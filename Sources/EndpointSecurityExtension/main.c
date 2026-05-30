#include <EndpointSecurity/EndpointSecurity.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <bsm/libbsm.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define XPCUI_ES_MACH_SERVICE "com.jonluca.xpcui.endpoint-security"
#define XPCUI_ES_MAX_TRACKED_PIDS 4096
#define XPCUI_ES_MAX_PENDING_EVENTS 4096
#define XPCUI_ES_MAX_FRAME_SIZE (64 * 1024 * 1024)

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} xpcui_buffer_t;

typedef struct {
    char *category;
    char *operation;
    char *path;
    char *service_name;
    char *session_id;
    char *auth_token;
    char *socket_path;
    uint64_t timestamp;
    uint64_t sequence;
    pid_t pid;
    pid_t parent_pid;
    pid_t child_pid;
    bool has_child_pid;
} xpcui_es_event_t;

static dispatch_queue_t xpcui_state_queue;
static dispatch_queue_t xpcui_writer_queue;
static pthread_mutex_t xpcui_config_lock = PTHREAD_MUTEX_INITIALIZER;
static char *xpcui_session_id;
static char *xpcui_auth_token;
static char *xpcui_socket_path;
static pid_t xpcui_tracked_pids[XPCUI_ES_MAX_TRACKED_PIDS];
static size_t xpcui_tracked_pid_count;
static es_client_t *xpcui_es_client;
static atomic_uint_fast64_t xpcui_sequence;
static atomic_uint_fast64_t xpcui_dropped;
static atomic_uint_fast64_t xpcui_previous_global_sequence;
static atomic_uint_fast64_t xpcui_pending_count;
static int xpcui_writer_socket = -1;
static char *xpcui_writer_socket_path;
static char *xpcui_writer_auth_token;
static bool xpcui_listener_has_native_peer_requirement;

static void xpcui_buffer_reserve(xpcui_buffer_t *buffer, size_t additional) {
    size_t needed = buffer->length + additional + 1;
    if (needed <= buffer->capacity) return;
    size_t capacity = buffer->capacity ? buffer->capacity : 1024;
    while (capacity < needed) capacity *= 2;
    char *data = realloc(buffer->data, capacity);
    if (!data) return;
    buffer->data = data;
    buffer->capacity = capacity;
}

static void xpcui_buffer_append_bytes(xpcui_buffer_t *buffer, const char *bytes, size_t length) {
    xpcui_buffer_reserve(buffer, length);
    if (!buffer->data || buffer->capacity < buffer->length + length + 1) return;
    memcpy(buffer->data + buffer->length, bytes, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
}

static void xpcui_buffer_append(xpcui_buffer_t *buffer, const char *text) {
    xpcui_buffer_append_bytes(buffer, text, strlen(text));
}

static void xpcui_buffer_append_format(xpcui_buffer_t *buffer, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    va_list copy;
    va_copy(copy, arguments);
    int length = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (length > 0) {
        xpcui_buffer_reserve(buffer, (size_t)length);
        if (buffer->data && buffer->capacity >= buffer->length + (size_t)length + 1) {
            vsnprintf(buffer->data + buffer->length, (size_t)length + 1, format, arguments);
            buffer->length += (size_t)length;
        }
    }
    va_end(arguments);
}

static void xpcui_buffer_append_json_string(xpcui_buffer_t *buffer, const char *string) {
    xpcui_buffer_append(buffer, "\"");
    if (string) {
        for (const unsigned char *cursor = (const unsigned char *)string; *cursor; cursor++) {
            switch (*cursor) {
                case '"': xpcui_buffer_append(buffer, "\\\""); break;
                case '\\': xpcui_buffer_append(buffer, "\\\\"); break;
                case '\b': xpcui_buffer_append(buffer, "\\b"); break;
                case '\f': xpcui_buffer_append(buffer, "\\f"); break;
                case '\n': xpcui_buffer_append(buffer, "\\n"); break;
                case '\r': xpcui_buffer_append(buffer, "\\r"); break;
                case '\t': xpcui_buffer_append(buffer, "\\t"); break;
                default:
                    if (*cursor < 0x20) {
                        xpcui_buffer_append_format(buffer, "\\u%04x", *cursor);
                    } else {
                        xpcui_buffer_append_bytes(buffer, (const char *)cursor, 1);
                    }
            }
        }
    }
    xpcui_buffer_append(buffer, "\"");
}

static char *xpcui_copy_token(es_string_token_t token) {
    char *copy = calloc(token.length + 1, 1);
    if (copy && token.data) memcpy(copy, token.data, token.length);
    return copy;
}

static uint64_t xpcui_nanoseconds(uint64_t mach_time) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return mach_time * timebase.numer / timebase.denom;
}

static bool xpcui_write_all(int socket_fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = send(socket_fd, cursor, length, MSG_NOSIGNAL);
        if (written <= 0) return false;
        cursor += written;
        length -= (size_t)written;
    }
    return true;
}

static bool xpcui_write_frame(int socket_fd, const char *bytes, size_t length) {
    if (length > XPCUI_ES_MAX_FRAME_SIZE) return false;
    uint32_t network_length = htonl((uint32_t)length);
    return xpcui_write_all(socket_fd, &network_length, sizeof(network_length))
        && xpcui_write_all(socket_fd, bytes, length);
}

static void xpcui_close_writer_socket(void) {
    if (xpcui_writer_socket >= 0) close(xpcui_writer_socket);
    xpcui_writer_socket = -1;
    free(xpcui_writer_socket_path);
    xpcui_writer_socket_path = NULL;
    free(xpcui_writer_auth_token);
    xpcui_writer_auth_token = NULL;
}

static int xpcui_connect(const char *socket_path, const char *auth_token) {
    if (xpcui_writer_socket >= 0
        && xpcui_writer_socket_path
        && strcmp(xpcui_writer_socket_path, socket_path) == 0
        && xpcui_writer_auth_token
        && strcmp(xpcui_writer_auth_token, auth_token) == 0) {
        return xpcui_writer_socket;
    }
    xpcui_close_writer_socket();
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) return -1;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlcpy(address.sun_path, socket_path, sizeof(address.sun_path)) >= sizeof(address.sun_path)
        || connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socket_fd);
        return -1;
    }
    xpcui_buffer_t authentication = {0};
    xpcui_buffer_append(&authentication, "{\"authToken\":");
    xpcui_buffer_append_json_string(&authentication, auth_token);
    xpcui_buffer_append(&authentication, "}");
    bool wrote = xpcui_write_frame(socket_fd, authentication.data, authentication.length);
    free(authentication.data);
    if (!wrote) {
        close(socket_fd);
        return -1;
    }
    xpcui_writer_socket = socket_fd;
    xpcui_writer_socket_path = strdup(socket_path);
    xpcui_writer_auth_token = strdup(auth_token);
    return socket_fd;
}

static bool xpcui_snapshot_config(xpcui_es_event_t *event, pid_t pid) {
    bool tracked = false;
    pthread_mutex_lock(&xpcui_config_lock);
    for (size_t index = 0; index < xpcui_tracked_pid_count; index++) {
        if (xpcui_tracked_pids[index] == pid) {
            tracked = true;
            break;
        }
    }
    if (tracked && xpcui_session_id && xpcui_auth_token && xpcui_socket_path) {
        event->session_id = strdup(xpcui_session_id);
        event->auth_token = strdup(xpcui_auth_token);
        event->socket_path = strdup(xpcui_socket_path);
    }
    pthread_mutex_unlock(&xpcui_config_lock);
    return tracked && event->session_id && event->auth_token && event->socket_path;
}

static void xpcui_track_pid(pid_t pid) {
    if (pid <= 0) return;
    pthread_mutex_lock(&xpcui_config_lock);
    for (size_t index = 0; index < xpcui_tracked_pid_count; index++) {
        if (xpcui_tracked_pids[index] == pid) {
            pthread_mutex_unlock(&xpcui_config_lock);
            return;
        }
    }
    if (xpcui_tracked_pid_count < XPCUI_ES_MAX_TRACKED_PIDS) {
        xpcui_tracked_pids[xpcui_tracked_pid_count++] = pid;
    }
    pthread_mutex_unlock(&xpcui_config_lock);
}

static void xpcui_release_event(xpcui_es_event_t *event) {
    free(event->category);
    free(event->operation);
    free(event->path);
    free(event->service_name);
    free(event->session_id);
    free(event->auth_token);
    free(event->socket_path);
    free(event);
}

static void xpcui_write_event(xpcui_es_event_t *event) {
    xpcui_buffer_t buffer = {0};
    xpcui_buffer_append(&buffer, "{\"schemaVersion\":1,\"sessionID\":");
    xpcui_buffer_append_json_string(&buffer, event->session_id);
    xpcui_buffer_append_format(
        &buffer,
        ",\"sequence\":%llu,\"monotonicTimestamp\":%llu,\"pid\":%d,\"parentPID\":%d,\"threadID\":0",
        event->sequence,
        event->timestamp,
        event->pid,
        event->parent_pid
    );
    xpcui_buffer_append(&buffer, ",\"source\":\"endpoint-security\",\"category\":");
    xpcui_buffer_append_json_string(&buffer, event->category);
    xpcui_buffer_append(&buffer, ",\"direction\":\"notify\",\"operation\":");
    xpcui_buffer_append_json_string(&buffer, event->operation);
    xpcui_buffer_append(&buffer, ",\"serviceName\":");
    if (event->service_name) {
        xpcui_buffer_append_json_string(&buffer, event->service_name);
    } else {
        xpcui_buffer_append(&buffer, "null");
    }
    xpcui_buffer_append(&buffer, ",\"summary\":");
    xpcui_buffer_append_json_string(&buffer, event->operation);
    xpcui_buffer_append(&buffer, ",\"payload\":{");
    bool has_payload = false;
    if (event->path) {
        xpcui_buffer_append(&buffer, "\"path\":");
        xpcui_buffer_append_json_string(&buffer, event->path);
        has_payload = true;
    }
    if (event->service_name) {
        if (has_payload) xpcui_buffer_append(&buffer, ",");
        xpcui_buffer_append(&buffer, "\"serviceName\":");
        xpcui_buffer_append_json_string(&buffer, event->service_name);
        has_payload = true;
    }
    if (event->has_child_pid) {
        if (has_payload) xpcui_buffer_append(&buffer, ",");
        xpcui_buffer_append_format(&buffer, "\"childPID\":%d", event->child_pid);
    }
    xpcui_buffer_append_format(
        &buffer,
        "},\"diagnostics\":[],\"droppedEventCount\":%llu}",
        atomic_load_explicit(&xpcui_dropped, memory_order_relaxed)
    );
    int socket_fd = xpcui_connect(event->socket_path, event->auth_token);
    if (socket_fd < 0 || !xpcui_write_frame(socket_fd, buffer.data, buffer.length)) {
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
        xpcui_close_writer_socket();
    }
    free(buffer.data);
}

static void xpcui_enqueue_event(xpcui_es_event_t *event) {
    uint64_t previous = atomic_fetch_add_explicit(&xpcui_pending_count, 1, memory_order_relaxed);
    if (previous >= XPCUI_ES_MAX_PENDING_EVENTS) {
        atomic_fetch_sub_explicit(&xpcui_pending_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
        xpcui_release_event(event);
        return;
    }
    dispatch_async(xpcui_writer_queue, ^{
        xpcui_write_event(event);
        xpcui_release_event(event);
        atomic_fetch_sub_explicit(&xpcui_pending_count, 1, memory_order_relaxed);
    });
}

static xpcui_es_event_t *xpcui_event_from_message(const es_message_t *message) {
    pid_t pid = audit_token_to_pid(message->process->audit_token);
    xpcui_es_event_t *event = calloc(1, sizeof(*event));
    if (!event) return NULL;
    if (!xpcui_snapshot_config(event, pid)) {
        xpcui_release_event(event);
        return NULL;
    }
    event->pid = pid;
    event->parent_pid = message->process->ppid;
    event->timestamp = xpcui_nanoseconds(message->mach_time);
    event->sequence = atomic_fetch_add_explicit(&xpcui_sequence, 1, memory_order_relaxed) + 1;
    switch (message->event_type) {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            event->category = strdup("process");
            event->operation = strdup("exec");
            event->path = xpcui_copy_token(message->event.exec.target->executable->path);
            break;
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            event->category = strdup("process");
            event->operation = strdup("exit");
            break;
        case ES_EVENT_TYPE_NOTIFY_FORK:
            event->category = strdup("process");
            event->operation = strdup("fork");
            event->child_pid = audit_token_to_pid(message->event.fork.child->audit_token);
            event->has_child_pid = event->child_pid > 0;
            event->path = xpcui_copy_token(message->event.fork.child->executable->path);
            if (event->has_child_pid) xpcui_track_pid(event->child_pid);
            break;
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            event->category = strdup("filesystem");
            event->operation = strdup("open");
            event->path = xpcui_copy_token(message->event.open.file->path);
            break;
        case ES_EVENT_TYPE_NOTIFY_CLOSE:
            event->category = strdup("filesystem");
            event->operation = strdup("close");
            event->path = xpcui_copy_token(message->event.close.target->path);
            break;
        case ES_EVENT_TYPE_NOTIFY_UIPC_CONNECT:
            event->category = strdup("socket");
            event->operation = strdup("unix-connect");
            event->path = xpcui_copy_token(message->event.uipc_connect.file->path);
            break;
        case ES_EVENT_TYPE_NOTIFY_XPC_CONNECT:
            event->category = strdup("xpc");
            event->operation = strdup("named-service-connect");
            if (message->event.xpc_connect) {
                event->service_name = xpcui_copy_token(message->event.xpc_connect->service_name);
            }
            break;
        default:
            xpcui_release_event(event);
            return NULL;
    }
    return event;
}

static void xpcui_handle_es_message(const es_message_t *message) {
    if (message->version >= 4) {
        uint64_t previous = atomic_exchange_explicit(
            &xpcui_previous_global_sequence,
            message->global_seq_num,
            memory_order_relaxed
        );
        if (previous > 0 && message->global_seq_num > previous + 1) {
            atomic_fetch_add_explicit(
                &xpcui_dropped,
                message->global_seq_num - previous - 1,
                memory_order_relaxed
            );
        }
    }
    xpcui_es_event_t *event = xpcui_event_from_message(message);
    if (event) xpcui_enqueue_event(event);
}

static void xpcui_start_client(void) {
    if (xpcui_es_client) return;
    es_new_client_result_t result = es_new_client(&xpcui_es_client, ^(es_client_t *client, const es_message_t *message) {
        (void)client;
        xpcui_handle_es_message(message);
    });
    if (result != ES_NEW_CLIENT_RESULT_SUCCESS) {
        xpcui_es_client = NULL;
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
        return;
    }
    es_event_type_t subscriptions[] = {
        ES_EVENT_TYPE_NOTIFY_EXEC,
        ES_EVENT_TYPE_NOTIFY_EXIT,
        ES_EVENT_TYPE_NOTIFY_FORK,
        ES_EVENT_TYPE_NOTIFY_OPEN,
        ES_EVENT_TYPE_NOTIFY_CLOSE,
        ES_EVENT_TYPE_NOTIFY_UIPC_CONNECT,
        ES_EVENT_TYPE_NOTIFY_XPC_CONNECT,
    };
    if (es_subscribe(
        xpcui_es_client,
        subscriptions,
        (uint32_t)(sizeof(subscriptions) / sizeof(subscriptions[0]))
    ) != ES_RETURN_SUCCESS) {
        es_delete_client(xpcui_es_client);
        xpcui_es_client = NULL;
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
    }
}

static void xpcui_update_tracked_pids(xpc_object_t message) {
    xpc_object_t pids = xpc_dictionary_get_array(message, "trackedPIDs");
    pthread_mutex_lock(&xpcui_config_lock);
    xpcui_tracked_pid_count = 0;
    if (pids) {
        size_t count = xpc_array_get_count(pids);
        for (size_t index = 0; index < count && index < XPCUI_ES_MAX_TRACKED_PIDS; index++) {
            xpcui_tracked_pids[xpcui_tracked_pid_count++] = (pid_t)xpc_array_get_int64(pids, index);
        }
    }
    pthread_mutex_unlock(&xpcui_config_lock);
}

static void xpcui_handle_control_message(xpc_object_t message) {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
    const char *command = xpc_dictionary_get_string(message, "command");
    if (!command) return;
    if (strcmp(command, "start") == 0) {
        const char *session_id = xpc_dictionary_get_string(message, "sessionID");
        const char *auth_token = xpc_dictionary_get_string(message, "authToken");
        const char *socket_path = xpc_dictionary_get_string(message, "socketPath");
        if (!session_id || !auth_token || !socket_path) return;
        pthread_mutex_lock(&xpcui_config_lock);
        free(xpcui_session_id);
        free(xpcui_auth_token);
        free(xpcui_socket_path);
        xpcui_session_id = strdup(session_id);
        xpcui_auth_token = strdup(auth_token);
        xpcui_socket_path = strdup(socket_path);
        pthread_mutex_unlock(&xpcui_config_lock);
        xpcui_update_tracked_pids(message);
        dispatch_async(xpcui_writer_queue, ^{
            xpcui_close_writer_socket();
        });
        xpcui_start_client();
    } else if (strcmp(command, "update-tracked-pids") == 0) {
        xpcui_update_tracked_pids(message);
    } else if (strcmp(command, "stop") == 0) {
        pthread_mutex_lock(&xpcui_config_lock);
        xpcui_tracked_pid_count = 0;
        free(xpcui_session_id);
        free(xpcui_auth_token);
        free(xpcui_socket_path);
        xpcui_session_id = NULL;
        xpcui_auth_token = NULL;
        xpcui_socket_path = NULL;
        pthread_mutex_unlock(&xpcui_config_lock);
        dispatch_async(xpcui_writer_queue, ^{
            xpcui_close_writer_socket();
        });
    }
}

static bool xpcui_peer_has_expected_identifier(xpc_connection_t peer) {
    pid_t pid = xpc_connection_get_pid(peer);
    CFNumberRef pid_number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    if (!pid_number) return false;
    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {pid_number};
    CFDictionaryRef attributes = CFDictionaryCreate(
        NULL,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(pid_number);
    if (!attributes) return false;

    SecCodeRef code = NULL;
    SecStaticCodeRef static_code = NULL;
    CFDictionaryRef information = NULL;
    SecCodeRef own_code = NULL;
    SecStaticCodeRef own_static_code = NULL;
    CFDictionaryRef own_information = NULL;
    bool trusted = false;
    if (SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess
        && SecCodeCheckValidity(code, kSecCSStrictValidate, NULL) == errSecSuccess
        && SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &static_code) == errSecSuccess
        && SecCodeCopySigningInformation(static_code, kSecCSDefaultFlags, &information) == errSecSuccess
        && SecCodeCopySelf(kSecCSDefaultFlags, &own_code) == errSecSuccess
        && SecCodeCopyStaticCode(own_code, kSecCSDefaultFlags, &own_static_code) == errSecSuccess
        && SecCodeCopySigningInformation(own_static_code, kSecCSDefaultFlags, &own_information) == errSecSuccess) {
        CFStringRef identifier = CFDictionaryGetValue(information, kSecCodeInfoIdentifier);
        CFStringRef team_identifier = CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier);
        CFStringRef own_team_identifier = CFDictionaryGetValue(own_information, kSecCodeInfoTeamIdentifier);
        trusted = identifier
            && CFGetTypeID(identifier) == CFStringGetTypeID()
            && CFStringCompare(identifier, CFSTR("com.jonluca.xpcui"), 0) == kCFCompareEqualTo
            && team_identifier
            && CFGetTypeID(team_identifier) == CFStringGetTypeID()
            && own_team_identifier
            && CFGetTypeID(own_team_identifier) == CFStringGetTypeID()
            && CFStringCompare(team_identifier, own_team_identifier, 0) == kCFCompareEqualTo;
    }
    if (own_information) CFRelease(own_information);
    if (own_static_code) CFRelease(own_static_code);
    if (own_code) CFRelease(own_code);
    if (information) CFRelease(information);
    if (static_code) CFRelease(static_code);
    if (code) CFRelease(code);
    CFRelease(attributes);
    return trusted;
}

int main(void) {
    xpcui_state_queue = dispatch_queue_create("com.jonluca.xpcui.endpoint-security.state", DISPATCH_QUEUE_SERIAL);
    xpcui_writer_queue = dispatch_queue_create("com.jonluca.xpcui.endpoint-security.writer", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(
        XPCUI_ES_MACH_SERVICE,
        xpcui_state_queue,
        XPC_CONNECTION_MACH_SERVICE_LISTENER
    );
    if (__builtin_available(macOS 14.4, *)) {
        if (xpc_connection_set_peer_team_identity_requirement(listener, "com.jonluca.xpcui") != 0) {
            return EXIT_FAILURE;
        }
        xpcui_listener_has_native_peer_requirement = true;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        if (!xpcui_listener_has_native_peer_requirement && !xpcui_peer_has_expected_identifier(peer)) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            xpcui_handle_control_message(message);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}
