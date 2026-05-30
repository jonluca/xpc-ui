#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdlib.h>
#include <string.h>

#import "XPCTraceOptionalAdapters.h"

static const char *xpcui_optional_adapters_environment = "XPCUI_OPTIONAL_ADAPTERS";

typedef void (*xpcui_optional_adapter_installer_t)(void);

typedef struct {
    const char *name;
    xpcui_optional_adapter_installer_t install;
} xpcui_optional_adapter_t;

static bool xpcui_optional_adapter_enabled(const char *adapter_name) {
    const char *configured = getenv(xpcui_optional_adapters_environment);
    if (!configured) {
        return false;
    }
    char *copy = strdup(configured);
    char *state = NULL;
    for (char *token = strtok_r(copy, ",", &state); token; token = strtok_r(NULL, ",", &state)) {
        if (strcmp(token, adapter_name) == 0) {
            free(copy);
            return true;
        }
    }
    free(copy);
    return false;
}

static void xpcui_swizzle_instance_method(Class class, SEL original_selector, SEL replacement_selector) {
    Method original_method = class_getInstanceMethod(class, original_selector);
    Method replacement_method = class_getInstanceMethod(class, replacement_selector);
    if (original_method && replacement_method) {
        method_exchangeImplementations(original_method, replacement_method);
    }
}

@implementation NSXPCConnection (XPCUIOptionalLifecycleAdapter)

- (instancetype)xpcui_initWithServiceName:(NSString *)service_name {
    id connection = [self xpcui_initWithServiceName:service_name];
    xpcui_trace_optional_lifecycle("nsxpc-service-create", service_name.UTF8String);
    return connection;
}

- (instancetype)xpcui_initWithMachServiceName:(NSString *)service_name
                                      options:(NSXPCConnectionOptions)options {
    id connection = [self xpcui_initWithMachServiceName:service_name options:options];
    xpcui_trace_optional_lifecycle("nsxpc-mach-service-create", service_name.UTF8String);
    return connection;
}

- (instancetype)xpcui_initWithListenerEndpoint:(NSXPCListenerEndpoint *)endpoint {
    id connection = [self xpcui_initWithListenerEndpoint:endpoint];
    xpcui_trace_optional_lifecycle("nsxpc-listener-endpoint-create", NULL);
    return connection;
}

@end

static void xpcui_install_nsxpc_lifecycle_adapter(void) {
    Class connection_class = NSXPCConnection.class;
    xpcui_swizzle_instance_method(
        connection_class,
        @selector(initWithServiceName:),
        @selector(xpcui_initWithServiceName:)
    );
    xpcui_swizzle_instance_method(
        connection_class,
        @selector(initWithMachServiceName:options:),
        @selector(xpcui_initWithMachServiceName:options:)
    );
    xpcui_swizzle_instance_method(
        connection_class,
        @selector(initWithListenerEndpoint:),
        @selector(xpcui_initWithListenerEndpoint:)
    );
    xpcui_trace_optional_lifecycle("nsxpc-lifecycle-adapter-enabled", NULL);
}

void xpcui_install_optional_adapters(void) {
    static const xpcui_optional_adapter_t adapters[] = {
        {"nsxpc-lifecycle", xpcui_install_nsxpc_lifecycle_adapter},
    };
    for (size_t index = 0; index < sizeof(adapters) / sizeof(adapters[0]); index++) {
        if (xpcui_optional_adapter_enabled(adapters[index].name)) {
            adapters[index].install();
        }
    }
}
