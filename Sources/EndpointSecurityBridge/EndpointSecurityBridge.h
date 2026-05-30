#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void XPCUIEndpointSecurityStart(
    NSString *sessionID,
    NSString *authToken,
    NSString *socketPath,
    NSArray<NSNumber *> *trackedPIDs
);
void XPCUIEndpointSecurityUpdateTrackedPIDs(NSArray<NSNumber *> *trackedPIDs);
void XPCUIEndpointSecurityStop(void);

NS_ASSUME_NONNULL_END
