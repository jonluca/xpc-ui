#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <xpc/xpc.h>

extern char **environ;

static const char *xpcui_fixture_cli_service = "com.jonluca.xpcui.fixture.mach-service";
typedef void (*xpcui_trace_lifecycle_fn)(const char *operation, const char *service_name);

static uint64_t xpcui_nanoseconds(struct timespec time) {
    return (uint64_t)time.tv_sec * 1000000000ULL + (uint64_t)time.tv_nsec;
}

static int xpcui_run_lifecycle_stress(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s --stress-lifecycle events-per-second duration-seconds\n", argv[0]);
        return 64;
    }
    char *rate_end = NULL;
    char *duration_end = NULL;
    uint64_t rate = strtoull(argv[2], &rate_end, 10);
    uint64_t duration = strtoull(argv[3], &duration_end, 10);
    if (!rate_end || rate_end[0] != '\0' || !duration_end || duration_end[0] != '\0'
        || rate == 0 || duration == 0) {
        fprintf(stderr, "stress rate and duration must be positive integers\n");
        return 64;
    }
    xpcui_trace_lifecycle_fn trace_lifecycle = (xpcui_trace_lifecycle_fn)dlsym(
        RTLD_DEFAULT,
        "xpcui_trace_optional_lifecycle"
    );
    if (!trace_lifecycle) {
        fprintf(stderr, "XPCTrace.dylib is not injected\n");
        return 69;
    }

    struct timespec started = {0};
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (uint64_t second = 0; second < duration; second++) {
        struct timespec interval_started = {0};
        clock_gettime(CLOCK_MONOTONIC, &interval_started);
        for (uint64_t event = 0; event < rate; event++) {
            trace_lifecycle("stress-lifecycle", "com.jonluca.xpcui.fixture.stress");
        }
        struct timespec interval_finished = {0};
        clock_gettime(CLOCK_MONOTONIC, &interval_finished);
        uint64_t elapsed = xpcui_nanoseconds(interval_finished) - xpcui_nanoseconds(interval_started);
        if (elapsed < 1000000000ULL) {
            uint64_t remaining = 1000000000ULL - elapsed;
            struct timespec sleep_time = {
                .tv_sec = (time_t)(remaining / 1000000000ULL),
                .tv_nsec = (long)(remaining % 1000000000ULL),
            };
            nanosleep(&sleep_time, NULL);
        }
    }
    struct timespec finished = {0};
    clock_gettime(CLOCK_MONOTONIC, &finished);
    printf(
        "{\"submittedEvents\":%llu,\"elapsedNanoseconds\":%llu}\n",
        rate * duration,
        xpcui_nanoseconds(finished) - xpcui_nanoseconds(started)
    );
    return 0;
}

static int xpcui_open_file(const char *role, char *path, size_t capacity) {
    snprintf(path, capacity, "/tmp/XPCFixtureCLI-%d-%s.log", getpid(), role);
    int file = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (file >= 0) {
        dprintf(file, "XPC Fixture CLI role=%s pid=%d\n", role, getpid());
    }
    return file;
}

static int xpcui_open_socket(char *path, size_t capacity) {
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return -1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    snprintf(path, capacity, "/tmp/XPCFixtureCLI-%d.sock", getpid());
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    unlink(path);
    if (bind(socket_fd, (const struct sockaddr *)&address, sizeof(address)) != 0
        || listen(socket_fd, 1) != 0) {
        close(socket_fd);
        unlink(path);
        return -1;
    }
    return socket_fd;
}

static xpc_object_t xpcui_message(const char *role) {
    static const uint8_t blob[] = {0x58, 0x50, 0x43, 0x55, 0x49, 0x00, 0xff};
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "kind", "cli-fixture");
    xpc_dictionary_set_string(message, "role", role);
    xpc_dictionary_set_data(message, "blob", blob, sizeof(blob));
    xpc_object_t nested = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(nested, "pid", getpid());
    xpc_dictionary_set_string(nested, "transport", "Process");
    xpc_dictionary_set_value(message, "nested", nested);
    xpc_release(nested);
    return message;
}

static xpc_connection_t xpcui_create_connection(void) {
    xpc_connection_t connection = xpc_connection_create_mach_service(
        xpcui_fixture_cli_service,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        0
    );
    if (!connection) {
        return NULL;
    }
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(connection);
    return connection;
}

static xpc_object_t xpcui_dictionary_get_dictionary(xpc_object_t dictionary, const char *key) {
    xpc_object_t value = xpc_dictionary_get_value(dictionary, key);
    return value && xpc_get_type(value) == XPC_TYPE_DICTIONARY ? value : NULL;
}

static xpc_object_t xpcui_interception_probe_message(void) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "kind", "interception-probe");

    xpc_object_t probe = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(probe, "role", "client-original");
    xpc_dictionary_set_bool(probe, "enabled", true);
    xpc_dictionary_set_int64(probe, "signed", -1);
    xpc_dictionary_set_uint64(probe, "unsigned", 1);
    xpc_dictionary_set_double(probe, "ratio", 1.25);
    xpc_object_t nested = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(nested, "pid", getpid());
    xpc_dictionary_set_value(probe, "nested", nested);
    xpc_release(nested);
    xpc_dictionary_set_value(message, "probe", probe);
    xpc_release(probe);
    return message;
}

static int xpcui_run_interception_probe(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s --interception-probe\n", argv[0]);
        return 64;
    }
    xpc_connection_t connection = xpcui_create_connection();
    if (!connection) {
        fprintf(stderr, "unable to create fixture XPC connection\n");
        return 69;
    }
    xpc_object_t message = xpcui_interception_probe_message();
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, message);
    xpc_release(message);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        char *description = reply ? xpc_copy_description(reply) : NULL;
        fprintf(stderr, "fixture probe did not receive a dictionary reply: %s\n", description ? description : "null");
        free(description);
        if (reply) xpc_release(reply);
        xpc_release(connection);
        return 69;
    }

    xpc_object_t received = xpcui_dictionary_get_dictionary(reply, "received");
    xpc_object_t received_nested = received ? xpcui_dictionary_get_dictionary(received, "nested") : NULL;
    xpc_object_t response = xpcui_dictionary_get_dictionary(reply, "response");
    if (!received || !received_nested || !response) {
        fprintf(stderr, "fixture probe reply is missing expected dictionaries\n");
        xpc_release(reply);
        xpc_release(connection);
        return 70;
    }

    printf(
        "{\"received\":{\"role\":\"%s\",\"enabled\":%s,\"signed\":%lld,"
        "\"unsigned\":%llu,\"ratio\":%.17g,\"nestedPID\":%lld},"
        "\"response\":{\"label\":\"%s\",\"enabled\":%s,\"signed\":%lld,"
        "\"unsigned\":%llu,\"ratio\":%.17g}}\n",
        xpc_dictionary_get_string(received, "role"),
        xpc_dictionary_get_bool(received, "enabled") ? "true" : "false",
        (long long)xpc_dictionary_get_int64(received, "signed"),
        (unsigned long long)xpc_dictionary_get_uint64(received, "unsigned"),
        xpc_dictionary_get_double(received, "ratio"),
        (long long)xpc_dictionary_get_int64(received_nested, "pid"),
        xpc_dictionary_get_string(response, "label"),
        xpc_dictionary_get_bool(response, "enabled") ? "true" : "false",
        (long long)xpc_dictionary_get_int64(response, "signed"),
        (unsigned long long)xpc_dictionary_get_uint64(response, "unsigned"),
        xpc_dictionary_get_double(response, "ratio")
    );
    fflush(stdout);
    usleep(250000);
    xpc_release(reply);
    xpc_release(connection);
    return 0;
}

static int xpcui_run_xpc_stress(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s --stress-xpc events-per-second duration-seconds\n", argv[0]);
        return 64;
    }
    char *rate_end = NULL;
    char *duration_end = NULL;
    uint64_t rate = strtoull(argv[2], &rate_end, 10);
    uint64_t duration = strtoull(argv[3], &duration_end, 10);
    if (!rate_end || rate_end[0] != '\0' || !duration_end || duration_end[0] != '\0'
        || rate == 0 || duration == 0) {
        fprintf(stderr, "stress rate and duration must be positive integers\n");
        return 64;
    }

    xpc_connection_t connection = xpcui_create_connection();
    if (!connection) {
        fprintf(stderr, "unable to create fixture XPC connection\n");
        return 69;
    }
    xpc_object_t message = xpcui_message("stress");

    struct timespec started = {0};
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (uint64_t second = 0; second < duration; second++) {
        struct timespec interval_started = {0};
        clock_gettime(CLOCK_MONOTONIC, &interval_started);
        for (uint64_t event = 0; event < rate; event++) {
            xpc_connection_send_message(connection, message);
        }
        struct timespec interval_finished = {0};
        clock_gettime(CLOCK_MONOTONIC, &interval_finished);
        uint64_t elapsed = xpcui_nanoseconds(interval_finished) - xpcui_nanoseconds(interval_started);
        if (elapsed < 1000000000ULL) {
            uint64_t remaining = 1000000000ULL - elapsed;
            struct timespec sleep_time = {
                .tv_sec = (time_t)(remaining / 1000000000ULL),
                .tv_nsec = (long)(remaining % 1000000000ULL),
            };
            nanosleep(&sleep_time, NULL);
        }
    }
    struct timespec finished = {0};
    clock_gettime(CLOCK_MONOTONIC, &finished);
    printf(
        "{\"submittedEvents\":%llu,\"elapsedNanoseconds\":%llu}\n",
        rate * duration,
        xpcui_nanoseconds(finished) - xpcui_nanoseconds(started)
    );
    xpc_release(message);
    xpc_release(connection);
    return 0;
}

static xpc_connection_t xpcui_emit_xpc_traffic(const char *role) {
    xpc_connection_t connection = xpcui_create_connection();
    if (!connection) {
        return NULL;
    }
    xpc_object_t message = xpcui_message(role);
    xpc_connection_send_message(connection, message);
    xpc_connection_send_message_with_reply(
        connection,
        message,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^(xpc_object_t reply) {
            (void)reply;
        }
    );
    xpc_release(message);
    return connection;
}

static pid_t xpcui_spawn_child(const char *executable) {
    pid_t child_pid = 0;
    char *const arguments[] = {(char *)executable, "--child", NULL};
    return posix_spawn(&child_pid, executable, NULL, NULL, arguments, environ) == 0
        ? child_pid
        : 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--stress-lifecycle") == 0) {
        return xpcui_run_lifecycle_stress(argc, argv);
    }
    if (argc > 1 && strcmp(argv[1], "--stress-xpc") == 0) {
        return xpcui_run_xpc_stress(argc, argv);
    }
    if (argc > 1 && strcmp(argv[1], "--interception-probe") == 0) {
        return xpcui_run_interception_probe(argc, argv);
    }
    bool is_child = argc > 1 && strcmp(argv[1], "--child") == 0;
    const char *role = is_child ? "child" : "parent";
    char file_path[128] = {0};
    char socket_path[128] = {0};
    int file = xpcui_open_file(role, file_path, sizeof(file_path));
    int folder = open("/tmp", O_RDONLY);
    int socket_fd = xpcui_open_socket(socket_path, sizeof(socket_path));
    xpc_connection_t connection = xpcui_emit_xpc_traffic(role);
    pid_t child_pid = is_child ? 0 : xpcui_spawn_child(argv[0]);

    sleep(is_child ? 5 : 7);

    if (child_pid > 0) {
        waitpid(child_pid, NULL, 0);
    }
    if (connection) xpc_release(connection);
    if (socket_fd >= 0) close(socket_fd);
    if (folder >= 0) close(folder);
    if (file >= 0) close(file);
    unlink(socket_path);
    unlink(file_path);
    return 0;
}
