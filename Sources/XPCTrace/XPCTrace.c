#include <stdlib.h>

// The full interposition layer is added after the app shell compiles. Keeping
// an exported symbol makes this a valid injectable dylib at the first checkpoint.
__attribute__((visibility("default")))
int xpcui_trace_version(void) {
    return 1;
}
