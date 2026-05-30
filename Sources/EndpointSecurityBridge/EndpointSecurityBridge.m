#import "EndpointSecurityBridge.h"

#import <dispatch/dispatch.h>
#import <xpc/xpc.h>

static const char *XPCUIMachServiceName = "com.jonluca.xpcui.endpoint-security";

static xpc_connection_t XPCUIEndpointSecurityConnection(void) {
    static xpc_connection_t connection;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        connection = xpc_connection_create_mach_service(
            XPCUIMachServiceName,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
            0
        );
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
            (void)event;
        });
        xpc_connection_resume(connection);
    });
    return connection;
}

static xpc_object_t XPCUITrackedPIDs(NSArray<NSNumber *> *trackedPIDs) {
    xpc_object_t array = xpc_array_create(NULL, 0);
    for (NSNumber *pid in trackedPIDs) {
        xpc_array_set_int64(array, XPC_ARRAY_APPEND, pid.intValue);
    }
    return array;
}

static void XPCUISendCommand(NSString *command, NSArray<NSNumber *> *trackedPIDs) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", command.UTF8String);
    xpc_object_t pids = XPCUITrackedPIDs(trackedPIDs);
    xpc_dictionary_set_value(message, "trackedPIDs", pids);
    xpc_connection_send_message(XPCUIEndpointSecurityConnection(), message);
}

void XPCUIEndpointSecurityStart(
    NSString *sessionID,
    NSString *authToken,
    NSString *socketPath,
    NSArray<NSNumber *> *trackedPIDs
) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "start");
    xpc_dictionary_set_string(message, "sessionID", sessionID.UTF8String);
    xpc_dictionary_set_string(message, "authToken", authToken.UTF8String);
    xpc_dictionary_set_string(message, "socketPath", socketPath.UTF8String);
    xpc_object_t pids = XPCUITrackedPIDs(trackedPIDs);
    xpc_dictionary_set_value(message, "trackedPIDs", pids);
    xpc_connection_send_message(XPCUIEndpointSecurityConnection(), message);
}

void XPCUIEndpointSecurityUpdateTrackedPIDs(NSArray<NSNumber *> *trackedPIDs) {
    XPCUISendCommand(@"update-tracked-pids", trackedPIDs);
}

void XPCUIEndpointSecurityStop(void) {
    XPCUISendCommand(@"stop", @[]);
}
