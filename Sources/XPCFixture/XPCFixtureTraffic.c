#include "XPCFixtureTraffic.h"

#include <unistd.h>
#include <xpc/xpc.h>

static const char *xpcui_fixture_service_name = "com.jonluca.xpcui.fixture.service";

static xpc_object_t xpcui_fixture_message(const char *kind, const char *message) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(payload, "kind", kind);
    xpc_dictionary_set_string(payload, "transport", "xpc_session");
    if (message) {
        xpc_dictionary_set_string(payload, "message", message);
    }
    return payload;
}

void xpcui_fixture_send_session_traffic(void) {
    xpc_rich_error_t creation_error = NULL;
    xpc_session_t session = xpc_session_create_xpc_service(
        xpcui_fixture_service_name,
        NULL,
        XPC_SESSION_CREATE_NONE,
        &creation_error
    );
    if (!session) {
        if (creation_error) xpc_release(creation_error);
        return;
    }

    xpc_object_t async_message = xpcui_fixture_message("session-async", "async session round trip");
    xpc_session_send_message_with_reply_async(session, async_message, ^(xpc_object_t reply, xpc_rich_error_t error) {
        (void)reply;
        (void)error;
    });
    xpc_release(async_message);

    xpc_object_t sync_message = xpcui_fixture_message("session-sync", "synchronous session round trip");
    xpc_rich_error_t sync_error = NULL;
    xpc_object_t sync_reply = xpc_session_send_message_with_reply_sync(session, sync_message, &sync_error);
    if (sync_reply) xpc_release(sync_reply);
    if (sync_error) xpc_release(sync_error);
    xpc_release(sync_message);

    xpc_object_t one_way_message = xpcui_fixture_message("error", NULL);
    xpc_rich_error_t send_error = xpc_session_send_message(session, one_way_message);
    if (send_error) xpc_release(send_error);
    xpc_release(one_way_message);

    usleep(20000);
    xpc_session_cancel(session);
    xpc_release(session);
}
