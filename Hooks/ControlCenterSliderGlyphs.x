// Control Center brightness / volume sliders: coloured glyphs (from the rootless add-on, rootless-addon/lgfix.m,
// "coloured glyphs", Reworked v3 test22).
//
// The glyph of a CC slider (sun, speaker) is punched out of the white fill: its layers carry the compositing
// filter destOut, so it shows whatever lies behind the slider (dark). Here the punch-out is taken off the slider's
// glyph and a colour matrix paints it in one colour (alpha kept): brightness yellow, volume blue, like iOS 18.
// The faint compensating copy for the unfilled part is left out while the glyph is coloured.
//
// The slider's two glyph views are looked up under their names on iOS 17 (_activeGlyphView /
// _compensatingGlyphView) and on iOS 13 (_glyphPackageView / _compensatingGlyphPackageView). Where neither pair
// exists, or the two are not built alike, the glyph stays as the system draws it.
//
// Off with the hidden setting ControlCenter.SliderGlyphColors = false (follows ControlCenter.Enabled otherwise).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kLGGlyphPunchKey = &kLGGlyphPunchKey;
static const void *kLGGlyphColoredKey = &kLGGlyphColoredKey;
static const void *kLGGlyphCopyMaskKey = &kLGGlyphCopyMaskKey;
static const void *kLGGlyphCopyHiddenKey = &kLGGlyphCopyHiddenKey;
static const void *kLGGlyphPendingKey = &kLGGlyphPendingKey;
static NSString *const kLGGlyphFilterName = @"lgGlyphColor";

static id LGGlyphIvar(id object, const char *first, const char *second) {
    const char *names[2] = { first, second };
    for (int i = 0; i < 2; i++) {
        if (!names[i]) continue;
        Ivar ivar = class_getInstanceVariable(object_getClass(object), names[i]);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;
        id value = object_getIvar(object, ivar);
        if (value) return value;
    }
    return nil;
}

static id LGGlyphColorFilter(float r, float g, float b) {
    Class filterClass = objc_getClass("CAFilter");
    SEL make = sel_registerName("filterWithType:");
    if (!filterClass || !class_getClassMethod(filterClass, make)) return nil;
    id filter = ((id (*)(id, SEL, id))objc_msgSend)((id)filterClass, make, @"colorMatrix");
    // rows R, G, B, A; columns r, g, b, a, bias. Colour = alpha times the wanted colour
    float m[20] = { 0, 0, 0, r, 0,   0, 0, 0, g, 0,   0, 0, 0, b, 0,   0, 0, 0, 1, 0 };
    [filter setValue:[NSValue valueWithBytes:m objCType:"{CAColorMatrix=ffffffffffffffffffff}"]
              forKey:@"inputColorMatrix"];
    [filter setValue:kLGGlyphFilterName forKey:@"name"];
    return filter;
}

// allowsGroupBlending is private API of CALayer
static BOOL LGGlyphGroupBlending(CALayer *layer) {
    SEL sel = sel_registerName("allowsGroupBlending");
    if (![layer respondsToSelector:sel]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel);
}

static void LGGlyphSetGroupBlending(CALayer *layer, BOOL on) {
    SEL sel = sel_registerName("setAllowsGroupBlending:");
    if (![layer respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, sel, on);
}

// Is `layer` built like `reference` (same classes, same number of sublayers all the way down)?
static BOOL LGGlyphSameShape(CALayer *layer, CALayer *reference, int depth) {
    if (!layer || !reference || depth > 12 ||
        object_getClass(layer) != object_getClass(reference)) return NO;
    NSArray *a = layer.sublayers, *b = reference.sublayers;
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (!LGGlyphSameShape(a[i], b[i], depth + 1)) return NO;
    }
    return YES;
}

// Takes the punch-out off: every layer gets the compositing filter and group blending of the same layer in the
// slider's compensating copy (the same package, never set up for punch-out). Some glyphs cut parts of themselves
// with destOut on purpose (the speaker); those stay. What was there before is kept on the layer.
static void LGGlyphPunchOut(CALayer *layer, CALayer *reference, int depth) {
    if (!layer || depth > 12) return;
    id want = reference.compositingFilter;
    BOOL wantGroup = LGGlyphGroupBlending(reference);
    id have = layer.compositingFilter;
    BOOL haveGroup = LGGlyphGroupBlending(layer);
    BOOL differs = haveGroup != wantGroup || (want ? ![want isEqual:have] : have != nil);
    if (differs) {
        if (!objc_getAssociatedObject(layer, kLGGlyphPunchKey)) {
            objc_setAssociatedObject(layer, kLGGlyphPunchKey,
                                     @[have ?: [NSNull null], @(haveGroup)],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        layer.compositingFilter = want;
        if (haveGroup != wantGroup) LGGlyphSetGroupBlending(layer, wantGroup);
    }
    NSArray *subs = layer.sublayers, *refs = reference.sublayers;
    for (NSUInteger i = 0; i < subs.count && i < refs.count; i++) {
        LGGlyphPunchOut(subs[i], refs[i], depth + 1);
    }
}

static void LGGlyphPunchRestore(CALayer *layer, int depth) {
    if (!layer || depth > 12) return;
    NSArray *saved = objc_getAssociatedObject(layer, kLGGlyphPunchKey);
    if (saved.count == 2) {
        id filter = saved[0];
        layer.compositingFilter = filter == [NSNull null] ? nil : filter;
        LGGlyphSetGroupBlending(layer, [saved[1] boolValue]);
        objc_setAssociatedObject(layer, kLGGlyphPunchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (CALayer *sub in layer.sublayers) LGGlyphPunchRestore(sub, depth + 1);
}

// 1 = brightness, 2 = volume, 0 = any other slider
static int LGGlyphSliderKind(UIView *slider) {
    // not by class name: an observed slider is an instance of a KVO subclass (NSKVONotifying_…)
    Class volumeClass = objc_getClass("MRUContinuousSliderView");
    if (volumeClass && [slider isKindOfClass:volumeClass]) return 2;
    volumeClass = objc_getClass("MediaControlsVolumeSliderView");
    if (volumeClass && [slider isKindOfClass:volumeClass]) return 2;
    id description = LGGlyphIvar(slider, "_glyphPackageDescription", NULL);
    SEL urlSel = sel_registerName("packageURL");
    id url = [description respondsToSelector:urlSel]
        ? ((id (*)(id, SEL))objc_msgSend)(description, urlSel) : nil;
    NSString *name = [url respondsToSelector:@selector(lastPathComponent)] ? [url lastPathComponent] : nil;
    if (![name isKindOfClass:[NSString class]]) return 0;
    if ([name hasPrefix:@"Brightness"]) return 1;
    if ([name hasPrefix:@"Volume"]) return 2;
    return 0;
}

// Where the colour filter goes: a package view is a 0x0 layer with everything outside its bounds, so its direct
// sublayers; an image glyph has none, so its own layer
static NSArray *LGGlyphColorLayers(UIView *glyph) {
    NSArray *subs = glyph.layer.sublayers;
    return subs.count ? subs : @[glyph.layer];
}

static void LGGlyphRemoveColor(UIView *glyph) {
    for (CALayer *sub in LGGlyphColorLayers(glyph)) {
        NSArray *filters = sub.filters;
        if (filters.count == 1 &&
            [[filters.firstObject valueForKey:@"name"] isEqual:kLGGlyphFilterName]) sub.filters = nil;
    }
}

static void LGGlyphUpdateSlider(UIView *slider) {
    UIView *glyph = LGGlyphIvar(slider, "_activeGlyphView", "_glyphPackageView");
    if (![glyph isKindOfClass:[UIView class]]) return;
    int kind = LGGlyphSliderKind(slider);
    UIView *previous = objc_getAssociatedObject(slider, kLGGlyphColoredKey);
    BOOL want = kind && lgHostEnabled(@"ControlCenter") &&
                LG_prefBool(@"ControlCenter.SliderGlyphColors", YES);
    // the slider may swap its glyph view: hand the old one back first
    if (previous && (previous != glyph || !want)) {
        LGGlyphPunchRestore(previous.layer, 0);
        LGGlyphRemoveColor(previous);
        UIView *covered = objc_getAssociatedObject(slider, kLGGlyphCopyHiddenKey);
        if (covered) {
            if (covered.layer.mask == objc_getAssociatedObject(covered, kLGGlyphCopyMaskKey)) {
                covered.layer.mask = nil;
            }
            objc_setAssociatedObject(covered, kLGGlyphCopyMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(slider, kLGGlyphCopyHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(slider, kLGGlyphColoredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!want) return;
    // without a compensating copy of the same build there is no safe reference: the glyph stays as it is
    UIView *reference = LGGlyphIvar(slider, "_compensatingGlyphView", "_compensatingGlyphPackageView");
    if (![reference isKindOfClass:[UIView class]] || reference == glyph ||
        !LGGlyphSameShape(glyph.layer, reference.layer, 0)) return;
    LGGlyphPunchOut(glyph.layer, reference.layer, 0);
    for (CALayer *sub in LGGlyphColorLayers(glyph)) {
        NSArray *filters = sub.filters;
        if (filters.count == 1 &&
            [[filters.firstObject valueForKey:@"name"] isEqual:kLGGlyphFilterName]) continue;
        // measured in the reference screenshot: sun #FFC401, speaker #40B2FF
        id filter = kind == 1 ? LGGlyphColorFilter(1.0f, 0.77f, 0.0f)
                              : LGGlyphColorFilter(0.25f, 0.70f, 1.0f);
        if (filter) sub.filters = @[filter];
    }
    // The compensating copy (grey, lies over the glyph and shows it on the unfilled part) dulls the colour and
    // is not needed while the glyph itself is always drawn: left out with an empty mask
    if (!objc_getAssociatedObject(reference, kLGGlyphCopyMaskKey) && !reference.layer.mask) {
        CALayer *empty = [CALayer layer];
        reference.layer.mask = empty;
        objc_setAssociatedObject(reference, kLGGlyphCopyMaskKey, empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, kLGGlyphCopyHiddenKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(slider, kLGGlyphColoredKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGGlyphUpdate(UIView *slider) {
    @try {
        LGGlyphUpdateSlider(slider);
    } @catch (__unused id e) {
    }
}

// The system sets a glyph up for punch-out whenever it likes (new package, new state): colour now and once more
// on the next turn of the main queue.
static void LGGlyphUpdateSoon(UIView *slider) {
    LGGlyphUpdate(slider);
    if (objc_getAssociatedObject(slider, kLGGlyphPendingKey)) return;
    objc_setAssociatedObject(slider, kLGGlyphPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakSlider = slider;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strong = weakSlider;
        if (!strong) return;
        objc_setAssociatedObject(strong, kLGGlyphPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGGlyphUpdate(strong);
    });
}

%hook CCUIBaseSliderView

- (void)layoutSubviews {
    %orig;
    LGGlyphUpdateSoon((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGGlyphUpdateSoon((UIView *)self);
}

- (void)setGlyphPackageDescription:(id)description {
    %orig;
    LGGlyphUpdateSoon((UIView *)self);
}

- (void)setGlyphState:(id)state {
    %orig;
    LGGlyphUpdateSoon((UIView *)self);
}

%end
