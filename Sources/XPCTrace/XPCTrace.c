#include <arpa/inet.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

#include "XPCTraceOptionalAdapters.h"

#define XPCUI_QUEUE_CAPACITY 4096
#define XPCUI_SERVICE_MAP_CAPACITY 512
#define XPCUI_MAX_FRAME_SIZE (64 * 1024 * 1024)
#define XPCUI_LAZY_PAYLOAD_THRESHOLD (512 * 1024)
#define XPCUI_MAX_DEPTH 24
#define XPCUI_INTERCEPTION_RULE_CAPACITY 32
#define XPCUI_INTERCEPTION_KEY_PATH_DEPTH 8
#define XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY 128
#define XPCUI_INTERCEPTION_KEY_PATH_CAPACITY 1024
#define XPCUI_INTERCEPTION_VALUE_CAPACITY 4096

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} xpcui_buffer_t;

typedef struct {
    xpc_object_t payload;
    bool payload_snapshot_fallback;
    char *direction;
    char *operation;
    char *service_name;
    char **interception_rule_ids;
    size_t interception_rule_count;
    uint64_t sequence;
    uint64_t timestamp;
    uint64_t thread_id;
} xpcui_pending_event_t;

static xpcui_pending_event_t xpcui_queue[XPCUI_QUEUE_CAPACITY];
static size_t xpcui_queue_head = 0;
static size_t xpcui_queue_tail = 0;
static size_t xpcui_queue_count = 0;
static pthread_mutex_t xpcui_queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t xpcui_queue_ready = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t xpcui_service_map_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t xpcui_sequence = 0;
static atomic_uint_fast64_t xpcui_dropped = 0;
static const char *xpcui_session_id = NULL;
static const char *xpcui_auth_token = NULL;
static const char *xpcui_socket_path = NULL;
static const char *xpcui_blobs_path = NULL;
static bool xpcui_enabled = false;
static atomic_bool xpcui_interception_enabled = false;

typedef enum {
    XPCUI_INTERCEPTION_REPLACEMENT_STRING,
    XPCUI_INTERCEPTION_REPLACEMENT_BOOL,
    XPCUI_INTERCEPTION_REPLACEMENT_INT64,
    XPCUI_INTERCEPTION_REPLACEMENT_UINT64,
    XPCUI_INTERCEPTION_REPLACEMENT_DOUBLE,
} xpcui_interception_replacement_type_t;

typedef struct {
    char *id;
    char *service_name;
    char *direction;
    char *operation;
    char *match_key;
    char *match_string_value;
    char *replacement_key;
    char *replacement_value;
    xpcui_interception_replacement_type_t replacement_type;
    bool replacement_bool_value;
    int64_t replacement_int64_value;
    uint64_t replacement_uint64_value;
    double replacement_double_value;
} xpcui_interception_rule_t;

typedef struct {
    xpc_object_t message;
    const char *rule_ids[XPCUI_INTERCEPTION_RULE_CAPACITY];
    size_t rule_count;
    bool owns_message;
} xpcui_interception_result_t;

static xpcui_interception_rule_t xpcui_interception_rules[XPCUI_INTERCEPTION_RULE_CAPACITY];
static size_t xpcui_interception_rule_count = 0;

typedef struct {
    const void *endpoint;
    char *name;
} xpcui_service_map_entry_t;

static xpcui_service_map_entry_t xpcui_service_map[XPCUI_SERVICE_MAP_CAPACITY];

static void xpcui_buffer_reserve(xpcui_buffer_t *buffer, size_t additional) {
    size_t needed = buffer->length + additional + 1;
    if (needed <= buffer->capacity) {
        return;
    }
    size_t capacity = buffer->capacity ? buffer->capacity : 1024;
    while (capacity < needed) {
        capacity *= 2;
    }
    char *data = realloc(buffer->data, capacity);
    if (!data) {
        return;
    }
    buffer->data = data;
    buffer->capacity = capacity;
}

static void xpcui_buffer_append_bytes(xpcui_buffer_t *buffer, const char *bytes, size_t length) {
    xpcui_buffer_reserve(buffer, length);
    if (!buffer->data || buffer->capacity < buffer->length + length + 1) {
        return;
    }
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

static void xpcui_buffer_append_base64(xpcui_buffer_t *buffer, const uint8_t *bytes, size_t length) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t index = 0; index < length; index += 3) {
        uint32_t value = (uint32_t)bytes[index] << 16;
        if (index + 1 < length) value |= (uint32_t)bytes[index + 1] << 8;
        if (index + 2 < length) value |= bytes[index + 2];
        char encoded[4] = {
            alphabet[(value >> 18) & 0x3f],
            alphabet[(value >> 12) & 0x3f],
            index + 1 < length ? alphabet[(value >> 6) & 0x3f] : '=',
            index + 2 < length ? alphabet[value & 0x3f] : '=',
        };
        xpcui_buffer_append_bytes(buffer, encoded, sizeof(encoded));
    }
}

static void xpcui_serialize_object(xpcui_buffer_t *buffer, xpc_object_t object, int depth);

static void xpcui_serialize_description(xpcui_buffer_t *buffer, xpc_object_t object, const char *type_name) {
    char *description = object ? xpc_copy_description(object) : NULL;
    xpcui_buffer_append(buffer, "{\"type\":");
    xpcui_buffer_append_json_string(buffer, type_name);
    xpcui_buffer_append(buffer, ",\"description\":");
    xpcui_buffer_append_json_string(buffer, description ? description : "");
    xpcui_buffer_append(buffer, "}");
    free(description);
}

static void xpcui_serialize_object(xpcui_buffer_t *buffer, xpc_object_t object, int depth) {
    if (!object) {
        xpcui_buffer_append(buffer, "null");
        return;
    }
    if (depth >= XPCUI_MAX_DEPTH) {
        xpcui_buffer_append(buffer, "{\"type\":\"depth-limit\"}");
        return;
    }
    xpc_type_t type = xpc_get_type(object);
    if (type == XPC_TYPE_NULL) {
        xpcui_buffer_append(buffer, "{\"type\":\"null\"}");
    } else if (type == XPC_TYPE_BOOL) {
        xpcui_buffer_append_format(buffer, "{\"type\":\"bool\",\"value\":%s}", xpc_bool_get_value(object) ? "true" : "false");
    } else if (type == XPC_TYPE_INT64) {
        xpcui_buffer_append_format(buffer, "{\"type\":\"int64\",\"value\":%lld}", xpc_int64_get_value(object));
    } else if (type == XPC_TYPE_UINT64) {
        xpcui_buffer_append_format(buffer, "{\"type\":\"uint64\",\"value\":%llu}", xpc_uint64_get_value(object));
    } else if (type == XPC_TYPE_DOUBLE) {
        xpcui_buffer_append_format(buffer, "{\"type\":\"double\",\"value\":%.17g}", xpc_double_get_value(object));
    } else if (type == XPC_TYPE_DATE) {
        xpcui_buffer_append_format(buffer, "{\"type\":\"date\",\"value\":%lld}", xpc_date_get_value(object));
    } else if (type == XPC_TYPE_STRING) {
        xpcui_buffer_append(buffer, "{\"type\":\"string\",\"value\":");
        xpcui_buffer_append_json_string(buffer, xpc_string_get_string_ptr(object));
        xpcui_buffer_append(buffer, "}");
    } else if (type == XPC_TYPE_DATA) {
        size_t length = xpc_data_get_length(object);
        xpcui_buffer_append_format(buffer, "{\"type\":\"data\",\"encoding\":\"base64\",\"length\":%zu,\"value\":\"", length);
        xpcui_buffer_append_base64(buffer, xpc_data_get_bytes_ptr(object), length);
        xpcui_buffer_append(buffer, "\"}");
    } else if (type == XPC_TYPE_UUID) {
        uuid_string_t uuid;
        uuid_unparse_lower(xpc_uuid_get_bytes(object), uuid);
        xpcui_buffer_append(buffer, "{\"type\":\"uuid\",\"value\":");
        xpcui_buffer_append_json_string(buffer, uuid);
        xpcui_buffer_append(buffer, "}");
    } else if (type == XPC_TYPE_ARRAY) {
        xpcui_buffer_append(buffer, "{\"type\":\"array\",\"value\":[");
        __block bool first = true;
        xpc_array_apply(object, ^bool(size_t index, xpc_object_t value) {
            (void)index;
            if (!first) xpcui_buffer_append(buffer, ",");
            first = false;
            xpcui_serialize_object(buffer, value, depth + 1);
            return true;
        });
        xpcui_buffer_append(buffer, "]}");
    } else if (type == XPC_TYPE_DICTIONARY) {
        xpcui_buffer_append(buffer, "{\"type\":\"dictionary\",\"value\":{");
        __block bool first = true;
        xpc_dictionary_apply(object, ^bool(const char *key, xpc_object_t value) {
            if (!first) xpcui_buffer_append(buffer, ",");
            first = false;
            xpcui_buffer_append_json_string(buffer, key);
            xpcui_buffer_append(buffer, ":");
            xpcui_serialize_object(buffer, value, depth + 1);
            return true;
        });
        xpcui_buffer_append(buffer, "}}");
    } else if (type == XPC_TYPE_FD) {
        xpcui_serialize_description(buffer, object, "fd");
    } else if (type == XPC_TYPE_ERROR) {
        xpcui_serialize_description(buffer, object, "error");
#if defined(XPC_TYPE_RICH_ERROR)
    } else if (type == XPC_TYPE_RICH_ERROR) {
        char *description = xpc_rich_error_copy_description((xpc_rich_error_t)object);
        xpcui_buffer_append_format(
            buffer,
            "{\"type\":\"rich-error\",\"canRetry\":%s,\"description\":",
            xpc_rich_error_can_retry((xpc_rich_error_t)object) ? "true" : "false"
        );
        xpcui_buffer_append_json_string(buffer, description ? description : "");
        xpcui_buffer_append(buffer, "}");
        free(description);
#endif
    } else if (type == XPC_TYPE_CONNECTION) {
        xpcui_serialize_description(buffer, object, "connection");
    } else if (type == XPC_TYPE_ENDPOINT) {
        xpcui_serialize_description(buffer, object, "endpoint");
    } else {
        xpcui_serialize_description(buffer, object, "unsupported");
    }
}

static uint64_t xpcui_monotonic_nanoseconds(void) {
    static mach_timebase_info_data_t timebase = {0};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return mach_continuous_time() * timebase.numer / timebase.denom;
}

static uint64_t xpcui_thread_id(void) {
    uint64_t thread_id = 0;
    pthread_threadid_np(NULL, &thread_id);
    return thread_id;
}

static void xpcui_remember_service_name(const void *endpoint, const char *name) {
    if (!endpoint || !name || name[0] == '\0') {
        return;
    }
    pthread_mutex_lock(&xpcui_service_map_lock);
    size_t replacement = ((uintptr_t)endpoint >> 4) % XPCUI_SERVICE_MAP_CAPACITY;
    for (size_t index = 0; index < XPCUI_SERVICE_MAP_CAPACITY; index++) {
        if (xpcui_service_map[index].endpoint == endpoint || !xpcui_service_map[index].endpoint) {
            replacement = index;
            break;
        }
    }
    free(xpcui_service_map[replacement].name);
    xpcui_service_map[replacement].endpoint = endpoint;
    xpcui_service_map[replacement].name = strdup(name);
    pthread_mutex_unlock(&xpcui_service_map_lock);
}

static char *xpcui_copy_service_name(const void *endpoint, const char *fallback_name) {
    if (endpoint && pthread_mutex_trylock(&xpcui_service_map_lock) == 0) {
        for (size_t index = 0; index < XPCUI_SERVICE_MAP_CAPACITY; index++) {
            if (xpcui_service_map[index].endpoint == endpoint) {
                char *name = strdup(xpcui_service_map[index].name ? xpcui_service_map[index].name : "");
                pthread_mutex_unlock(&xpcui_service_map_lock);
                return name;
            }
        }
        pthread_mutex_unlock(&xpcui_service_map_lock);
    }
    return strdup(fallback_name ? fallback_name : "");
}

static char *xpcui_copy_cf_string(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return NULL;
    }
    CFStringRef string = (CFStringRef)value;
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(string),
        kCFStringEncodingUTF8
    ) + 1;
    char *copy = calloc((size_t)capacity, 1);
    if (!copy || !CFStringGetCString(string, copy, capacity, kCFStringEncodingUTF8)) {
        free(copy);
        return NULL;
    }
    return copy;
}

static bool xpcui_cf_bool(CFDictionaryRef dictionary, CFStringRef key, bool fallback) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) {
        return fallback;
    }
    return CFBooleanGetValue((CFBooleanRef)value);
}

static bool xpcui_string_has_maximum_length(const char *value, size_t maximum) {
    return value && strnlen(value, maximum + 1) <= maximum;
}

static bool xpcui_key_path_is_valid(const char *key_path) {
    if (!xpcui_string_has_maximum_length(key_path, XPCUI_INTERCEPTION_KEY_PATH_CAPACITY)
        || key_path[0] == '\0') {
        return false;
    }
    const char *cursor = key_path;
    for (size_t depth = 0; depth < XPCUI_INTERCEPTION_KEY_PATH_DEPTH; depth++) {
        const char *separator = strchr(cursor, '.');
        size_t length = separator ? (size_t)(separator - cursor) : strlen(cursor);
        if (length == 0 || length >= XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY) {
            return false;
        }
        if (!separator) {
            return true;
        }
        cursor = separator + 1;
    }
    return false;
}

static bool xpcui_load_replacement_value(
    CFDictionaryRef dictionary,
    xpcui_interception_rule_t *rule
) {
    char *type = xpcui_copy_cf_string(dictionary, CFSTR("replacementType"));
    if (!type) {
        type = strdup("string");
    }
    rule->replacement_value = xpcui_copy_cf_string(dictionary, CFSTR("replacementValue"));
    if (!rule->replacement_value) {
        rule->replacement_value = xpcui_copy_cf_string(dictionary, CFSTR("replacementStringValue"));
    }
    if (!type || !xpcui_string_has_maximum_length(rule->replacement_value, XPCUI_INTERCEPTION_VALUE_CAPACITY)) {
        free(type);
        return false;
    }

    bool valid = true;
    if (strcmp(type, "string") == 0) {
        rule->replacement_type = XPCUI_INTERCEPTION_REPLACEMENT_STRING;
    } else if (strcmp(type, "bool") == 0) {
        rule->replacement_type = XPCUI_INTERCEPTION_REPLACEMENT_BOOL;
        if (strcasecmp(rule->replacement_value, "true") == 0) {
            rule->replacement_bool_value = true;
        } else if (strcasecmp(rule->replacement_value, "false") == 0) {
            rule->replacement_bool_value = false;
        } else {
            valid = false;
        }
    } else if (strcmp(type, "int64") == 0) {
        rule->replacement_type = XPCUI_INTERCEPTION_REPLACEMENT_INT64;
        char *end = NULL;
        errno = 0;
        rule->replacement_int64_value = strtoll(rule->replacement_value, &end, 10);
        valid = errno == 0 && end && end[0] == '\0';
    } else if (strcmp(type, "uint64") == 0) {
        rule->replacement_type = XPCUI_INTERCEPTION_REPLACEMENT_UINT64;
        char *end = NULL;
        errno = 0;
        rule->replacement_uint64_value = strtoull(rule->replacement_value, &end, 10);
        valid = errno == 0
            && end
            && end[0] == '\0'
            && rule->replacement_value[0] != '-';
    } else if (strcmp(type, "double") == 0) {
        rule->replacement_type = XPCUI_INTERCEPTION_REPLACEMENT_DOUBLE;
        char *end = NULL;
        errno = 0;
        rule->replacement_double_value = strtod(rule->replacement_value, &end);
        valid = errno == 0 && end && end[0] == '\0' && isfinite(rule->replacement_double_value);
    } else {
        valid = false;
    }
    free(type);
    return valid;
}

static void xpcui_release_interception_rule(xpcui_interception_rule_t *rule) {
    free(rule->id);
    free(rule->service_name);
    free(rule->direction);
    free(rule->operation);
    free(rule->match_key);
    free(rule->match_string_value);
    free(rule->replacement_key);
    free(rule->replacement_value);
    *rule = (xpcui_interception_rule_t){0};
}

static bool xpcui_load_interception_rule(CFDictionaryRef dictionary, xpcui_interception_rule_t *rule) {
    if (!xpcui_cf_bool(dictionary, CFSTR("enabled"), true)) {
        return false;
    }
    *rule = (xpcui_interception_rule_t){
        .id = xpcui_copy_cf_string(dictionary, CFSTR("id")),
        .service_name = xpcui_copy_cf_string(dictionary, CFSTR("serviceName")),
        .direction = xpcui_copy_cf_string(dictionary, CFSTR("direction")),
        .operation = xpcui_copy_cf_string(dictionary, CFSTR("operation")),
        .match_key = xpcui_copy_cf_string(dictionary, CFSTR("matchKey")),
        .match_string_value = xpcui_copy_cf_string(dictionary, CFSTR("matchStringValue")),
        .replacement_key = xpcui_copy_cf_string(dictionary, CFSTR("replacementKey")),
    };
    bool valid = rule->id
        && rule->service_name
        && rule->direction
        && rule->operation
        && rule->match_key
        && rule->match_string_value
        && rule->replacement_key
        && xpcui_load_replacement_value(dictionary, rule)
        && rule->service_name[0] != '\0'
        && rule->direction[0] != '\0'
        && rule->operation[0] != '\0'
        && xpcui_string_has_maximum_length(rule->id, XPCUI_INTERCEPTION_KEY_PATH_CAPACITY)
        && xpcui_string_has_maximum_length(rule->service_name, XPCUI_INTERCEPTION_KEY_PATH_CAPACITY)
        && xpcui_string_has_maximum_length(rule->direction, XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY)
        && xpcui_string_has_maximum_length(rule->operation, XPCUI_INTERCEPTION_KEY_PATH_CAPACITY)
        && xpcui_string_has_maximum_length(rule->match_string_value, XPCUI_INTERCEPTION_VALUE_CAPACITY)
        && (rule->match_key[0] == '\0' || xpcui_key_path_is_valid(rule->match_key))
        && xpcui_key_path_is_valid(rule->replacement_key)
        && ((rule->match_key[0] == '\0') == (rule->match_string_value[0] == '\0'));
    if (!valid) {
        xpcui_release_interception_rule(rule);
    }
    return valid;
}

static void xpcui_load_interception_rules(void) {
    const char *path = getenv("XPCUI_INTERCEPTION_RULES_PATH");
    if (!path || path[0] == '\0') {
        return;
    }
    int file = open(path, O_RDONLY);
    if (file < 0) {
        return;
    }
    struct stat metadata = {0};
    if (fstat(file, &metadata) != 0 || metadata.st_size <= 0 || metadata.st_size > 1024 * 1024) {
        close(file);
        return;
    }
    UInt8 *bytes = malloc((size_t)metadata.st_size);
    if (!bytes) {
        close(file);
        return;
    }
    size_t offset = 0;
    while (offset < (size_t)metadata.st_size) {
        ssize_t count = read(file, bytes + offset, (size_t)metadata.st_size - offset);
        if (count <= 0) {
            free(bytes);
            close(file);
            return;
        }
        offset += (size_t)count;
    }
    close(file);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, metadata.st_size);
    free(bytes);
    if (!data) {
        return;
    }
    CFErrorRef error = NULL;
    CFPropertyListRef property_list = CFPropertyListCreateWithData(
        kCFAllocatorDefault,
        data,
        kCFPropertyListImmutable,
        NULL,
        &error
    );
    CFRelease(data);
    if (!property_list || CFGetTypeID(property_list) != CFDictionaryGetTypeID()) {
        if (property_list) CFRelease(property_list);
        if (error) CFRelease(error);
        return;
    }
    CFTypeRef rules_value = CFDictionaryGetValue((CFDictionaryRef)property_list, CFSTR("rules"));
    if (rules_value && CFGetTypeID(rules_value) == CFArrayGetTypeID()) {
        CFArrayRef rules = (CFArrayRef)rules_value;
        CFIndex count = CFArrayGetCount(rules);
        for (CFIndex index = 0;
             index < count && xpcui_interception_rule_count < XPCUI_INTERCEPTION_RULE_CAPACITY;
             index++) {
            CFTypeRef value = CFArrayGetValueAtIndex(rules, index);
            if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
                continue;
            }
            xpcui_interception_rule_t rule = {0};
            if (xpcui_load_interception_rule((CFDictionaryRef)value, &rule)) {
                xpcui_interception_rules[xpcui_interception_rule_count++] = rule;
            }
        }
    }
    CFRelease(property_list);
    if (error) CFRelease(error);
    atomic_store_explicit(
        &xpcui_interception_enabled,
        xpcui_interception_rule_count > 0,
        memory_order_relaxed
    );
}

static bool xpcui_next_key_path_segment(
    const char **cursor,
    char segment[XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY],
    bool *is_last
) {
    const char *separator = strchr(*cursor, '.');
    size_t length = separator ? (size_t)(separator - *cursor) : strlen(*cursor);
    if (length == 0 || length >= XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY) {
        return false;
    }
    memcpy(segment, *cursor, length);
    segment[length] = '\0';
    *is_last = !separator;
    *cursor = separator ? separator + 1 : *cursor + length;
    return true;
}

static xpc_object_t xpcui_dictionary_get_key_path(xpc_object_t dictionary, const char *key_path) {
    xpc_object_t current = dictionary;
    const char *cursor = key_path;
    for (size_t depth = 0; depth < XPCUI_INTERCEPTION_KEY_PATH_DEPTH; depth++) {
        char segment[XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY] = {0};
        bool is_last = false;
        if (!current
            || xpc_get_type(current) != XPC_TYPE_DICTIONARY
            || !xpcui_next_key_path_segment(&cursor, segment, &is_last)) {
            return NULL;
        }
        current = xpc_dictionary_get_value(current, segment);
        if (is_last) {
            return current;
        }
    }
    return NULL;
}

static bool xpcui_dictionary_has_key_path_parent(xpc_object_t dictionary, const char *key_path) {
    xpc_object_t current = dictionary;
    const char *cursor = key_path;
    for (size_t depth = 0; depth < XPCUI_INTERCEPTION_KEY_PATH_DEPTH; depth++) {
        char segment[XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY] = {0};
        bool is_last = false;
        if (!current
            || xpc_get_type(current) != XPC_TYPE_DICTIONARY
            || !xpcui_next_key_path_segment(&cursor, segment, &is_last)) {
            return false;
        }
        if (is_last) {
            return true;
        }
        current = xpc_dictionary_get_value(current, segment);
    }
    return false;
}

static bool xpcui_dictionary_set_replacement(
    xpc_object_t dictionary,
    const xpcui_interception_rule_t *rule
) {
    xpc_object_t current = dictionary;
    const char *cursor = rule->replacement_key;
    for (size_t depth = 0; depth < XPCUI_INTERCEPTION_KEY_PATH_DEPTH; depth++) {
        char segment[XPCUI_INTERCEPTION_KEY_SEGMENT_CAPACITY] = {0};
        bool is_last = false;
        if (!current
            || xpc_get_type(current) != XPC_TYPE_DICTIONARY
            || !xpcui_next_key_path_segment(&cursor, segment, &is_last)) {
            return false;
        }
        if (is_last) {
            switch (rule->replacement_type) {
                case XPCUI_INTERCEPTION_REPLACEMENT_STRING:
                    xpc_dictionary_set_string(current, segment, rule->replacement_value);
                    return true;
                case XPCUI_INTERCEPTION_REPLACEMENT_BOOL:
                    xpc_dictionary_set_bool(current, segment, rule->replacement_bool_value);
                    return true;
                case XPCUI_INTERCEPTION_REPLACEMENT_INT64:
                    xpc_dictionary_set_int64(current, segment, rule->replacement_int64_value);
                    return true;
                case XPCUI_INTERCEPTION_REPLACEMENT_UINT64:
                    xpc_dictionary_set_uint64(current, segment, rule->replacement_uint64_value);
                    return true;
                case XPCUI_INTERCEPTION_REPLACEMENT_DOUBLE:
                    xpc_dictionary_set_double(current, segment, rule->replacement_double_value);
                    return true;
            }
        }
        xpc_object_t child = xpc_dictionary_get_value(current, segment);
        if (!child || xpc_get_type(child) != XPC_TYPE_DICTIONARY) {
            return false;
        }
        xpc_object_t child_copy = xpc_copy(child);
        if (!child_copy) {
            return false;
        }
        xpc_dictionary_set_value(current, segment, child_copy);
        current = child_copy;
        xpc_release(child_copy);
    }
    return false;
}

static xpcui_interception_result_t xpcui_apply_interception(
    xpc_object_t message,
    const char *direction,
    const char *operation,
    const void *endpoint,
    const char *fallback_name
) {
    xpcui_interception_result_t result = {.message = message};
    if (!message
        || !atomic_load_explicit(&xpcui_interception_enabled, memory_order_relaxed)
        || xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
        return result;
    }
    char *service_name = xpcui_copy_service_name(endpoint, fallback_name);
    if (!service_name) {
        return result;
    }
    for (size_t index = 0; index < xpcui_interception_rule_count; index++) {
        xpcui_interception_rule_t *rule = &xpcui_interception_rules[index];
        if (strcmp(rule->service_name, service_name) != 0
            || strcmp(rule->direction, direction) != 0
            || strcmp(rule->operation, operation) != 0) {
            continue;
        }
        if (rule->match_key[0] != '\0') {
            xpc_object_t value = xpcui_dictionary_get_key_path(result.message, rule->match_key);
            if (!value
                || xpc_get_type(value) != XPC_TYPE_STRING
                || strcmp(xpc_string_get_string_ptr(value), rule->match_string_value) != 0) {
                continue;
            }
        }
        if (!xpcui_dictionary_has_key_path_parent(result.message, rule->replacement_key)) {
            continue;
        }
        if (!result.owns_message) {
            result.message = xpc_copy(message);
            if (!result.message) {
                break;
            }
            result.owns_message = true;
        }
        if (xpcui_dictionary_set_replacement(result.message, rule)
            && result.rule_count < XPCUI_INTERCEPTION_RULE_CAPACITY) {
            result.rule_ids[result.rule_count++] = rule->id;
        }
    }
    free(service_name);
    return result;
}

static void xpcui_release_interception_result(xpcui_interception_result_t *result) {
    if (result->owns_message && result->message) {
        xpc_release(result->message);
    }
    *result = (xpcui_interception_result_t){0};
}

static void xpcui_release_pending(xpcui_pending_event_t *event);

static xpc_object_t xpcui_copy_payload_snapshot(xpc_object_t payload, bool *used_fallback) {
    *used_fallback = false;
    if (!payload) {
        return NULL;
    }
    xpc_object_t snapshot = xpc_copy(payload);
    if (snapshot) {
        return snapshot;
    }
    *used_fallback = true;
    return xpc_retain(payload);
}

static char **xpcui_copy_interception_rule_ids(
    const char * const *rule_ids,
    size_t rule_count,
    size_t *copied_rule_count
) {
    *copied_rule_count = 0;
    if (!rule_ids || rule_count == 0) {
        return NULL;
    }
    char **copies = calloc(rule_count, sizeof(char *));
    if (!copies) {
        return NULL;
    }
    for (size_t index = 0; index < rule_count; index++) {
        copies[index] = strdup(rule_ids[index]);
        if (!copies[index]) {
            break;
        }
        (*copied_rule_count)++;
    }
    if (*copied_rule_count == 0) {
        free(copies);
        return NULL;
    }
    return copies;
}

static void xpcui_enqueue_named_with_interception(
    xpc_object_t payload,
    const char *direction,
    const char *operation,
    const void *endpoint,
    const char *fallback_name,
    const char * const *interception_rule_ids,
    size_t interception_rule_count
) {
    if (!xpcui_enabled) {
        return;
    }
    bool payload_snapshot_fallback = false;
    xpcui_pending_event_t event = {
        .payload = xpcui_copy_payload_snapshot(payload, &payload_snapshot_fallback),
        .payload_snapshot_fallback = payload_snapshot_fallback,
        .direction = strdup(direction),
        .operation = strdup(operation),
        .service_name = xpcui_copy_service_name(endpoint, fallback_name),
        .sequence = atomic_fetch_add_explicit(&xpcui_sequence, 1, memory_order_relaxed) + 1,
        .timestamp = xpcui_monotonic_nanoseconds(),
        .thread_id = xpcui_thread_id(),
    };
    event.interception_rule_ids = xpcui_copy_interception_rule_ids(
        interception_rule_ids,
        interception_rule_count,
        &event.interception_rule_count
    );
    if (pthread_mutex_trylock(&xpcui_queue_lock) != 0) {
        xpcui_release_pending(&event);
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
        return;
    }
    if (xpcui_queue_count >= XPCUI_QUEUE_CAPACITY) {
        pthread_mutex_unlock(&xpcui_queue_lock);
        xpcui_release_pending(&event);
        atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
        return;
    }
    xpcui_queue[xpcui_queue_tail] = event;
    xpcui_queue_tail = (xpcui_queue_tail + 1) % XPCUI_QUEUE_CAPACITY;
    xpcui_queue_count++;
    pthread_cond_signal(&xpcui_queue_ready);
    pthread_mutex_unlock(&xpcui_queue_lock);
}

static void xpcui_enqueue_named(
    xpc_object_t payload,
    const char *direction,
    const char *operation,
    const void *endpoint,
    const char *fallback_name
) {
    xpcui_enqueue_named_with_interception(payload, direction, operation, endpoint, fallback_name, NULL, 0);
}

static void xpcui_enqueue(xpc_object_t payload, const char *direction, const char *operation, xpc_connection_t connection) {
    if (!xpcui_enabled) {
        return;
    }
    const char *fallback_name = connection ? xpc_connection_get_name(connection) : NULL;
    xpcui_enqueue_named(payload, direction, operation, connection, fallback_name);
}

static void xpcui_enqueue_intercepted(
    xpc_object_t payload,
    const char *direction,
    const char *operation,
    xpc_connection_t connection,
    const char * const *interception_rule_ids,
    size_t interception_rule_count
) {
    if (!xpcui_enabled) {
        return;
    }
    const char *fallback_name = connection ? xpc_connection_get_name(connection) : NULL;
    xpcui_enqueue_named_with_interception(
        payload,
        direction,
        operation,
        connection,
        fallback_name,
        interception_rule_ids,
        interception_rule_count
    );
}

void xpcui_trace_optional_lifecycle(const char *operation, const char *service_name) {
    xpcui_enqueue_named(NULL, "lifecycle", operation, NULL, service_name);
}

#if defined(XPC_TYPE_SESSION)
static void xpcui_enqueue_intercepted_session(
    xpc_object_t payload,
    const char *direction,
    const char *operation,
    xpc_session_t session,
    const char * const *interception_rule_ids,
    size_t interception_rule_count
) {
    xpcui_enqueue_named_with_interception(
        payload,
        direction,
        operation,
        session,
        NULL,
        interception_rule_ids,
        interception_rule_count
    );
}

static void xpcui_enqueue_session_error(
    xpc_rich_error_t error,
    const char *operation,
    xpc_session_t session,
    const char *fallback_name
) {
    if (error) {
        xpcui_enqueue_named((xpc_object_t)error, "incoming", operation, session, fallback_name);
    }
}
#endif

static bool xpcui_write_all(int socket_fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t result = send(socket_fd, cursor, length, MSG_NOSIGNAL);
        if (result <= 0) {
            return false;
        }
        cursor += result;
        length -= (size_t)result;
    }
    return true;
}

static bool xpcui_write_frame(int socket_fd, const char *bytes, size_t length) {
    if (length > XPCUI_MAX_FRAME_SIZE) {
        return false;
    }
    uint32_t network_length = htonl((uint32_t)length);
    return xpcui_write_all(socket_fd, &network_length, sizeof(network_length))
        && xpcui_write_all(socket_fd, bytes, length);
}

static bool xpcui_write_payload_sidecar(
    xpcui_pending_event_t *event,
    const char *bytes,
    size_t length,
    char *filename,
    size_t filename_capacity
) {
    if (!xpcui_blobs_path) {
        return false;
    }
    snprintf(filename, filename_capacity, "payload-%d-%llu.json", getpid(), event->sequence);
    char path[PATH_MAX] = {0};
    char temporary_path[PATH_MAX] = {0};
    if (snprintf(path, sizeof(path), "%s/%s", xpcui_blobs_path, filename) >= (int)sizeof(path)
        || snprintf(temporary_path, sizeof(temporary_path), "%s.tmp", path) >= (int)sizeof(temporary_path)) {
        return false;
    }
    int file = open(temporary_path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (file < 0) {
        return false;
    }
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(file, cursor, remaining);
        if (written <= 0) {
            close(file);
            unlink(temporary_path);
            return false;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
    if (close(file) != 0 || rename(temporary_path, path) != 0) {
        unlink(temporary_path);
        return false;
    }
    return true;
}

static int xpcui_connect(void) {
    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return -1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, xpcui_socket_path, sizeof(address.sun_path));
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socket_fd);
        return -1;
    }
    xpcui_buffer_t authentication = {0};
    xpcui_buffer_append(&authentication, "{\"authToken\":");
    xpcui_buffer_append_json_string(&authentication, xpcui_auth_token);
    xpcui_buffer_append(&authentication, "}");
    bool wrote_authentication = xpcui_write_frame(socket_fd, authentication.data, authentication.length);
    free(authentication.data);
    if (!wrote_authentication) {
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static char *xpcui_event_json(xpcui_pending_event_t *event, size_t *length) {
    xpcui_buffer_t payload = {0};
    xpcui_serialize_object(&payload, event->payload, 0);
    char sidecar_filename[128] = {0};
    bool externalized = payload.length > XPCUI_LAZY_PAYLOAD_THRESHOLD
        && xpcui_write_payload_sidecar(event, payload.data, payload.length, sidecar_filename, sizeof(sidecar_filename));
    xpcui_buffer_t buffer = {0};
    xpcui_buffer_append(&buffer, "{\"schemaVersion\":1,\"sessionID\":");
    xpcui_buffer_append_json_string(&buffer, xpcui_session_id);
    xpcui_buffer_append_format(
        &buffer,
        ",\"sequence\":%llu,\"monotonicTimestamp\":%llu,\"pid\":%d,\"parentPID\":%d,\"threadID\":%llu",
        event->sequence,
        event->timestamp,
        getpid(),
        getppid(),
        event->thread_id
    );
    xpcui_buffer_append(&buffer, ",\"source\":\"injected-xpc\",\"category\":\"xpc\",\"direction\":");
    xpcui_buffer_append_json_string(&buffer, event->direction);
    xpcui_buffer_append(&buffer, ",\"operation\":");
    xpcui_buffer_append_json_string(&buffer, event->operation);
    xpcui_buffer_append(&buffer, ",\"serviceName\":");
    if (event->service_name && event->service_name[0] != '\0') {
        xpcui_buffer_append_json_string(&buffer, event->service_name);
    } else {
        xpcui_buffer_append(&buffer, "null");
    }
    xpcui_buffer_append(&buffer, ",\"summary\":");
    xpcui_buffer_append_json_string(&buffer, event->operation);
    xpcui_buffer_append(&buffer, ",\"payload\":");
    if (externalized) {
        xpcui_buffer_append_format(&buffer, "{\"type\":\"lazy-json\",\"encoding\":\"json\",\"length\":%zu,\"blobReference\":", payload.length);
        xpcui_buffer_append_json_string(&buffer, sidecar_filename);
        xpcui_buffer_append(&buffer, "}");
    } else {
        xpcui_buffer_append_bytes(&buffer, payload.data, payload.length);
    }
    xpcui_buffer_append(&buffer, ",\"diagnostics\":[");
    bool has_diagnostic = false;
    if (event->payload_snapshot_fallback) {
        xpcui_buffer_append(&buffer, "\"payload-snapshot-fallback\"");
        has_diagnostic = true;
    }
    for (size_t index = 0; index < event->interception_rule_count; index++) {
        if (has_diagnostic) xpcui_buffer_append(&buffer, ",");
        char diagnostic[XPCUI_INTERCEPTION_KEY_PATH_CAPACITY + 32] = {0};
        snprintf(diagnostic, sizeof(diagnostic), "intercepted-rule:%s", event->interception_rule_ids[index]);
        xpcui_buffer_append_json_string(&buffer, diagnostic);
        has_diagnostic = true;
    }
    xpcui_buffer_append(&buffer, "]");
    xpcui_buffer_append_format(
        &buffer,
        ",\"droppedEventCount\":%llu}",
        atomic_load_explicit(&xpcui_dropped, memory_order_relaxed)
    );
    free(payload.data);
    *length = buffer.length;
    return buffer.data;
}

static bool xpcui_dequeue(xpcui_pending_event_t *event) {
    pthread_mutex_lock(&xpcui_queue_lock);
    while (xpcui_queue_count == 0) {
        struct timespec deadline = {0};
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += 1;
        if (pthread_cond_timedwait(&xpcui_queue_ready, &xpcui_queue_lock, &deadline) == ETIMEDOUT
            && xpcui_queue_count == 0) {
            pthread_mutex_unlock(&xpcui_queue_lock);
            return false;
        }
    }
    *event = xpcui_queue[xpcui_queue_head];
    xpcui_queue_head = (xpcui_queue_head + 1) % XPCUI_QUEUE_CAPACITY;
    xpcui_queue_count--;
    pthread_mutex_unlock(&xpcui_queue_lock);
    return true;
}

static void xpcui_release_pending(xpcui_pending_event_t *event) {
    if (event->payload) xpc_release(event->payload);
    free(event->direction);
    free(event->operation);
    free(event->service_name);
    for (size_t index = 0; index < event->interception_rule_count; index++) {
        free(event->interception_rule_ids[index]);
    }
    free(event->interception_rule_ids);
}

static void *xpcui_worker(void *context) {
    (void)context;
    int socket_fd = -1;
    uint64_t reported_dropped = 0;
    while (true) {
        xpcui_pending_event_t event = {0};
        bool has_event = xpcui_dequeue(&event);
        uint64_t dropped = atomic_load_explicit(&xpcui_dropped, memory_order_relaxed);
        if (!has_event && dropped <= reported_dropped) {
            continue;
        }
        if (!has_event) {
            event.direction = strdup("diagnostic");
            event.operation = strdup("dropped-events");
            event.service_name = strdup("");
            event.sequence = atomic_fetch_add_explicit(&xpcui_sequence, 1, memory_order_relaxed) + 1;
            event.timestamp = xpcui_monotonic_nanoseconds();
            event.thread_id = xpcui_thread_id();
        }
        if (socket_fd < 0) {
            socket_fd = xpcui_connect();
        }
        size_t length = 0;
        char *json = xpcui_event_json(&event, &length);
        bool wrote = socket_fd >= 0 && json && xpcui_write_frame(socket_fd, json, length);
        if (!wrote) {
            atomic_fetch_add_explicit(&xpcui_dropped, 1, memory_order_relaxed);
            if (socket_fd >= 0) close(socket_fd);
            socket_fd = -1;
        } else {
            reported_dropped = atomic_load_explicit(&xpcui_dropped, memory_order_relaxed);
        }
        free(json);
        xpcui_release_pending(&event);
    }
    return NULL;
}

__attribute__((constructor))
static void xpcui_initialize(void) {
    xpcui_session_id = getenv("XPCUI_SESSION_ID");
    xpcui_auth_token = getenv("XPCUI_AUTH_TOKEN");
    xpcui_socket_path = getenv("XPCUI_SOCKET_PATH");
    xpcui_blobs_path = getenv("XPCUI_BLOBS_PATH");
    if (!xpcui_session_id || !xpcui_auth_token || !xpcui_socket_path) {
        return;
    }
    xpcui_load_interception_rules();
    xpcui_enabled = true;
    pthread_t worker;
    if (pthread_create(&worker, NULL, xpcui_worker, NULL) == 0) {
        pthread_detach(worker);
        xpcui_install_optional_adapters();
    } else {
        xpcui_enabled = false;
    }
}

xpc_connection_t xpcui_connection_create(const char *name, dispatch_queue_t queue) {
    xpc_connection_t connection = xpc_connection_create(name, queue);
    xpcui_remember_service_name(connection, name);
    xpcui_enqueue(NULL, "lifecycle", "connection-create", connection);
    return connection;
}

xpc_connection_t xpcui_connection_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags) {
    xpc_connection_t connection = xpc_connection_create_mach_service(name, queue, flags);
    xpcui_remember_service_name(connection, name);
    xpcui_enqueue(NULL, "lifecycle", "mach-service-create", connection);
    return connection;
}

void xpcui_connection_set_event_handler(xpc_connection_t connection, xpc_handler_t handler) {
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        xpcui_interception_result_t interception = xpcui_apply_interception(
            event,
            "incoming",
            "receive",
            connection,
            xpc_connection_get_name(connection)
        );
        xpcui_enqueue_intercepted(
            interception.message,
            "incoming",
            "receive",
            connection,
            interception.rule_ids,
            interception.rule_count
        );
        handler(interception.message);
        xpcui_release_interception_result(&interception);
    });
}

void xpcui_connection_send_message(xpc_connection_t connection, xpc_object_t message) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "send",
        connection,
        xpc_connection_get_name(connection)
    );
    xpcui_enqueue_intercepted(
        interception.message,
        "outgoing",
        "send",
        connection,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_connection_send_message(connection, interception.message);
    xpcui_release_interception_result(&interception);
}

void xpcui_connection_send_message_with_reply(
    xpc_connection_t connection,
    xpc_object_t message,
    dispatch_queue_t reply_queue,
    xpc_handler_t handler
) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "send-with-reply",
        connection,
        xpc_connection_get_name(connection)
    );
    xpcui_enqueue_intercepted(
        interception.message,
        "outgoing",
        "send-with-reply",
        connection,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_connection_send_message_with_reply(connection, interception.message, reply_queue, ^(xpc_object_t reply) {
        xpcui_interception_result_t reply_interception = xpcui_apply_interception(
            reply,
            "incoming",
            "reply",
            connection,
            xpc_connection_get_name(connection)
        );
        xpcui_enqueue_intercepted(
            reply_interception.message,
            "incoming",
            "reply",
            connection,
            reply_interception.rule_ids,
            reply_interception.rule_count
        );
        handler(reply_interception.message);
        xpcui_release_interception_result(&reply_interception);
    });
    xpcui_release_interception_result(&interception);
}

xpc_object_t xpcui_connection_send_message_with_reply_sync(xpc_connection_t connection, xpc_object_t message) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "send-with-reply-sync",
        connection,
        xpc_connection_get_name(connection)
    );
    xpcui_enqueue_intercepted(
        interception.message,
        "outgoing",
        "send-with-reply-sync",
        connection,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, interception.message);
    xpcui_release_interception_result(&interception);
    xpcui_interception_result_t reply_interception = xpcui_apply_interception(
        reply,
        "incoming",
        "reply-sync",
        connection,
        xpc_connection_get_name(connection)
    );
    xpcui_enqueue_intercepted(
        reply_interception.message,
        "incoming",
        "reply-sync",
        connection,
        reply_interception.rule_ids,
        reply_interception.rule_count
    );
    if (reply_interception.owns_message) {
        xpc_release(reply);
        reply = reply_interception.message;
        reply_interception.owns_message = false;
    }
    return reply;
}

#if defined(XPC_TYPE_SESSION)
xpc_session_t xpcui_session_create_xpc_service(
    const char *name,
    dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags,
    xpc_rich_error_t *error_out
) {
    xpc_session_t session = xpc_session_create_xpc_service(name, target_queue, flags, error_out);
    xpcui_remember_service_name(session, name);
    xpcui_enqueue_named(NULL, "lifecycle", "session-xpc-service-create", session, name);
    if (error_out) xpcui_enqueue_session_error(*error_out, "session-create-error", session, name);
    return session;
}

xpc_session_t xpcui_session_create_mach_service(
    const char *mach_service,
    dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags,
    xpc_rich_error_t *error_out
) {
    xpc_session_t session = xpc_session_create_mach_service(mach_service, target_queue, flags, error_out);
    xpcui_remember_service_name(session, mach_service);
    xpcui_enqueue_named(NULL, "lifecycle", "session-mach-service-create", session, mach_service);
    if (error_out) xpcui_enqueue_session_error(*error_out, "session-create-error", session, mach_service);
    return session;
}

void xpcui_session_set_incoming_message_handler(
    xpc_session_t session,
    xpc_session_incoming_message_handler_t handler
) {
    xpc_session_set_incoming_message_handler(session, ^(xpc_object_t message) {
        xpcui_interception_result_t interception = xpcui_apply_interception(
            message,
            "incoming",
            "session-receive",
            session,
            NULL
        );
        xpcui_enqueue_intercepted_session(
            interception.message,
            "incoming",
            "session-receive",
            session,
            interception.rule_ids,
            interception.rule_count
        );
        handler(interception.message);
        xpcui_release_interception_result(&interception);
    });
}

xpc_rich_error_t xpcui_session_send_message(xpc_session_t session, xpc_object_t message) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "session-send",
        session,
        NULL
    );
    xpcui_enqueue_intercepted_session(
        interception.message,
        "outgoing",
        "session-send",
        session,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_rich_error_t error = xpc_session_send_message(session, interception.message);
    xpcui_release_interception_result(&interception);
    xpcui_enqueue_session_error(error, "session-send-error", session, NULL);
    return error;
}

void xpcui_session_send_message_with_reply_async(
    xpc_session_t session,
    xpc_object_t message,
    xpc_session_reply_handler_t reply_handler
) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "session-send-with-reply",
        session,
        NULL
    );
    xpcui_enqueue_intercepted_session(
        interception.message,
        "outgoing",
        "session-send-with-reply",
        session,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_session_send_message_with_reply_async(session, interception.message, ^(xpc_object_t reply, xpc_rich_error_t error) {
        xpcui_interception_result_t reply_interception = xpcui_apply_interception(
            reply,
            "incoming",
            "session-reply",
            session,
            NULL
        );
        if (reply) {
            xpcui_enqueue_intercepted_session(
                reply_interception.message,
                "incoming",
                "session-reply",
                session,
                reply_interception.rule_ids,
                reply_interception.rule_count
            );
        }
        xpcui_enqueue_session_error(error, "session-reply-error", session, NULL);
        reply_handler(reply_interception.message, error);
        xpcui_release_interception_result(&reply_interception);
    });
    xpcui_release_interception_result(&interception);
}

xpc_object_t xpcui_session_send_message_with_reply_sync(
    xpc_session_t session,
    xpc_object_t message,
    xpc_rich_error_t *error_out
) {
    xpcui_interception_result_t interception = xpcui_apply_interception(
        message,
        "outgoing",
        "session-send-with-reply-sync",
        session,
        NULL
    );
    xpcui_enqueue_intercepted_session(
        interception.message,
        "outgoing",
        "session-send-with-reply-sync",
        session,
        interception.rule_ids,
        interception.rule_count
    );
    xpc_object_t reply = xpc_session_send_message_with_reply_sync(session, interception.message, error_out);
    xpcui_release_interception_result(&interception);
    xpcui_interception_result_t reply_interception = xpcui_apply_interception(
        reply,
        "incoming",
        "session-reply-sync",
        session,
        NULL
    );
    if (reply) {
        xpcui_enqueue_intercepted_session(
            reply_interception.message,
            "incoming",
            "session-reply-sync",
            session,
            reply_interception.rule_ids,
            reply_interception.rule_count
        );
    }
    if (reply_interception.owns_message) {
        xpc_release(reply);
        reply = reply_interception.message;
        reply_interception.owns_message = false;
    }
    if (error_out) xpcui_enqueue_session_error(*error_out, "session-reply-sync-error", session, NULL);
    return reply;
}
#endif

#define XPCUI_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    xpcui_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&replacee \
    }

XPCUI_INTERPOSE(xpcui_connection_create, xpc_connection_create);
XPCUI_INTERPOSE(xpcui_connection_create_mach_service, xpc_connection_create_mach_service);
XPCUI_INTERPOSE(xpcui_connection_set_event_handler, xpc_connection_set_event_handler);
XPCUI_INTERPOSE(xpcui_connection_send_message, xpc_connection_send_message);
XPCUI_INTERPOSE(xpcui_connection_send_message_with_reply, xpc_connection_send_message_with_reply);
XPCUI_INTERPOSE(xpcui_connection_send_message_with_reply_sync, xpc_connection_send_message_with_reply_sync);
#if defined(XPC_TYPE_SESSION)
XPCUI_INTERPOSE(xpcui_session_create_xpc_service, xpc_session_create_xpc_service);
XPCUI_INTERPOSE(xpcui_session_create_mach_service, xpc_session_create_mach_service);
XPCUI_INTERPOSE(xpcui_session_set_incoming_message_handler, xpc_session_set_incoming_message_handler);
XPCUI_INTERPOSE(xpcui_session_send_message, xpc_session_send_message);
XPCUI_INTERPOSE(xpcui_session_send_message_with_reply_async, xpc_session_send_message_with_reply_async);
XPCUI_INTERPOSE(xpcui_session_send_message_with_reply_sync, xpc_session_send_message_with_reply_sync);
#endif
