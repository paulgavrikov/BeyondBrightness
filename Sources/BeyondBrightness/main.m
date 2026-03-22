#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <math.h>

typedef int32_t (*BBGetValueDoubleFn)(uint32_t displayID, double *value);
typedef int32_t (*BBSetValueDoubleFn)(uint32_t displayID, double value);
typedef int32_t (*BBGetValueFloatFn)(uint32_t displayID, float *value);
typedef int32_t (*BBSetValueFloatFn)(uint32_t displayID, float value);
typedef int32_t (*BBGetRangeFloatFn)(uint32_t displayID, float *minValue, float *maxValue);
typedef int32_t (*BBSetUInt32FloatFn)(uint32_t displayID, float value);
typedef int32_t (*BBSetUInt32DoubleFn)(uint32_t displayID, double value);

typedef NS_ENUM(NSInteger, BBStatusDisplayMode) {
    BBStatusDisplayModeIconAndPercentage = 0,
    BBStatusDisplayModeIconOnly = 1,
    BBStatusDisplayModeHidden = 2
};

static NSString * const BBStatusDisplayModeDefaultsKey = @"StatusDisplayMode";

@interface BBBrightnessSnapshot : NSObject
@property (nonatomic, assign) double normalizedBrightness;
@property (nonatomic, assign) double maximumBrightness;
@property (nonatomic, assign) BOOL supportsExtendedBrightness;
@property (nonatomic, assign) NSInteger percentage;
@property (nonatomic, copy) NSString *modeDescription;
@end

@implementation BBBrightnessSnapshot
@end

@interface BBHDRPixelView : MTKView
@property (nonatomic, assign) double hdrLevel;
- (instancetype)initWithFrame:(NSRect)frameRect hdrLevel:(double)hdrLevel;
@end

@implementation BBHDRPixelView

- (instancetype)initWithFrame:(NSRect)frameRect hdrLevel:(double)hdrLevel {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (!self) {
        return nil;
    }

    self.hdrLevel = hdrLevel;
    self.colorPixelFormat = MTLPixelFormatRGBA16Float;
    self.framebufferOnly = NO;
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.clearColor = MTLClearColorMake(hdrLevel, hdrLevel, hdrLevel, 1.0);
    self.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    if ([self.layer respondsToSelector:NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:")]) {
        [(id)self.layer setValue:@YES forKey:@"wantsExtendedDynamicRangeContent"];
    }
    [self setNeedsDisplay:YES];
    return self;
}

- (void)setHdrLevel:(double)hdrLevel {
    _hdrLevel = hdrLevel;
    self.clearColor = MTLClearColorMake(hdrLevel, hdrLevel, hdrLevel, 1.0);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    id<CAMetalDrawable> drawable = [self currentDrawable];
    MTLRenderPassDescriptor *descriptor = self.currentRenderPassDescriptor;
    if (drawable == nil || descriptor == nil) {
        return;
    }

    id<MTLCommandQueue> queue = [self.device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
}

@end

@interface BBXDROverlayController : NSObject
- (void)updateBoostFactor:(double)boostFactor forDisplayID:(CGDirectDisplayID)displayID;
- (void)tearDown;
- (NSString *)diagnosticsSummary;
@end

@interface BBXDROverlayController ()
@property (nonatomic, strong) NSWindow *overlayWindow;
@property (nonatomic, strong) BBHDRPixelView *pixelView;
@property (nonatomic, assign) CGDirectDisplayID activeDisplayID;
@property (nonatomic, assign) double activeBoostFactor;
@end

@implementation BBXDROverlayController

- (void)updateBoostFactor:(double)boostFactor forDisplayID:(CGDirectDisplayID)displayID {
    self.activeDisplayID = displayID;
    self.activeBoostFactor = boostFactor;

    if (boostFactor <= 0.001) {
        [self tearDown];
        CGDisplayRestoreColorSyncSettings();
        return;
    }

    NSScreen *targetScreen = nil;
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber != nil && screenNumber.unsignedIntValue == displayID) {
            targetScreen = screen;
            break;
        }
    }
    if (targetScreen == nil) {
        return;
    }

    if (self.overlayWindow == nil) {
        NSRect frame = NSMakeRect(NSMinX(targetScreen.frame), NSMaxY(targetScreen.frame) - 4.0, 4.0, 4.0);
        self.overlayWindow = [[NSWindow alloc] initWithContentRect:frame
                                                         styleMask:NSWindowStyleMaskBorderless
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
        self.overlayWindow.level = NSScreenSaverWindowLevel;
        self.overlayWindow.opaque = NO;
        self.overlayWindow.backgroundColor = NSColor.clearColor;
        self.overlayWindow.ignoresMouseEvents = YES;
        self.overlayWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.overlayWindow.releasedWhenClosed = NO;
        self.pixelView = [[BBHDRPixelView alloc] initWithFrame:NSMakeRect(0, 0, 4.0, 4.0) hdrLevel:4.0];
        self.overlayWindow.contentView = self.pixelView;
    }

    NSRect frame = NSMakeRect(NSMinX(targetScreen.frame), NSMaxY(targetScreen.frame) - 4.0, 4.0, 4.0);
    [self.overlayWindow setFrame:frame display:YES];
    self.pixelView.hdrLevel = 4.0 + (boostFactor * 8.0);
    [self.overlayWindow orderFrontRegardless];

    double gamma = MAX(0.55, 1.0 - (boostFactor * 0.40));
    CGSetDisplayTransferByFormula(displayID, 0.0, 1.0, gamma, 0.0, 1.0, gamma, 0.0, 1.0, gamma);
}

- (void)tearDown {
    [self.overlayWindow orderOut:nil];
}

- (NSString *)diagnosticsSummary {
    return [NSString stringWithFormat:@"Overlay active: %@, boost factor: %.3f, display: %u",
            self.overlayWindow.isVisible ? @"yes" : @"no",
            self.activeBoostFactor,
            self.activeDisplayID];
}

@end

@interface BBBrightnessController : NSObject
- (instancetype)initWithError:(NSError **)error;
- (BBBrightnessSnapshot *)snapshotWithError:(NSError **)error;
- (BOOL)setBrightness:(double)normalizedValue error:(NSError **)error;
- (NSString *)diagnosticsReport;
@end

@interface BBBrightnessController ()
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) void *displayServicesHandle;
@property (nonatomic, assign) void *coreDisplayHandle;
@property (nonatomic, assign) void *skyLightHandle;
@property (nonatomic, assign) BBGetValueFloatFn dsGetBrightness;
@property (nonatomic, assign) BBSetValueFloatFn dsSetBrightness;
@property (nonatomic, assign) BBGetValueFloatFn dsGetLinearBrightness;
@property (nonatomic, assign) BBSetValueFloatFn dsSetLinearBrightness;
@property (nonatomic, assign) BBGetRangeFloatFn dsGetLinearBrightnessUsableRange;
@property (nonatomic, assign) BBSetUInt32FloatFn dsSetDynamicSlider;
@property (nonatomic, assign) BBGetValueDoubleFn getLinearBrightness;
@property (nonatomic, assign) BBSetValueDoubleFn setLinearBrightness;
@property (nonatomic, assign) BBGetValueDoubleFn getUserBrightness;
@property (nonatomic, assign) BBSetValueDoubleFn setUserBrightness;
@property (nonatomic, assign) BBGetValueDoubleFn getPotentialHeadroom;
@property (nonatomic, assign) BBSetValueDoubleFn requestHeadroom;
@property (nonatomic, assign) BBSetUInt32DoubleFn setDynamicSliderFactor;
@property (nonatomic, assign) BBGetValueDoubleFn slsGetCurrentHeadroom;
@property (nonatomic, assign) BBGetValueDoubleFn slsGetPotentialHeadroom;
@property (nonatomic, assign) BBGetValueDoubleFn slsGetReferenceHeadroom;
@property (nonatomic, assign) double cachedMaximumBrightness;
@property (nonatomic, assign) double lastRequestedNormalizedBrightness;
@property (nonatomic, assign) double activeBoostFactor;
@property (nonatomic, copy) NSString *lastSetOperationReport;
@property (nonatomic, strong) BBXDROverlayController *overlayController;
@end

@implementation BBBrightnessController

- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    CGDirectDisplayID pickedDisplay = 0;
    if (![self pickControllableDisplay:&pickedDisplay error:error]) {
        return nil;
    }

    void *displayServicesHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    void *coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW);
    void *skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (displayServicesHandle == NULL && coreDisplayHandle == NULL && skyLightHandle == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"BeyondBrightness"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Private display brightness controls are unavailable on this Mac."}];
        }
        return nil;
    }

    self.displayID = pickedDisplay;
    self.displayServicesHandle = displayServicesHandle;
    self.coreDisplayHandle = coreDisplayHandle;
    self.skyLightHandle = skyLightHandle;
    self.dsGetBrightness = displayServicesHandle ? (BBGetValueFloatFn)dlsym(displayServicesHandle, "DisplayServicesGetBrightness") : NULL;
    self.dsSetBrightness = displayServicesHandle ? (BBSetValueFloatFn)dlsym(displayServicesHandle, "DisplayServicesSetBrightness") : NULL;
    self.dsGetLinearBrightness = displayServicesHandle ? (BBGetValueFloatFn)dlsym(displayServicesHandle, "DisplayServicesGetLinearBrightness") : NULL;
    self.dsSetLinearBrightness = displayServicesHandle ? (BBSetValueFloatFn)dlsym(displayServicesHandle, "DisplayServicesSetLinearBrightness") : NULL;
    self.dsGetLinearBrightnessUsableRange = displayServicesHandle ? (BBGetRangeFloatFn)dlsym(displayServicesHandle, "DisplayServicesGetLinearBrightnessUsableRange") : NULL;
    self.dsSetDynamicSlider = displayServicesHandle ? (BBSetUInt32FloatFn)dlsym(displayServicesHandle, "DisplayServicesSetDynamicSlider") : NULL;
    self.getLinearBrightness = coreDisplayHandle ? (BBGetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_GetLinearBrightness") : NULL;
    self.setLinearBrightness = coreDisplayHandle ? (BBSetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_SetLinearBrightness") : NULL;
    self.getUserBrightness = coreDisplayHandle ? (BBGetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_GetUserBrightness") : NULL;
    self.setUserBrightness = coreDisplayHandle ? (BBSetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_SetUserBrightness") : NULL;
    self.getPotentialHeadroom = coreDisplayHandle ? (BBGetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_GetPotentialHeadroom") : NULL;
    self.requestHeadroom = coreDisplayHandle ? (BBSetValueDoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_RequestHeadroom") : NULL;
    self.setDynamicSliderFactor = coreDisplayHandle ? (BBSetUInt32DoubleFn)dlsym(coreDisplayHandle, "CoreDisplay_Display_SetDynamicSliderFactor") : NULL;
    self.slsGetCurrentHeadroom = skyLightHandle ? (BBGetValueDoubleFn)dlsym(skyLightHandle, "SLSDisplayGetCurrentHeadroom") : NULL;
    self.slsGetPotentialHeadroom = skyLightHandle ? (BBGetValueDoubleFn)dlsym(skyLightHandle, "SLSDisplayGetPotentialHeadroom") : NULL;
    self.slsGetReferenceHeadroom = skyLightHandle ? (BBGetValueDoubleFn)dlsym(skyLightHandle, "SLSDisplayGetReferenceHeadroom") : NULL;
    self.cachedMaximumBrightness = 1.0;
    self.lastRequestedNormalizedBrightness = 1.0;
    self.activeBoostFactor = 0.0;
    self.lastSetOperationReport = @"No brightness write attempted yet.";
    self.overlayController = [BBXDROverlayController new];

    NSError *maximumError = nil;
    double maximum = [self readPotentialMaximumBrightness:&maximumError];
    if (maximumError == nil && maximum >= 1.0) {
        self.cachedMaximumBrightness = maximum;
    }

    return self;
}

- (void)dealloc {
    if (self.displayServicesHandle != NULL) {
        dlclose(self.displayServicesHandle);
        self.displayServicesHandle = NULL;
    }
    if (self.coreDisplayHandle != NULL) {
        dlclose(self.coreDisplayHandle);
        self.coreDisplayHandle = NULL;
    }
    if (self.skyLightHandle != NULL) {
        dlclose(self.skyLightHandle);
        self.skyLightHandle = NULL;
    }
    [self.overlayController tearDown];
    CGDisplayRestoreColorSyncSettings();
}

- (BBBrightnessSnapshot *)snapshotWithError:(NSError **)error {
    NSError *readError = nil;
    double currentBrightness = [self readNormalizedBrightness:&readError];
    if (readError != nil) {
        if (error != NULL) {
            *error = readError;
        }
        return nil;
    }

    NSError *maximumError = nil;
    double maximum = [self readPotentialMaximumBrightness:&maximumError];
    if (maximumError != nil || maximum < 1.0) {
        maximum = self.cachedMaximumBrightness;
    }
    self.cachedMaximumBrightness = MAX(1.0, maximum);

    BBBrightnessSnapshot *snapshot = [BBBrightnessSnapshot new];
    double displayedBrightness = currentBrightness;
    if (self.activeBoostFactor > 0.001) {
        displayedBrightness = currentBrightness + (self.activeBoostFactor * (self.cachedMaximumBrightness - 1.0));
    } else {
        self.lastRequestedNormalizedBrightness = currentBrightness;
    }
    snapshot.normalizedBrightness = MIN(MAX(displayedBrightness, 0.0), self.cachedMaximumBrightness);
    snapshot.maximumBrightness = self.cachedMaximumBrightness;
    snapshot.supportsExtendedBrightness = [self canAttemptExtendedBrightness];
    snapshot.percentage = (NSInteger)llround(snapshot.normalizedBrightness * 100.0);
    snapshot.modeDescription = snapshot.supportsExtendedBrightness
        ? @"Native XDR boost path available"
        : @"Standard brightness only on this display";
    return snapshot;
}

- (BOOL)setBrightness:(double)normalizedValue error:(NSError **)error {
    double safeMaximum = [self canAttemptExtendedBrightness] ? MAX(2.0, self.cachedMaximumBrightness) : MAX(1.0, self.cachedMaximumBrightness);
    NSError *maximumError = nil;
    double probedMaximum = [self readPotentialMaximumBrightness:&maximumError];
    if (maximumError == nil && probedMaximum >= 1.0) {
        safeMaximum = probedMaximum;
        self.cachedMaximumBrightness = probedMaximum;
    }
    if ([self canAttemptExtendedBrightness]) {
        safeMaximum = MAX(2.0, safeMaximum);
        self.cachedMaximumBrightness = MAX(self.cachedMaximumBrightness, safeMaximum);
    }

    double clampedValue = MIN(MAX(normalizedValue, 0.0), safeMaximum);
    double standardValue = clampedValue > 1.0 ? 1.0 : MIN(clampedValue, 1.0);
    double requestedHeadroom = MAX(1.0, clampedValue);
    double dynamicFactor = 0.0;
    if (safeMaximum > 1.0) {
        dynamicFactor = (clampedValue - 1.0) / (safeMaximum - 1.0);
        dynamicFactor = MIN(MAX(dynamicFactor, 0.0), 1.0);
    }
    NSMutableArray<NSString *> *operationLines = [NSMutableArray array];
    [operationLines addObject:[NSString stringWithFormat:@"Requested %.3f, clamped %.3f, max %.3f, factor %.3f",
                               normalizedValue, clampedValue, safeMaximum, dynamicFactor]];
    self.lastRequestedNormalizedBrightness = clampedValue;

    if (self.dsSetBrightness != NULL) {
        int32_t result = self.dsSetBrightness(self.displayID, (float)standardValue);
        [operationLines addObject:[NSString stringWithFormat:@"DisplayServicesSetBrightness -> %d", result]];
        if (result != 0) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            if (error != NULL) {
                *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting display brightness failed with code %d.", result]
                                           code:1002];
            }
            return NO;
        }
    } else if (self.setUserBrightness != NULL) {
        int32_t result = self.setUserBrightness(self.displayID, standardValue);
        [operationLines addObject:[NSString stringWithFormat:@"CoreDisplaySetUserBrightness -> %d", result]];
        if (result != 0) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            if (error != NULL) {
                *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting user brightness failed with code %d.", result]
                                           code:1002];
            }
            return NO;
        }
    } else if (self.setLinearBrightness != NULL) {
        int32_t result = self.setLinearBrightness(self.displayID, standardValue);
        [operationLines addObject:[NSString stringWithFormat:@"CoreDisplaySetLinearBrightness(standard) -> %d", result]];
        if (result != 0) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            if (error != NULL) {
                *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting linear brightness failed with code %d.", result]
                                           code:1003];
            }
            return NO;
        }
    } else {
        self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
        if (error != NULL) {
            *error = [self errorWithMessage:@"CoreDisplay brightness controls are unavailable on this Mac." code:1004];
        }
        return NO;
    }

    if (clampedValue <= 1.0 && self.dsSetLinearBrightness != NULL) {
        int32_t result = self.dsSetLinearBrightness(self.displayID, (float)clampedValue);
        [operationLines addObject:[NSString stringWithFormat:@"DisplayServicesSetLinearBrightness(reset) -> %d", result]];
        if (result != 0) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            if (error != NULL) {
                *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting linear brightness reset failed with code %d.", result]
                                           code:1005];
            }
            return NO;
        }
    }

    if (self.dsSetDynamicSlider != NULL) {
        int32_t result = self.dsSetDynamicSlider(self.displayID, (float)dynamicFactor);
        [operationLines addObject:[NSString stringWithFormat:@"DisplayServicesSetDynamicSlider -> %d", result]];
        if (result != 0 && clampedValue > 1.0 && error != NULL) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting dynamic slider failed with code %d.", result]
                                       code:1007];
            return NO;
        }
    }

    if (self.setDynamicSliderFactor != NULL) {
        int32_t result = self.setDynamicSliderFactor(self.displayID, dynamicFactor);
        [operationLines addObject:[NSString stringWithFormat:@"CoreDisplaySetDynamicSliderFactor -> %d", result]];
        if (result != 0 && clampedValue > 1.0) {
            [operationLines addObject:@"CoreDisplay dynamic slider factor failed, continuing with DisplayServices + overlay path"];
        }
    }

    if (self.requestHeadroom != NULL) {
        int32_t result = self.requestHeadroom(self.displayID, requestedHeadroom);
        [operationLines addObject:[NSString stringWithFormat:@"CoreDisplayRequestHeadroom -> %d", result]];
        if (result != 0) {
            self.cachedMaximumBrightness = MAX(self.cachedMaximumBrightness, 1.0);
        }
    } else if (clampedValue <= 1.0 && self.setLinearBrightness != NULL) {
        int32_t result = self.setLinearBrightness(self.displayID, clampedValue);
        [operationLines addObject:[NSString stringWithFormat:@"CoreDisplaySetLinearBrightness(reset) -> %d", result]];
        if (result != 0) {
            self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
            if (error != NULL) {
                *error = [self errorWithMessage:[NSString stringWithFormat:@"Setting linear brightness reset failed with code %d.", result]
                                           code:1009];
            }
            return NO;
        }
    }

    [self.overlayController updateBoostFactor:dynamicFactor forDisplayID:self.displayID];
    self.activeBoostFactor = dynamicFactor;
    [operationLines addObject:[self.overlayController diagnosticsSummary]];

    self.lastSetOperationReport = [operationLines componentsJoinedByString:@"\n"];
    return YES;
}

- (BOOL)pickControllableDisplay:(CGDirectDisplayID *)displayID error:(NSError **)error {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        if (error != NULL) {
            *error = [self errorWithMessage:@"No controllable display was found." code:1007];
        }
        return NO;
    }

    CGDirectDisplayID displays[count];
    if (CGGetActiveDisplayList(count, displays, &count) != kCGErrorSuccess) {
        if (error != NULL) {
            *error = [self errorWithMessage:@"Unable to enumerate displays." code:1008];
        }
        return NO;
    }

    for (uint32_t index = 0; index < count; index += 1) {
        if (CGDisplayIsBuiltin(displays[index]) != 0) {
            *displayID = displays[index];
            return YES;
        }
    }

    *displayID = CGMainDisplayID();
    return YES;
}

- (double)readNormalizedBrightness:(NSError **)error {
    if (self.dsGetBrightness != NULL) {
        NSError *brightnessError = nil;
        float brightness = [self readFloatValueUsing:self.dsGetBrightness label:@"display brightness" error:&brightnessError];
        if (brightnessError == nil && isfinite(brightness) && brightness >= 0.0) {
            return (double)brightness;
        }
    }

    if (self.dsGetLinearBrightness != NULL) {
        NSError *linearError = nil;
        float linearValue = [self readFloatValueUsing:self.dsGetLinearBrightness label:@"linear brightness" error:&linearError];
        if (linearError == nil && linearValue > 0.0 && isfinite(linearValue)) {
            return (double)linearValue;
        }
    }

    if (self.getLinearBrightness != NULL) {
        NSError *linearError = nil;
        double linearValue = [self readValueUsing:self.getLinearBrightness label:@"linear brightness" error:&linearError];
        if (linearError == nil && linearValue > 0.0 && isfinite(linearValue)) {
            return linearValue;
        }
    }

    if (self.getUserBrightness != NULL) {
        return [self readValueUsing:self.getUserBrightness label:@"user brightness" error:error];
    }

    if (error != NULL) {
        *error = [self errorWithMessage:@"CoreDisplay brightness controls are unavailable on this Mac." code:1009];
    }
    return 0.0;
}

- (double)readPotentialMaximumBrightness:(NSError **)error {
    double bestMaximum = 1.0;

    if (self.dsGetLinearBrightnessUsableRange != NULL) {
        float minimum = 0.0f;
        float maximum = 1.0f;
        int32_t result = self.dsGetLinearBrightnessUsableRange(self.displayID, &minimum, &maximum);
        if (result == 0 && isfinite(maximum) && maximum >= 1.0f) {
            bestMaximum = MAX(bestMaximum, MIN(MAX((double)maximum, 1.0), 3.0));
        }
    }

    if (self.getPotentialHeadroom != NULL) {
        NSError *coreDisplayError = nil;
        double headroom = [self readValueUsing:self.getPotentialHeadroom label:@"display headroom" error:&coreDisplayError];
        if (coreDisplayError == nil && isfinite(headroom) && headroom >= 1.0) {
            bestMaximum = MAX(bestMaximum, MIN(MAX(headroom, 1.0), 3.0));
        }
    }

    if (self.slsGetPotentialHeadroom != NULL) {
        NSError *slsError = nil;
        double headroom = [self readValueUsing:self.slsGetPotentialHeadroom label:@"SkyLight display headroom" error:&slsError];
        if (slsError == nil && isfinite(headroom) && headroom >= 1.0) {
            bestMaximum = MAX(bestMaximum, MIN(MAX(headroom, 1.0), 3.0));
        }
    }

    if (self.slsGetReferenceHeadroom != NULL) {
        NSError *referenceError = nil;
        double headroom = [self readValueUsing:self.slsGetReferenceHeadroom label:@"reference headroom" error:&referenceError];
        if (referenceError == nil && isfinite(headroom) && headroom > 1.0) {
            bestMaximum = MAX(bestMaximum, MIN(MAX(headroom, 1.0), 3.0));
        }
    }

    if (bestMaximum > 1.0) {
        return bestMaximum;
    }

    if ([self canAttemptExtendedBrightness]) {
        return 2.0;
    }

    return 1.0;
}

- (double)readValueUsing:(BBGetValueDoubleFn)function label:(NSString *)label error:(NSError **)error {
    double value = 0.0;
    int32_t result = function(self.displayID, &value);
    if (result != 0) {
        if (error != NULL) {
            *error = [self errorWithMessage:[NSString stringWithFormat:@"Reading %@ failed with code %d.", label, result]
                                       code:1010];
        }
        return 0.0;
    }

    return value;
}

- (float)readFloatValueUsing:(BBGetValueFloatFn)function label:(NSString *)label error:(NSError **)error {
    float value = 0.0f;
    int32_t result = function(self.displayID, &value);
    if (result != 0) {
        if (error != NULL) {
            *error = [self errorWithMessage:[NSString stringWithFormat:@"Reading %@ failed with code %d.", label, result]
                                       code:1011];
        }
        return 0.0f;
    }

    return value;
}

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:@"BeyondBrightness"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (BOOL)canAttemptExtendedBrightness {
    return self.dsSetDynamicSlider != NULL ||
           self.setDynamicSliderFactor != NULL ||
           self.requestHeadroom != NULL ||
           self.dsSetLinearBrightness != NULL;
}

- (NSString *)diagnosticsReport {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Display ID: %u", self.displayID]];
    [lines addObject:[NSString stringWithFormat:@"Boost APIs present: %@",
                      [self canAttemptExtendedBrightness] ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"DS get/set brightness: %@/%@",
                      self.dsGetBrightness ? @"yes" : @"no",
                      self.dsSetBrightness ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"DS linear get/set/range/dynamic: %@/%@/%@/%@",
                      self.dsGetLinearBrightness ? @"yes" : @"no",
                      self.dsSetLinearBrightness ? @"yes" : @"no",
                      self.dsGetLinearBrightnessUsableRange ? @"yes" : @"no",
                      self.dsSetDynamicSlider ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"CD user/linear/headroom/dynamic: %@/%@/%@/%@",
                      self.setUserBrightness ? @"yes" : @"no",
                      self.setLinearBrightness ? @"yes" : @"no",
                      self.requestHeadroom ? @"yes" : @"no",
                      self.setDynamicSliderFactor ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"SLS headroom current/potential/reference: %@/%@/%@",
                      self.slsGetCurrentHeadroom ? @"yes" : @"no",
                      self.slsGetPotentialHeadroom ? @"yes" : @"no",
                      self.slsGetReferenceHeadroom ? @"yes" : @"no"]];

    NSError *snapshotError = nil;
    BBBrightnessSnapshot *snapshot = [self snapshotWithError:&snapshotError];
    if (snapshot != nil) {
    [lines addObject:[NSString stringWithFormat:@"Snapshot brightness/max/supports: %.3f / %.3f / %@",
                          snapshot.normalizedBrightness,
                          snapshot.maximumBrightness,
                          snapshot.supportsExtendedBrightness ? @"yes" : @"no"]];
        [lines addObject:[NSString stringWithFormat:@"Snapshot mode: %@",
                          snapshot.modeDescription ?: @"unknown"]];
    } else {
        [lines addObject:[NSString stringWithFormat:@"Snapshot error: %@",
                          snapshotError.localizedDescription ?: @"unknown"]];
    }

    NSError *potentialError = nil;
    double potential = [self readPotentialMaximumBrightness:&potentialError];
    [lines addObject:[NSString stringWithFormat:@"Computed max brightness: %.3f%@",
                      potential,
                      potentialError ? [NSString stringWithFormat:@" (error: %@)", potentialError.localizedDescription] : @""]];
    [lines addObject:[NSString stringWithFormat:@"Overlay: %@", [self.overlayController diagnosticsSummary]]];

    [lines addObject:@"Last write report:"];
    [lines addObject:self.lastSetOperationReport ?: @"Unavailable"];
    return [lines componentsJoinedByString:@"\n"];
}

@end

@interface BBAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *sliderValueLabel;
@property (nonatomic, strong) NSTextField *supportLabel;
@property (nonatomic, strong) NSMenuItem *errorMenuItem;
@property (nonatomic, strong) BBBrightnessController *brightnessController;
@property (nonatomic, strong) BBBrightnessSnapshot *lastSnapshot;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) UNUserNotificationCenter *notificationCenter;
@property (nonatomic, strong) NSDate *lastNotificationDate;
@property (nonatomic, assign) BOOL suppressNextNotification;
@property (nonatomic, assign) BOOL notificationsAuthorized;
@property (nonatomic, assign) BOOL menuIsOpen;
@property (nonatomic, strong) NSDate *suppressPollingUntil;
@property (nonatomic, assign) BBStatusDisplayMode statusDisplayMode;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSSegmentedControl *appearanceControl;
@property (nonatomic, strong) NSTextField *appearanceDescriptionLabel;
@end

@implementation BBAppDelegate

- (NSAttributedString *)statusTitleForPercentage:(NSInteger)percentage {
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium]
    };
    NSString *title = [NSString stringWithFormat:@" %3ld%%", (long)percentage];
    return [[NSAttributedString alloc] initWithString:title attributes:attributes];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.lastNotificationDate = [NSDate distantPast];
    self.suppressPollingUntil = [NSDate distantPast];
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    if (iconPath != nil) {
        NSImage *appIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (appIcon != nil) {
            [NSApp setApplicationIconImage:appIcon];
        }
    }
    [self loadPreferences];
    [NSApp setActivationPolicy:self.statusDisplayMode == BBStatusDisplayModeHidden ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
    [self configureNotifications];
    [self configureMenu];
    [self configureSettingsWindow];
    [self configureBrightnessController];
    [self startPolling];
    [self applyStatusDisplayMode];
    if (self.statusDisplayMode == BBStatusDisplayModeHidden) {
        [self showSettings:nil];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)configureNotifications {
    self.notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    [self.notificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                           completionHandler:^(BOOL granted, __unused NSError * _Nullable error) {
        self.notificationsAuthorized = granted;
    }];
}

- (void)configureMenu {
    self.statusMenu = [[NSMenu alloc] initWithTitle:@"BeyondBrightness"];
    self.statusMenu.delegate = (id<NSMenuDelegate>)self;

    self.slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    self.slider.minValue = 0.0;
    self.slider.maxValue = 100.0;
    self.slider.doubleValue = 100.0;
    self.slider.target = self;
    self.slider.action = @selector(sliderChanged:);
    self.slider.continuous = NO;

    self.sliderValueLabel = [NSTextField labelWithString:@"100%"];
    self.sliderValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightMedium];
    self.sliderValueLabel.alignment = NSTextAlignmentRight;

    NSTextField *statusLabel = [NSTextField labelWithString:@"Brightness"];
    statusLabel.font = [NSFont systemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightSemibold];

    self.supportLabel = [NSTextField labelWithString:@""];
    self.supportLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    self.supportLabel.textColor = [NSColor secondaryLabelColor];

    NSStackView *stack = [NSStackView stackViewWithViews:@[statusLabel, self.sliderValueLabel, self.slider, self.supportLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 6.0;
    stack.edgeInsets = NSEdgeInsetsMake(10.0, 12.0, 10.0, 12.0);

    NSMenuItem *sliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    sliderItem.view = stack;
    [self.statusMenu addItem:sliderItem];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    [self.statusMenu addItem:[self presetMenuItemWithTitle:@"100%" percent:100]];
    [self.statusMenu addItem:[self presetMenuItemWithTitle:@"120%" percent:120]];
    [self.statusMenu addItem:[self presetMenuItemWithTitle:@"140%" percent:140]];
    [self.statusMenu addItem:[self presetMenuItemWithTitle:@"160%" percent:160]];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    self.errorMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.errorMenuItem.hidden = YES;
    [self.statusMenu addItem:self.errorMenuItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit BeyondBrightness" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [self.statusMenu addItem:quitItem];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings" action:@selector(showSettings:) keyEquivalent:@","];
    settingsItem.target = self;
    settingsItem.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings"];
    [self.statusMenu insertItem:settingsItem atIndex:self.statusMenu.numberOfItems - 1];

    [self rebuildStatusItem];
}

- (NSMenuItem *)presetMenuItemWithTitle:(NSString *)title percent:(NSInteger)percent {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(applyPreset:) keyEquivalent:@""];
    item.target = self;
    item.tag = percent;
    return item;
}

- (void)configureBrightnessController {
    NSError *error = nil;
    self.brightnessController = [[BBBrightnessController alloc] initWithError:&error];
    if (self.brightnessController == nil) {
        [self showError:error.localizedDescription ?: @"Unable to access display brightness."];
        return;
    }

    self.errorMenuItem.hidden = YES;
    [self refreshUIAndNotify:NO];
}

- (void)configureSettingsWindow {
    NSRect frame = NSMakeRect(0, 0, 400, 210);
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    self.settingsWindow.title = @"Appearance";
    self.settingsWindow.releasedWhenClosed = NO;
    [self.settingsWindow center];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:frame];
    background.material = NSVisualEffectMaterialUnderWindowBackground;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;

    NSTextField *titleLabel = [NSTextField labelWithString:@"Appearance"];
    titleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];

    NSTextField *descriptionLabel = [NSTextField labelWithString:@"Choose how BeyondBrightness should appear in the menu bar."];
    descriptionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    descriptionLabel.maximumNumberOfLines = 1;
    descriptionLabel.textColor = [NSColor secondaryLabelColor];

    self.appearanceControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 292, 30)];
    self.appearanceControl.segmentCount = 3;
    [self.appearanceControl setLabel:@"Icon + %" forSegment:0];
    [self.appearanceControl setLabel:@"Icon only" forSegment:1];
    [self.appearanceControl setLabel:@"Hidden" forSegment:2];
    self.appearanceControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.appearanceControl.target = self;
    self.appearanceControl.action = @selector(statusDisplayModeChanged:);
    self.appearanceControl.segmentStyle = NSSegmentStyleRounded;

    self.appearanceDescriptionLabel = [NSTextField labelWithString:@""];
    self.appearanceDescriptionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.appearanceDescriptionLabel.maximumNumberOfLines = 2;
    self.appearanceDescriptionLabel.textColor = [NSColor secondaryLabelColor];

    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 352, 86)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.82].CGColor;
    card.layer.cornerRadius = 14.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.78].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *cardStack = [NSStackView stackViewWithViews:@[self.appearanceControl, self.appearanceDescriptionLabel]];
    cardStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    cardStack.spacing = 12.0;
    cardStack.edgeInsets = NSEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    NSButton *closeButton = [NSButton buttonWithTitle:@"Done" target:self action:@selector(closeSettings:)];
    closeButton.bezelStyle = NSBezelStyleRounded;
    closeButton.keyEquivalent = @"\r";

    NSStackView *footerStack = [NSStackView stackViewWithViews:@[[NSView new], closeButton]];
    footerStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footerStack.alignment = NSLayoutAttributeCenterY;
    footerStack.spacing = 8.0;

    NSStackView *stack = [NSStackView stackViewWithViews:@[titleLabel, descriptionLabel, card, footerStack]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14.0;
    stack.edgeInsets = NSEdgeInsetsMake(20.0, 20.0, 18.0, 20.0);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [background addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:background.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:background.bottomAnchor],
        [card.widthAnchor constraintEqualToConstant:360.0]
    ]];

    self.settingsWindow.contentView = background;
    [self refreshSettingsUI];
}

- (void)loadPreferences {
    NSInteger rawValue = [[NSUserDefaults standardUserDefaults] integerForKey:BBStatusDisplayModeDefaultsKey];
    if (rawValue < BBStatusDisplayModeIconAndPercentage || rawValue > BBStatusDisplayModeHidden) {
        rawValue = BBStatusDisplayModeIconAndPercentage;
    }
    self.statusDisplayMode = (BBStatusDisplayMode)rawValue;
}

- (void)savePreferences {
    [[NSUserDefaults standardUserDefaults] setInteger:self.statusDisplayMode forKey:BBStatusDisplayModeDefaultsKey];
}

- (void)rebuildStatusItem {
    if (self.statusItem != nil) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }

    if (self.statusDisplayMode == BBStatusDisplayModeHidden) {
        return;
    }

    CGFloat length = self.statusDisplayMode == BBStatusDisplayModeIconOnly ? NSSquareStatusItemLength : 60.0;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:length];
    self.statusItem.menu = self.statusMenu;
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:@"Brightness"];
    if (self.statusDisplayMode == BBStatusDisplayModeIconOnly) {
        self.statusItem.button.imagePosition = NSImageOnly;
        self.statusItem.button.title = @"";
        self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
    } else {
        self.statusItem.button.imagePosition = NSImageLeft;
        self.statusItem.button.attributedTitle = [self statusTitleForPercentage:100];
    }
}

- (void)applyStatusDisplayMode {
    if (self.statusDisplayMode == BBStatusDisplayModeHidden) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
    [self rebuildStatusItem];
    [self refreshSettingsUI];
    if (self.lastSnapshot != nil) {
        [self applySnapshotToUI:self.lastSnapshot];
    }
}

- (void)refreshSettingsUI {
    self.appearanceControl.selectedSegment = self.statusDisplayMode;
    switch (self.statusDisplayMode) {
        case BBStatusDisplayModeIconAndPercentage:
            self.appearanceDescriptionLabel.stringValue = @"Show the icon with the live brightness percentage next to it.";
            break;
        case BBStatusDisplayModeIconOnly:
            self.appearanceDescriptionLabel.stringValue = @"Keep the menu bar presence minimal and show only the symbol.";
            break;
        case BBStatusDisplayModeHidden:
            self.appearanceDescriptionLabel.stringValue = @"Remove the status item entirely. The app stays available from the Dock.";
            break;
    }
}

- (void)startPolling {
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(pollBrightness:)
                                                    userInfo:nil
                                                     repeats:YES];
    self.pollTimer.tolerance = 0.2;
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)sliderChanged:(NSSlider *)sender {
    self.sliderValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)llround(sender.doubleValue)];
    [self commitSliderValue];
}

- (void)commitSliderValue {
    if (self.brightnessController == nil) {
        return;
    }

    self.suppressNextNotification = YES;
    self.suppressPollingUntil = [NSDate dateWithTimeIntervalSinceNow:0.25];
    NSError *error = nil;
    if (![self.brightnessController setBrightness:(self.slider.doubleValue / 100.0) error:&error]) {
        [self showError:error.localizedDescription ?: @"Brightness update failed."];
        return;
    }

    [self refreshUIAndNotify:YES];
}

- (void)applyPreset:(NSMenuItem *)sender {
    self.slider.doubleValue = sender.tag;
    [self commitSliderValue];
}

- (void)showSettings:(__unused id)sender {
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)closeSettings:(__unused id)sender {
    [self.settingsWindow orderOut:nil];
}

- (void)statusDisplayModeChanged:(id)sender {
    if ([sender isKindOfClass:[NSSegmentedControl class]]) {
        self.statusDisplayMode = (BBStatusDisplayMode)((NSSegmentedControl *)sender).selectedSegment;
    }
    [self savePreferences];
    [self applyStatusDisplayMode];
}

- (void)pollBrightness:(__unused NSTimer *)timer {
    if ([self.suppressPollingUntil timeIntervalSinceNow] > 0.0) {
        return;
    }
    if (self.brightnessController == nil) {
        return;
    }

    NSError *error = nil;
    BBBrightnessSnapshot *snapshot = [self.brightnessController snapshotWithError:&error];
    if (snapshot == nil) {
        [self showError:error.localizedDescription ?: @"Brightness read failed."];
        return;
    }

    if (self.lastSnapshot != nil) {
        double delta = fabs(self.lastSnapshot.normalizedBrightness - snapshot.normalizedBrightness);
        if (delta < 0.01) {
            self.suppressNextNotification = NO;
            return;
        }
    }

    BOOL shouldNotify = (self.lastSnapshot != nil && !self.suppressNextNotification);
    [self applySnapshotToUI:snapshot];
    self.lastSnapshot = snapshot;

    if (shouldNotify) {
        [self sendBrightnessNotificationForSnapshot:snapshot];
    }

    self.suppressNextNotification = NO;
}

- (void)refreshUIAndNotify:(BOOL)notify {
    if (self.brightnessController == nil) {
        return;
    }

    NSError *error = nil;
    BBBrightnessSnapshot *snapshot = [self.brightnessController snapshotWithError:&error];
    if (snapshot == nil) {
        [self showError:error.localizedDescription ?: @"Brightness read failed."];
        return;
    }

    self.errorMenuItem.hidden = YES;
    [self applySnapshotToUI:snapshot];
    self.lastSnapshot = snapshot;

    if (notify) {
        [self sendBrightnessNotificationForSnapshot:snapshot];
    }
}

- (void)applySnapshotToUI:(BBBrightnessSnapshot *)snapshot {
    self.slider.maxValue = snapshot.maximumBrightness * 100.0;
    self.slider.doubleValue = snapshot.normalizedBrightness * 100.0;
    self.sliderValueLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)snapshot.percentage];
    self.supportLabel.stringValue = snapshot.supportsExtendedBrightness
        ? [NSString stringWithFormat:@"%@ up to %ld%%", snapshot.modeDescription ?: @"Native XDR boost path available", (long)llround(snapshot.maximumBrightness * 100.0)]
        : (snapshot.modeDescription ?: @"Standard brightness only on this display");
    if (self.statusItem != nil) {
        self.statusItem.button.attributedTitle = (self.statusDisplayMode == BBStatusDisplayModeIconOnly)
            ? [[NSAttributedString alloc] initWithString:@""]
            : [self statusTitleForPercentage:snapshot.percentage];
    }
}

- (void)showError:(NSString *)message {
    self.errorMenuItem.title = message;
    self.errorMenuItem.hidden = NO;
    self.supportLabel.stringValue = @"Unavailable";
    if (self.statusItem != nil && self.statusDisplayMode != BBStatusDisplayModeIconOnly) {
        NSDictionary<NSAttributedStringKey, id> *attributes = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium]
        };
        self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:@" Err" attributes:attributes];
    }
}

- (void)sendBrightnessNotificationForSnapshot:(BBBrightnessSnapshot *)snapshot {
    if (!self.notificationsAuthorized) {
        return;
    }
    if ([[NSDate date] timeIntervalSinceDate:self.lastNotificationDate] < 0.4) {
        return;
    }

    self.lastNotificationDate = [NSDate date];

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Brightness";
    if (snapshot.supportsExtendedBrightness && snapshot.normalizedBrightness > 1.0) {
        content.body = [NSString stringWithFormat:@"Set to %ld%% (boosted)", (long)snapshot.percentage];
    } else {
        content.body = [NSString stringWithFormat:@"Set to %ld%%", (long)snapshot.percentage];
    }

    NSString *identifier = [NSString stringWithFormat:@"brightness-%@", [NSUUID UUID].UUIDString];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [self.notificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    self.menuIsOpen = YES;
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    self.menuIsOpen = NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag || self.statusDisplayMode == BBStatusDisplayModeHidden) {
        [self showSettings:nil];
    }
    return YES;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        NSApplication *application = [NSApplication sharedApplication];
        BBAppDelegate *delegate = [BBAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
