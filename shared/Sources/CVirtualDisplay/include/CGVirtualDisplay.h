// Private CoreGraphics virtual-display API (ADR-0006). Not in the public SDK.
// Declarations match what DeskPad and other open-source tools use. Every class is weak-imported:
// if Apple removes one, the app still launches, `CVDAvailable()` returns false and the host falls
// back to mirroring the built-in display (docs/adr/0006).
#pragma once
#include <TargetConditionals.h>

#if TARGET_OS_OSX
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property (strong, nullable) dispatch_queue_t queue;
@property (copy) NSString *name;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property unsigned int serialNum;
@property unsigned int productID;
@property unsigned int vendorID;
@property (copy, nullable) void (^terminationHandler)(id _Nullable display, id _Nullable reason);
@end

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
@property (readonly) unsigned int width;
@property (readonly) unsigned int height;
@property (readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property (strong) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

/// True when all four classes exist at runtime.
static inline BOOL CVDAvailable(void) {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil;
}

NS_ASSUME_NONNULL_END
#endif
