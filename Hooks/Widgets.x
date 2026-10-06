#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const CGFloat kWidgetCornerRadius = 20.2;
static void *kWidgetGlassKey = &kWidgetGlassKey;

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

static UIViewController *widgetNearestStackController(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder)
        if ([NSStringFromClass(r.class) isEqualToString:@"SBHWidgetStackViewController"] &&
            [r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
    return nil;
}

static BOOL widgetHasAncestorNamedWithinDepth(UIView *view, NSString *name, NSInteger maxDepth) {
    NSInteger depth = 0;
    for (UIView *a = view.superview; a && depth < maxDepth; a = a.superview, depth++)
        if ([NSStringFromClass(a.class) isEqualToString:name]) return YES;
    return NO;
}

static BOOL widgetSubtreeContainsClass(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return YES;
    for (UIView *sub in view.subviews)
        if (widgetSubtreeContainsClass(sub, name)) return YES;
    return NO;
}

static UIView *widgetFindDescendantNamed(UIView *view, NSString *name) {
    for (UIView *sub in view.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:name]) return sub;
        UIView *found = widgetFindDescendantNamed(sub, name);
        if (found) return found;
    }
    return nil;
}

static BOOL isWidgetGlassHostContainer(UIView *view) {
    // widget internals vary so use the nearest stable container
    if (!isExactClass(view, @"UIView")) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;
    if (!widgetNearestStackController(view)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBFTouchPassThroughView", 8)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBIconView", 10)) return NO;
    for (UIView *sub in view.subviews) {
        if (!isExactClass(sub, @"UIView") && !isExactClass(sub, @"BSUIScrollView")) continue;
        UIView *scroll = isExactClass(sub, @"BSUIScrollView") ? sub
                       : widgetFindDescendantNamed(sub, @"BSUIScrollView");
        if (scroll && widgetSubtreeContainsClass(scroll, @"SBHWidgetContainerView")) return YES;
    }
    return NO;
}

static UIView *widgetAncestorContainerHost(UIView *view) {
    NSInteger depth = 0;
    for (UIView *a = view; a && depth < 12; a = a.superview, depth++)
        if (isWidgetGlassHostContainer(a)) return a;
    return nil;
}

static BOOL isWidgetStackBackgroundMaterial(UIView *mat) {
    // stack backgrounds stay stock so child widgets keep separate lenses
    if (!isExactClass(mat, @"MTMaterialView")) return NO;
    UIView *parent = mat.superview;
    if (!isExactClass(parent, @"UIView")) return NO;
    UIViewController *vc = widgetNearestStackController(parent);
    if (!vc) return NO;
    return vc.view == parent || parent.superview == vc.view;
}

static void removeWidgetGlass(UIView *container) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    if (!glass) return;
    [glass removeFromSuperview];
    objc_setAssociatedObject(container, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void injectWidgetGlass(UIView *container) {
    if (!lgHostEnabled(@"Widgets")) { removeWidgetGlass(container); return; }
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"Widgets");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(container, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    else if (container.subviews.firstObject != glass) [container sendSubviewToBack:glass];
    glass.frame = container.bounds;
    glass.layer.cornerRadius  = kWidgetCornerRadius;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    container.layer.cornerRadius  = kWidgetCornerRadius;
    container.layer.cornerCurve   = kCACornerCurveContinuous;
    container.layer.masksToBounds = YES;
    container.clipsToBounds       = YES;
    lgTrackGlass(glass, @"Widgets", nil);
}

#pragma mark - iOS 13 Today widgets

// iOS 13 has no home screen widgets; its Today widgets (also shown above the 3D Touch menu of an app icon) are
// WGWidgetPlatterView with dark MTMaterialView backgrounds. Replace those with the widget glass.
static void *kLegacyPlatterMaterialKey = &kLegacyPlatterMaterialKey;

// Alpha alone did not hold (the materials were back at 1.0 in a hierarchy dump, other tweaks touch them too),
// so they are also masked with an empty layer.
static void legacySetMaterialHidden(UIView *material, BOOL hidden) {
    NSNumber *original = objc_getAssociatedObject(material, kLegacyPlatterMaterialKey);
    if (hidden) {
        if (!original)
            objc_setAssociatedObject(material, kLegacyPlatterMaterialKey, @(material.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (material.alpha != 0.0) material.alpha = 0.0;
        if (!material.layer.mask) material.layer.mask = [CALayer layer];
    } else if (original) {
        material.layer.mask = nil;
        material.alpha = original.doubleValue;
        objc_setAssociatedObject(material, kLegacyPlatterMaterialKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void legacyPlatterSetMaterials(UIView *view, UIView *content, BOOL hidden, NSInteger depth) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *sub in view.subviews) {
        if (sub == content || [sub isKindOfClass:[LGLiveBackdropView class]]) continue;
        if (materialClass && [sub isKindOfClass:materialClass]) legacySetMaterialHidden(sub, hidden);
        else if (depth < 2) legacyPlatterSetMaterials(sub, content, hidden, depth + 1);
    }
}

// The Today column has one dark material behind the whole widget list (MTMaterialView next to
// _WGWidgetListScrollView); every widget glass sampled it, which was the dark veil on all widgets.
static void legacyListSetMaterialHidden(UIView *platter, BOOL hidden) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    if (!materialClass) return;
    NSInteger depth = 0;
    for (UIView *a = platter.superview; a && depth < 8; a = a.superview, depth++) {
        if (!isExactClass(a, @"_WGWidgetListScrollView")) continue;
        for (UIView *sibling in a.superview.subviews)
            if ([sibling isKindOfClass:materialClass]) legacySetMaterialHidden(sibling, hidden);
        return;
    }
}

static void updateLegacyPlatterGlass(UIView *platter) {
    UIView *content = [platter respondsToSelector:@selector(contentView)]
        ? [platter valueForKey:@"contentView"] : nil;
    LGLiveBackdropView *glass = objc_getAssociatedObject(platter, kWidgetGlassKey);
    if (!lgHostEnabled(@"Widgets") || !platter.window) {
        legacyPlatterSetMaterials(platter, content, NO, 0);
        if (platter.window) legacyListSetMaterialHidden(platter, NO);
        removeWidgetGlass(platter);
        return;
    }
    if (platter.bounds.size.width < 40.0 || platter.bounds.size.height < 20.0) return;
    if (!glass) {
        glass = LGCreateRegisteredGlass(platter.bounds, nil, @"Widgets");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        objc_setAssociatedObject(platter, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != platter) [platter insertSubview:glass atIndex:0];
    else if (platter.subviews.firstObject != glass) [platter sendSubviewToBack:glass];
    legacyPlatterSetMaterials(platter, content, YES, 0);
    legacyListSetMaterialHidden(platter, YES);
    CGFloat radius = 13.0;
    SEL radiusSel = NSSelectorFromString(@"_continuousCornerRadius");
    if ([platter respondsToSelector:radiusSel]) {
        CGFloat own = ((CGFloat (*)(id, SEL))objc_msgSend)(platter, radiusSel);
        if (own > 0.0) radius = own;
    }
    glass.frame = platter.bounds;
    glass.layer.cornerRadius  = radius;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    lgTrackGlass(glass, @"Widgets", nil);
}

static NSHashTable<UIView *> *sLegacyPlatters;

#pragma mark - hooks

%hook WGWidgetPlatterView
- (void)didMoveToWindow {
    %orig;
    if (!sLegacyPlatters) sLegacyPlatters = [NSHashTable weakObjectsHashTable];
    [sLegacyPlatters addObject:(UIView *)self];
    updateLegacyPlatterGlass((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    updateLegacyPlatterGlass((UIView *)self);
}
%end

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window && lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)setHidden:(BOOL)hidden {
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_)) {
        hidden = YES;
        lgSuppressStock(self_, @"Widgets", NO);
    }
    %orig(hidden);
}
%end

%hook CHUISAvocadoHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (id)screenshotManager {
    if (self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook CHUISWidgetHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContent {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContentIfNecessary {
    if (self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (id)_snapshotImageFromURL:(id)arg1 {
    if (self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook BSUIScrollView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    UIView *host = widgetAncestorContainerHost(self_);
    if (!host) return;
    if (!self_.window) { removeWidgetGlass(host); return; }
    injectWidgetGlass(host);
}
- (void)layoutSubviews {
    %orig;
    UIView *host = widgetAncestorContainerHost((UIView *)self);
    if (host) injectWidgetGlass(host);
}
%end

%ctor {
    %init;
    lgObservePreferenceReload(^{
        for (UIView *platter in sLegacyPlatters.allObjects) updateLegacyPlatterGlass(platter);
    });
}
