#include <dispatch/dispatch.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

static const char *xpcui_fixture_service_name = "com.jonluca.xpcui.fixture.mach-service";

static xpc_object_t xpcui_fixture_response(void) {
    xpc_object_t response = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(response, "label", "service-original");
    xpc_dictionary_set_bool(response, "enabled", false);
    xpc_dictionary_set_int64(response, "signed", -11);
    xpc_dictionary_set_uint64(response, "unsigned", 11);
    xpc_dictionary_set_double(response, "ratio", 1.5);
    return response;
}

static void xpcui_fixture_handle_message(xpc_connection_t peer, xpc_object_t message) {
    const char *kind = xpc_dictionary_get_string(message, "kind");
    if (!kind || strcmp(kind, "no-reply") == 0) {
        return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) {
        return;
    }
    xpc_dictionary_set_string(reply, "status", "ok");
    xpc_dictionary_set_string(reply, "echoKind", kind);
    xpc_dictionary_set_int64(reply, "servicePID", getpid());

    xpc_object_t probe = xpc_dictionary_get_value(message, "probe");
    if (probe) {
        xpc_dictionary_set_value(reply, "received", probe);
    }
    xpc_object_t response = xpcui_fixture_response();
    xpc_dictionary_set_value(reply, "response", response);
    xpc_release(response);

    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

static void xpcui_fixture_handle_connection(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
            xpcui_fixture_handle_message(peer, message);
        }
    });
    xpc_connection_resume(peer);
}

int main(void) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        xpcui_fixture_service_name,
        dispatch_get_main_queue(),
        XPC_CONNECTION_MACH_SERVICE_LISTENER
    );
    if (!listener) {
        return 69;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
            xpcui_fixture_handle_connection(peer);
        }
    });
    xpc_connection_resume(listener);
    dispatch_main();
    return 0;
}
