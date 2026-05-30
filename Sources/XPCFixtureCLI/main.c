#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

extern char **environ;

static const char *xpcui_fixture_cli_service = "com.apple.cfprefsd.agent";

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

static xpc_connection_t xpcui_emit_xpc_traffic(const char *role) {
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
