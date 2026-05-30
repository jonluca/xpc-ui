#include <dispatch/dispatch.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

static void handle_message(xpc_connection_t peer, xpc_object_t message) {
    const char *kind = xpc_dictionary_get_string(message, "kind");
    if (!kind) {
        return;
    }
    if (strcmp(kind, "error") == 0) {
        return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) {
        return;
    }
    xpc_dictionary_set_string(reply, "status", "ok");
    xpc_dictionary_set_string(reply, "echoKind", kind);
    xpc_dictionary_set_int64(reply, "servicePID", getpid());
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

static void handle_connection(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
            handle_message(peer, message);
        }
    });
    xpc_connection_resume(peer);
}

int main(void) {
    xpc_main(handle_connection);
    return 0;
}
