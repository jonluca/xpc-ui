#ifndef XPCUI_NATIVE_SNAPSHOT_H
#define XPCUI_NATIVE_SNAPSHOT_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

char *XPCUICopyProcessSnapshotJSON(pid_t pid);
void XPCUIFreeCString(char *string);

#ifdef __cplusplus
}
#endif

#endif
