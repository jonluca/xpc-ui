#ifndef XPCUI_NATIVE_SNAPSHOT_H
#define XPCUI_NATIVE_SNAPSHOT_H

#include <sys/types.h>

#ifdef __OBJC__
#import "../EndpointSecurityBridge/EndpointSecurityBridge.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

char *XPCUICopyProcessSnapshotJSON(pid_t pid);
char *XPCUICopyProcessTreeJSON(pid_t rootPID);
void XPCUIFreeCString(char *string);

#ifdef __cplusplus
}
#endif

#endif
