#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface CCUIContinuousSliderView : UIControl
@end

@interface SBElasticSliderView : CCUIContinuousSliderView
@end

@interface SBElasticVolumeSliderView : SBElasticSliderView
@end

@interface SBElasticSliderMaterialWrapperView : UIView {
    MTMaterialView *_captureOnlyMaterialView;
    MTMaterialView *_baseMaterialView;
    UIView *_shadowView;
    UIView *_sliderWrapperView;
    UIView *_maskView;
    SBElasticVolumeSliderView *_sliderView;
}
- (void)_setContinuousCornerRadius:(double)radius;
@end

@interface LGVolumeHUDVibranceView : UIView
@end

@implementation LGVolumeHUDVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;
static const void * const kLGVolumeHUDMaterialHiddenKey = &kLGVolumeHUDMaterialHiddenKey;
static const void * const kLGVolumeHUDProbePendingKey = &kLGVolumeHUDProbePendingKey;

static BOOL LGVolumeHUDEnabled(void) {
    return lgHostEnabled(@"VolumeHUD");
}

static BOOL LGVolumeHUDNeedsLegacyMaterialWorkaround(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16;
}

static UIView *LGVolumeHUDDescendant(UIView *view, Class targetClass) {
    if ([view isKindOfClass:targetClass]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = LGVolumeHUDDescendant(subview, targetClass);
        if (found) return found;
    }
    return nil;
}

static UIView *LGVolumeHUDIvarView(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    id value = object_getIvar(object, ivar);
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static UIView *LGVolumeHUDDirectChild(UIView *ancestor, UIView *view) {
    for (UIView *v = view; v; v = v.superview)
        if (v.superview == ancestor) return v;
    return nil;
}

static BOOL LGVolumeHUDIsInside(UIView *view, UIView *ancestor) {
    for (UIView *v = view; v; v = v.superview)
        if (v == ancestor) return YES;
    return NO;
}

static void LGSetVolumeHUDBackgroundMaterialsHidden(UIView *view, BOOL hidden) {
    if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")] &&
        [view.superview isKindOfClass:NSClassFromString(@"MTMaterialShadowView")]) {
        NSNumber *original = objc_getAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey);
        if (hidden) {
            if (!original)
                objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.hidden = YES;
        } else if (original) {
            view.hidden = original.boolValue;
            objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
    for (UIView *subview in view.subviews) LGSetVolumeHUDBackgroundMaterialsHidden(subview, hidden);
}

// ios 13: the background is a plain MTMaterialView (no MTMaterialShadowView parent)
static void LGSetVolumeHUDLegacyMaterialsHidden(UIView *view, UIView *wrapper, UIView *sliderView, BOOL hidden) {
    if (sliderView && view == sliderView) {
        // the slider's direct material child is its dark track; the fill sits in a clipping UIView
        for (UIView *subview in view.subviews)
            if ([subview isKindOfClass:NSClassFromString(@"MTMaterialView")])
                LGSetVolumeHUDLegacyMaterialsHidden(subview, wrapper, nil, hidden);
        return;
    }
    if (view != wrapper && [view isKindOfClass:NSClassFromString(@"MTMaterialView")] &&
        !(sliderView && LGVolumeHUDIsInside(view, sliderView))) {
        NSNumber *original = objc_getAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey);
        if (hidden) {
            if (!original)
                objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.hidden = YES;
        } else if (original) {
            view.hidden = original.boolValue;
            objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    for (UIView *subview in view.subviews) LGSetVolumeHUDLegacyMaterialsHidden(subview, wrapper, sliderView, hidden);
}

static void LGAppendVolumeHUDMaterialRows(UIView *view, NSString *path,
                                          NSMutableArray<NSString *> *rows) {
    NSString *nextPath = [path stringByAppendingFormat:@"/%@", NSStringFromClass(view.class)];
    [rows addObject:[NSString stringWithFormat:@"%@ frame=%@ hidden=%d alpha=%.2f radius=%.2f",
            nextPath, NSStringFromCGRect(view.frame), view.hidden, view.alpha, view.layer.cornerRadius]];
    for (UIView *subview in view.subviews) LGAppendVolumeHUDMaterialRows(subview, nextPath, rows);
}

static void LGScheduleVolumeHUDProbe(UIView *wrapper) {
    if (!LGDebugLoggingEnabled() || [objc_getAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey) boolValue]) return;
    objc_setAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!wrapper.window) return;
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        LGAppendVolumeHUDMaterialRows(wrapper, @"", rows);
        LGLog(@"[VolumeHUD probe] wrapper=%@ bounds=%@ materials=[%@]",
              NSStringFromClass(wrapper.class), NSStringFromCGRect(wrapper.bounds),
              [rows componentsJoinedByString:@" | "]);
    });
}

static void LGUpdateVolumeHUDGlass(SBElasticSliderMaterialWrapperView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTMaterialView *cap = nil;
    UIView *shadow = nil;
    UIView *sliderWrapper = nil;
    UIView *sliderView = nil;
    // ios 13 has no _captureOnlyMaterialView/_shadowView, so read each ivar on its own
    base = (MTMaterialView *)LGVolumeHUDIvarView(self, "_baseMaterialView");
    cap = (MTMaterialView *)LGVolumeHUDIvarView(self, "_captureOnlyMaterialView");
    shadow = LGVolumeHUDIvarView(self, "_shadowView");
    sliderWrapper = LGVolumeHUDIvarView(self, "_sliderWrapperView");
    sliderView = LGVolumeHUDIvarView(self, "_sliderView");
    if (!sliderView)
        sliderView = LGVolumeHUDDescendant(self, NSClassFromString(@"SBElasticVolumeSliderView"));
    if (!sliderView)
        sliderView = LGVolumeHUDDescendant(self, NSClassFromString(@"SBElasticSliderView"));

    if (!LGVolumeHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGVolumeHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        if (cap) cap.hidden = NO;
        if (shadow) shadow.hidden = NO;
        LGSetVolumeHUDBackgroundMaterialsHidden(self, NO);
        LGSetVolumeHUDLegacyMaterialsHidden(self, self, sliderView, NO);
        return;
    }

    if (base) base.hidden = YES;
    if (cap) cap.hidden = YES;
    if (shadow) shadow.hidden = YES;
    LGSetVolumeHUDBackgroundMaterialsHidden(self, YES);
    if (LGVolumeHUDNeedsLegacyMaterialWorkaround())
        LGSetVolumeHUDLegacyMaterialsHidden(self, self, sliderView, YES);

    LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *above = sliderWrapper ?: LGVolumeHUDDirectChild(self, sliderView);
            if (above) {
                [self insertSubview:vibrance belowSubview:above];
            } else {
                [self insertSubview:vibrance atIndex:0];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGVolumeHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        [self insertSubview:glass atIndex:0];
    }
    if (vibrance && glass.superview == self && vibrance.superview == self &&
        [self.subviews indexOfObject:glass] > [self.subviews indexOfObject:vibrance])
        [self insertSubview:glass belowSubview:vibrance];

    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (sliderWrapper) {
        sliderWrapper.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderWrapper.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderWrapper.layer.masksToBounds = YES;
    }

    if (sliderView) {
        sliderView.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderView.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderView.layer.masksToBounds = YES;
        if (LGVolumeHUDNeedsLegacyMaterialWorkaround()) {
            for (UIView *subview in sliderView.subviews) {
                if (![subview isKindOfClass:NSClassFromString(@"MTMaterialView")]) continue;
                subview.layer.cornerRadius = radius;
                subview.layer.cornerCurve = kCACornerCurveContinuous;
                subview.layer.masksToBounds = YES;
            }
        }
    }
    LGScheduleVolumeHUDProbe(self);
}

%group LGVolumeHUDHooks

%hook SBElasticSliderMaterialWrapperView

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (instancetype)initWithSliderView:(id)sliderView {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (void)layoutSubviews {
    %orig;
    LGUpdateVolumeHUDGlass(self);
}

- (void)_setContinuousCornerRadius:(double)radius {
    if (LGVolumeHUDEnabled()) {
        CGFloat pillRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;
        %orig((double)pillRadius);
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (glass) {
            glass.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                glass.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
        LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (vibrance) {
            vibrance.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                vibrance.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
    } else {
        %orig;
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGVolumeHUDHooks);
    lgObservePreferenceReload(^{

        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
