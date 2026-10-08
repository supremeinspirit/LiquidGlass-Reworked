// LiquidAssFix: add-on for the stock dylv.liquidass 0.1.1b on iOS 17 (arm64e), loaded into SpringBoard.
// Runtime style on purpose: no @"" literals and no @implementation, because the on-device clang
// does not sign their isa and arm64e hosts die in objc_msgSend (see HIPChargeModule.m).
//
// Parts:
//  - layoutSubviews hook slots with replaceable handlers (a newer build loaded later through the
//    dev loader takes the handlers over, so fixes can be iterated without a respring)
//  - volume HUD glass for iOS 17's SBElasticSliderView (stock hooks a class that no longer exists)
//  - expanded Control Center slider modules, Dynamic Island glass, cover sheet, widget page
//  - a plain status log (OUTDIR/fix.log)
//
// The fixes were written for iOS 17; on older versions the add-on only applies the clear dark tint defaults.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/disabled

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <time.h>
#include <unistd.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define OUTDIR "/var/mobile/Library/Accessibility/lgdiag"
#define BUILD_TAG "v85"
#define MAX_SLOTS 12
#define MAX_HANDLERS 24

#define S(cstr) [NSString stringWithUTF8String:(cstr)]
// Association keys must be the same in every loaded build: a selector is unique per process, a static's address is not
#define KEY(name) ((const void *)sel_registerName(name))

typedef void (*LGFixHandler)(id object);

#pragma mark - log

static void flog(const char *fmt, ...) {
	// the private self-test runs the same code: its lines must not look like something that happened on screen
	if (getenv("LGFIX_SELFTEST")) return;
	FILE *f = fopen(OUTDIR "/fix.log", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	fprintf(f, "%.2f [" BUILD_TAG "] ", CFAbsoluteTimeGetCurrent());
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	va_end(ap);
	fclose(f);
}

// Everything that repeats (per layout, per island expansion, per widget) is only logged with CTLDIR/debug-log
static BOOL sVerbose;
#define vlog(...) do { if (sVerbose) flog(__VA_ARGS__); } while (0)

static void logSetup(void) {
	sVerbose = access(CTLDIR "/debug-log", F_OK) == 0;
	struct stat st;
	if (stat(OUTDIR "/fix.log", &st) == 0 && st.st_size > 64 * 1024) truncate(OUTDIR "/fix.log", 0);
}

#pragma mark - handler registry (owned by the first loaded build)

struct handlerEntry { char name[40]; LGFixHandler fn; };
static struct handlerEntry sHandlers[MAX_HANDLERS];

__attribute__((visibility("default"))) void lgfix_register(const char *name, LGFixHandler fn) {
	for (int i = 0; i < MAX_HANDLERS; i++) {
		if (!sHandlers[i].name[0] || !strcmp(sHandlers[i].name, name)) {
			strlcpy(sHandlers[i].name, name, sizeof(sHandlers[i].name));
			sHandlers[i].fn = fn;
			return;
		}
	}
}

static LGFixHandler handlerNamed(const char *name) {
	for (int i = 0; i < MAX_HANDLERS && sHandlers[i].name[0]; i++)
		if (!strcmp(sHandlers[i].name, name)) return sHandlers[i].fn;
	return NULL;
}

static void callHandler(const char *name, id object) {
	LGFixHandler fn = handlerNamed(name);
	if (!fn) return;
	@try {
		fn(object);
	} @catch (id e) {
		flog("handler %s threw", name);
	}
}

#pragma mark - layoutSubviews hook slots

struct hookSlot {
	Class cls;
	IMP orig;          // set when the class had its own layoutSubviews
	char handler[40];
	BOOL busy;
};
static struct hookSlot sSlots[MAX_SLOTS];

static void slotCall(int index, id self, SEL _cmd) {
	struct hookSlot *slot = &sSlots[index];
	if (slot->orig) {
		((void (*)(id, SEL))slot->orig)(self, _cmd);
	} else {
		struct objc_super sup = { self, class_getSuperclass(slot->cls) };
		((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
	}
	if (slot->busy) return;
	slot->busy = YES;
	callHandler(slot->handler, self);
	slot->busy = NO;
}

#define SLOT(n) static void slot##n(id self, SEL _cmd) { slotCall(n, self, _cmd); }
SLOT(0) SLOT(1) SLOT(2) SLOT(3) SLOT(4) SLOT(5) SLOT(6) SLOT(7) SLOT(8) SLOT(9) SLOT(10) SLOT(11)
// Filled at run time: a static initializer of function pointers is not signed correctly by the on-device toolchain
static IMP sSlotImps[MAX_SLOTS];
static void fillSlotImps(void) {
	if (sSlotImps[0]) return;
	sSlotImps[0] = (IMP)slot0; sSlotImps[1] = (IMP)slot1; sSlotImps[2] = (IMP)slot2; sSlotImps[3] = (IMP)slot3;
	sSlotImps[4] = (IMP)slot4; sSlotImps[5] = (IMP)slot5; sSlotImps[6] = (IMP)slot6; sSlotImps[7] = (IMP)slot7;
	sSlotImps[8] = (IMP)slot8; sSlotImps[9] = (IMP)slot9; sSlotImps[10] = (IMP)slot10; sSlotImps[11] = (IMP)slot11;
}

// Run handler `handlerName` after every -layoutSubviews of `className`. Returns 1 when hooked.
__attribute__((visibility("default"))) int lgfix_hook_layout(const char *className, const char *handlerName) {
	Class cls = objc_getClass(className);
	if (!cls) return 0;
	fillSlotImps();
	for (int i = 0; i < MAX_SLOTS; i++) {
		if (sSlots[i].cls == cls) {
			strlcpy(sSlots[i].handler, handlerName, sizeof(sSlots[i].handler));
			return 1;
		}
		if (sSlots[i].cls) continue;
		SEL sel = @selector(layoutSubviews);
		sSlots[i].cls = cls;
		strlcpy(sSlots[i].handler, handlerName, sizeof(sSlots[i].handler));
		if (!class_addMethod(cls, sel, sSlotImps[i], "v@:")) {
			unsigned int count = 0;
			Method *methods = class_copyMethodList(cls, &count);
			for (unsigned int m = 0; m < count; m++) {
				if (method_getName(methods[m]) == sel) {
					sSlots[i].orig = method_setImplementation(methods[m], sSlotImps[i]);
					break;
				}
			}
			free(methods);
			if (!sSlots[i].orig) {
				sSlots[i].cls = Nil;
				return 0;
			}
		}
		return 1;
	}
	return 0;
}

#pragma mark - liquidass.dylib API

static id (*pCreateGlass)(CGRect, id, id);
static void (*pTrackGlass)(id, id, id);
static BOOL (*pHostEnabled)(id);

static BOOL resolveLiquidAss(void) {
	if (pCreateGlass && pHostEnabled) return YES;
	pCreateGlass = dlsym(RTLD_DEFAULT, "LGCreateRegisteredGlass");
	pTrackGlass = dlsym(RTLD_DEFAULT, "lgTrackGlass");
	pHostEnabled = dlsym(RTLD_DEFAULT, "lgHostEnabled");
	return pCreateGlass && pHostEnabled;
}

static id ivarObject(id object, const char *name) {
	if (!object) return nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	if (!ivar) return nil;
	const char *type = ivar_getTypeEncoding(ivar);
	if (!type || type[0] != '@') return nil;
	return object_getIvar(object, ivar);
}

static void setContinuousCorners(CALayer *layer, CGFloat radius) {
	[layer setCornerRadius:radius];
	[layer setCornerCurve:kCACornerCurveContinuous];
}

#pragma mark - volume HUD (SBElasticSliderView, iOS 17)

static const char *cname(id obj);
static NSArray *allWindows(void);
static BOOL isNewestBuild(void);
static void widgetFillUpdate(id object);
static void widgetListUpdate(id object);
static void widgetFillWalk(UIView *view, Class cls, int depth);

static void volumeUpdate(id object) {
	UIView *slider = object;
	if (!resolveLiquidAss()) return;
	UIView *base = ivarObject(slider, "_baseMaterialView");
	UIView *capture = ivarObject(slider, "_captureOnlyMaterialView");
	UIView *shadow = ivarObject(slider, "_shadowView");
	UIView *glass = objc_getAssociatedObject(slider, KEY("lgfix_kVolumeGlassKey"));
	UIView *vibrance = objc_getAssociatedObject(slider, KEY("lgfix_kVolumeVibranceKey"));

	// The thin bar states (7 and 14 pt wide) are narrower than any glass bezel: the refraction has nothing to
	// sample and renders black. Use the stock material there.
	UIView *narrowBase = base;
	BOOL narrow = narrowBase && [narrowBase frame].size.width < 30.0 && access(CTLDIR "/glass-thin-bar", F_OK) != 0;
	if (narrow || !pHostEnabled(S("VolumeHUD"))) {
		[glass setHidden:YES];
		[vibrance setHidden:YES];
		[base setHidden:NO];
		[capture setHidden:NO];
		[shadow setHidden:NO];
		[(UIView *)ivarObject(slider, "_backgroundView") setAlpha:1.0];
		return;
	}
	UIView *host = [base superview];
	if (!base || !host) return;
	CGRect frame = [base frame];
	if (frame.size.width < 2.0 || frame.size.height < 2.0) return;

	[base setHidden:YES];
	[capture setHidden:YES];
	[shadow setHidden:YES];

	if (!glass) {
		glass = pCreateGlass(frame, nil, S("VolumeHUD"));
		if (!glass) return;
		[glass setUserInteractionEnabled:NO];
		objc_setAssociatedObject(slider, KEY("lgfix_kVolumeGlassKey"), glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (pTrackGlass) pTrackGlass(glass, S("VolumeHUD"), slider);
		vlog("volume: glass created for %s host=%s frame=%.0fx%.0f", class_getName(object_getClass(slider)),
		     class_getName(object_getClass(host)), frame.size.width, frame.size.height);
	}
	if (!vibrance) {
		Class cls = objc_getClass("LGVolumeHUDVibranceView");
		if (cls) vibrance = [[cls alloc] initWithFrame:frame];
		if (vibrance)
			objc_setAssociatedObject(slider, KEY("lgfix_kVolumeVibranceKey"), vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if ([glass superview] != host) [host insertSubview:glass aboveSubview:base];
	if (vibrance && [vibrance superview] != host) [host insertSubview:vibrance aboveSubview:glass];

	// Pill shape like the stock tweak on older iOS. The slider derives every radius from this fraction.
	SEL fractionSel = sel_registerName("cornerRadiusMinorAxisFraction");
	SEL setFractionSel = sel_registerName("setCornerRadiusMinorAxisFraction:");
	if ([slider respondsToSelector:fractionSel] && [slider respondsToSelector:setFractionSel] &&
	    fabs(((double (*)(id, SEL))objc_msgSend)(slider, fractionSel) - 0.5) > 0.001) {
		((void (*)(id, SEL, double))objc_msgSend)(slider, setFractionSel, 0.5);
		SEL updateSel = sel_registerName("_updateCornerRadius");
		if ([slider respondsToSelector:updateSel]) ((void (*)(id, SEL))objc_msgSend)(slider, updateSel);
	}
	CGFloat radius = MIN(frame.size.width, frame.size.height) * 0.5;
	// The slider's own track material (colorMatrix backdrop) darkens the glass under the unfilled part
	UIView *track = ivarObject(slider, "_backgroundView");
	BOOL clearTrack = access(CTLDIR "/keep-track", F_OK) != 0;
	if (track && fabs([track alpha] - (clearTrack ? 0.0 : 1.0)) > 0.01) [track setAlpha:clearTrack ? 0.0 : 1.0];
	if ([[host layer] masksToBounds]) setContinuousCorners([host layer], radius);
	CGSize oldSize = [glass bounds].size;
	BOOL resized = fabs(oldSize.width - frame.size.width) > 0.5 || fabs(oldSize.height - frame.size.height) > 0.5;
	[glass setHidden:NO];
	if (resized || !CGRectEqualToRect([glass frame], frame)) [glass setFrame:frame];
	setContinuousCorners([glass layer], radius);
	[[glass layer] setMasksToBounds:YES];
	if (resized && [glass respondsToSelector:@selector(applyFilters)])
		((void (*)(id, SEL))objc_msgSend)(glass, @selector(applyFilters));
	// Stock derives the capture scale from Global.Quality (0.1 here -> about 0.34 for the HUD, visibly soft).
	// The HUD is tiny, so always capture it at the top scale the tweak uses (0.75), like on a default-quality install.
	if (access(CTLDIR "/no-hud-scale", F_OK) != 0) {
		@try {
			id current = [[glass layer] valueForKey:S("scale")];
			if (![current respondsToSelector:@selector(doubleValue)] || fabs([current doubleValue] - 0.75) > 0.01)
				[[glass layer] setValue:[NSNumber numberWithDouble:0.75] forKey:S("scale")];
		} @catch (id e) {}
	}
	if (vibrance) {
		[vibrance setHidden:NO];
		if (!CGRectEqualToRect([vibrance frame], frame)) [vibrance setFrame:frame];
		setContinuousCorners([vibrance layer], radius);
		[[vibrance layer] setMasksToBounds:YES];
	}
}

#pragma mark - expanded Control Center module that is one big slider (WhitePointModule)

// Stock gives the expanded module container a glass with the module radius and the slider inside it a
// pill glass: two outlines at once. Keep the slider's pill, hide the container's glass while that holds.

static BOOL sLegacyOS;   // iOS 15 and 16

static UIView *directSubviewOfClass(UIView *view, const char *className) {
	Class cls = objc_getClass(className);
	if (!cls) return nil;
	for (UIView *sub in [view subviews])
		if ([sub isKindOfClass:cls]) return sub;
	return nil;
}

static UIView *findSlider(UIView *view, int depth) {
	Class cls = objc_getClass("CCUIContinuousSliderView");
	if (!cls || depth > 4) return nil;
	for (UIView *sub in [view subviews]) {
		if ([sub isKindOfClass:cls]) return sub;
		UIView *found = findSlider(sub, depth + 1);
		if (found) return found;
	}
	return nil;
}

// iOS 15 and 16: the container's glass is the slider's only background, so it stays. It only gets the slider's
// pill shape while the slider fills the whole container.

// The original 0.1.1-2b keeps a "desired radius" number on every layer it rounds and its -[CALayer setCornerRadius:]
// hook replaces any other value with it, so the pill radius never reached the container's material (square
// background behind a pill slider). Its association key is a static that holds its own address; find it once by
// looking through the original's __data for such slots and asking the locked layer which one carries a number.
static const void *sDesiredRadiusKey;

static const void *ccDesiredRadiusKey(CALayer *layer) {
	if (sDesiredRadiusKey) return sDesiredRadiusKey;
	static uintptr_t *sSlots;
	static unsigned long sSlotCount;
	static BOOL sLooked;
	if (!sLooked) {
		sLooked = YES;
		Dl_info info;
		// a symbol only the main dylib has (LG_prefBool is in LiquidAssRWB too, which SpringBoard also loads)
		void *symbol = dlsym(RTLD_DEFAULT, "LGInstallRegisteredGlassInMaterial");
		if (symbol && dladdr(symbol, &info) && info.dli_fbase) {
			unsigned long size = 0;
			uint8_t *data = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__data", &size);
			if (data) { sSlots = (uintptr_t *)data; sSlotCount = size / sizeof(uintptr_t); }
		}
	}
	for (unsigned long i = 0; i < sSlotCount; i++) {
		if (sSlots[i] != (uintptr_t)&sSlots[i]) continue;
		id value = objc_getAssociatedObject(layer, (const void *)&sSlots[i]);
		if (value && [value isKindOfClass:[NSNumber class]] && fabs([value doubleValue] - [layer cornerRadius]) <= 0.5) {
			sDesiredRadiusKey = (const void *)&sSlots[i];
			flog("cc: the original's radius lock found");
			break;
		}
	}
	return sDesiredRadiusKey;
}

// Sets the radius the original insists on for this layer; the value it had is kept for ccPillRelease
static void ccSetLockedRadius(UIView *view, CGFloat radius) {
	CALayer *layer = [view layer];
	const void *key = ccDesiredRadiusKey(layer);
	if (!key) return;
	id locked = objc_getAssociatedObject(layer, key);
	if (![locked isKindOfClass:[NSNumber class]] || fabs([locked doubleValue] - radius) <= 0.5) return;
	if (!objc_getAssociatedObject(view, KEY("lgfix_kPillPreviousRadiusKey")))
		objc_setAssociatedObject(view, KEY("lgfix_kPillPreviousRadiusKey"), locked, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(layer, key, [NSNumber numberWithDouble:radius], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ccFilterType(UIView *view) {
	@try {
		id type = [[[[view layer] filters] firstObject] valueForKey:S("type")];
		if ([type isKindOfClass:[NSString class]]) return type;
	} @catch (id e) {}
	return nil;
}

// The glass names its filter after its corner radius (".rN") and only picks a new one in applyFilters. The original
// puts the module radius back on every layout, so the layer could end up as a pill with the module-radius filter
// still attached (square glass behind a pill slider). Make the filter follow whenever it is not the one that was
// last chosen for the pill.
static void ccGlassRefilter(UIView *glass, BOOL changed) {
	if (![glass respondsToSelector:@selector(applyFilters)]) return;
	NSString *type = ccFilterType(glass);
	NSString *chosen = objc_getAssociatedObject(glass, KEY("lgfix_kPillFilterTypeKey"));
	if (!changed && type && chosen && [type isEqualToString:chosen]) return;
	((void (*)(id, SEL))objc_msgSend)(glass, @selector(applyFilters));
	if ([glass respondsToSelector:@selector(updateSpecular)]) ((void (*)(id, SEL))objc_msgSend)(glass, @selector(updateSpecular));
	objc_setAssociatedObject(glass, KEY("lgfix_kPillFilterTypeKey"), ccFilterType(glass), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ccPillRound(UIView *view, CGFloat radius) {
	ccSetLockedRadius(view, radius);
	BOOL changed = fabs([[view layer] cornerRadius] - radius) > 0.5;
	if (changed) {
		setContinuousCorners([view layer], radius);
		[[view layer] setMasksToBounds:YES];
		[view setNeedsLayout];
	}
	Class glassClass = objc_getClass("LGLiveBackdropView");
	if (glassClass && [view isKindOfClass:glassClass]) ccGlassRefilter(view, changed);
}

// The module is small again: hand the radius back that the original had chosen before
static void ccPillRelease(UIView *container) {
	if (!objc_getAssociatedObject(container, KEY("lgfix_kContainerPillLockedKey"))) return;
	objc_setAssociatedObject(container, KEY("lgfix_kContainerPillLockedKey"), nil, OBJC_ASSOCIATION_ASSIGN);
	for (UIView *sub in [container subviews]) {
		NSNumber *previous = objc_getAssociatedObject(sub, KEY("lgfix_kPillPreviousRadiusKey"));
		if (!previous) continue;
		objc_setAssociatedObject(sub, KEY("lgfix_kPillPreviousRadiusKey"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (sDesiredRadiusKey && objc_getAssociatedObject([sub layer], sDesiredRadiusKey))
			objc_setAssociatedObject([sub layer], sDesiredRadiusKey, previous, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[[sub layer] setCornerRadius:[previous doubleValue]];
		[sub setNeedsLayout];
	}
}

static void ccContainerPillUpdate(id object) {
	UIView *container = object;
	CGSize size = [container bounds].size;
	if (size.height <= 220.0 || size.width <= 60.0) { ccPillRelease(container); return; }
	UIView *slider = findSlider(container, 0);
	if (!slider || [slider isHidden]) { ccPillRelease(container); return; }
	CGSize s = [slider bounds].size;
	if (fabs(s.width - size.width) >= 16.0 || fabs(s.height - size.height) >= 16.0) { ccPillRelease(container); return; }
	CGFloat radius = MIN(size.width, size.height) * 0.5;
	Class glassClass = objc_getClass("LGLiveBackdropView"), materialClass = objc_getClass("MTMaterialView");
	int glasses = 0, materials = 0;
	for (UIView *sub in [container subviews]) {
		if (glassClass && [sub isKindOfClass:glassClass]) { ccPillRound(sub, radius); glasses++; }
		if (materialClass && [sub isKindOfClass:materialClass]) {
			ccPillRound(sub, radius);
			materials++;
			for (UIView *inner in [sub subviews])
				if (glassClass && [inner isKindOfClass:glassClass]) { ccPillRound(inner, radius); glasses++; }
		}
	}
	objc_setAssociatedObject(container, KEY("lgfix_kContainerPillLockedKey"), container, OBJC_ASSOCIATION_ASSIGN);
	if (!objc_getAssociatedObject(container, KEY("lgfix_kContainerPillKey"))) {
		objc_setAssociatedObject(container, KEY("lgfix_kContainerPillKey"), container, OBJC_ASSOCIATION_ASSIGN);
		vlog("cc: whole-module slider %.0fx%.0f, pill radius %.0f on %d glass, %d material", size.width, size.height,
		     radius, glasses, materials);
	}
}

// The module is laid out while it still expands and not again at the final size until it is touched.
// Apply the shape once more after each size change (not on every layout: that made dragging a slider lag).
static void ccContainerPillSettle(UIView *container) {
	ccContainerPillUpdate(container);
	CGSize size = [container bounds].size;
	NSValue *settled = objc_getAssociatedObject(container, KEY("lgfix_kContainerSettledSizeKey"));
	if (settled && CGSizeEqualToSize([settled CGSizeValue], size)) return;
	objc_setAssociatedObject(container, KEY("lgfix_kContainerSettledSizeKey"), [NSValue valueWithCGSize:size],
	                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	__weak UIView *weakContainer = container;
	for (int i = 0; i < 4; i++) {
		int64_t ms = i == 0 ? 120 : i == 1 ? 400 : i == 2 ? 900 : 1500;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			UIView *strong = weakContainer;
			if (!strong || ![strong window]) return;
			@try {
				// what a touch does: the slider lays out again and the stock tweak rounds its parts
				UIView *slider = findSlider(strong, 0);
				[slider setNeedsLayout];
				[slider layoutIfNeeded];
				ccContainerPillUpdate(strong);
			} @catch (id e) {}
		});
	}
}

static void ccMediaStyleUpdate(id object);

static void ccContainerUpdate(id object) {
	if (sLegacyOS) { ccContainerPillSettle(object); return; }
	ccMediaStyleUpdate(object);
	UIView *container = object;
	UIView *glass = directSubviewOfClass(container, "LGLiveBackdropView");
	if (!glass) return;
	CGSize size = [container bounds].size;
	BOOL wholeSlider = NO;
	if (size.height > 220.0 && size.width > 60.0) {
		UIView *slider = findSlider(container, 0);
		if (slider && ![slider isHidden]) {
			CGSize s = [slider bounds].size;
			wholeSlider = fabs(s.width - size.width) < 16.0 && fabs(s.height - size.height) < 16.0;
		}
	}
	BOOL hiddenByMe = objc_getAssociatedObject(container, KEY("lgfix_kContainerGlassHiddenKey")) != nil;
	if (wholeSlider) {
		if (![glass isHidden]) [glass setHidden:YES];
		if (!hiddenByMe) {
			objc_setAssociatedObject(container, KEY("lgfix_kContainerGlassHiddenKey"), glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			vlog("cc: container glass hidden for whole-module slider %.0fx%.0f", size.width, size.height);
		}
	} else if (hiddenByMe) {
		[glass setHidden:NO];
		objc_setAssociatedObject(container, KEY("lgfix_kContainerGlassHiddenKey"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

static void ccSliderUpdate(id object) {
	Class cls = objc_getClass("CCUIContentModuleContentContainerView");
	if (!cls) return;
	int level = 0;
	for (UIView *v = [(UIView *)object superview]; v && level < 4; v = [v superview], level++) {
		if ([v isKindOfClass:cls]) {
			ccContainerUpdate(v);
			return;
		}
	}
}

#pragma mark - Control Center toggles: no white fill when switched on

// A switched-on module (CCUIButtonModuleView) gets a white fill over the whole module. Leave that out, so only
// the glyph changes to its "on" colour. Kill switch CTLDIR/keep-toggle-white.
static void ccToggleUpdate(id object) {
	static int keep = -1;
	if (keep < 0) keep = access(CTLDIR "/keep-toggle-white", F_OK) == 0;
	if (keep) return;
	UIView *fill = ivarObject(object, "_highlightedBackgroundView");
	if (![fill isKindOfClass:[UIView class]]) return;
	BOOL want = !resolveLiquidAss() || pHostEnabled(S("ControlCenter"));
	BOOL masked = objc_getAssociatedObject(fill, KEY("lgfix_kToggleFillMaskKey")) != nil;
	if (want && !masked) {
		CALayer *mask = [CALayer layer];
		[[fill layer] setMask:mask];
		objc_setAssociatedObject(fill, KEY("lgfix_kToggleFillMaskKey"), mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	} else if (!want && masked) {
		[[fill layer] setMask:nil];
		objc_setAssociatedObject(fill, KEY("lgfix_kToggleFillMaskKey"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

#pragma mark - Now Playing module on iOS 15 and 16

// The module's platter gets its glass from the stock tweak, but a legacy _UIBackdropView (blur plus a white
// veil) lies on top of it and hides the glass. Leave that view out while the glass is there.
// Kill switch CTLDIR/no-media-glass.
static UIView *findView(UIView *view, Class cls, int levels);

static void ccMediaApply(UIView *container) {
	Class glassClass = objc_getClass("LGLiveBackdropView"), backdropClass = objc_getClass("_UIBackdropView");
	Class mediaClass = objc_getClass("MRUControlCenterView");
	if (!glassClass || !backdropClass || !mediaClass || ![container window]) return;
	UIView *media = findView(container, mediaClass, 6);
	int masked = 0;
	for (UIView *holder in [media subviews]) {
		UIView *glass = nil;
		for (UIView *sub in [holder subviews])
			if ([sub isKindOfClass:glassClass] && ![sub isHidden]) glass = sub;
		for (UIView *sub in [holder subviews]) {
			if (![sub isKindOfClass:backdropClass]) continue;
			BOOL mine = objc_getAssociatedObject(sub, KEY("lgfix_kMediaBackdropMaskKey")) != nil;
			if (glass && !mine) {
				CALayer *mask = [CALayer layer];
				[[sub layer] setMask:mask];
				objc_setAssociatedObject(sub, KEY("lgfix_kMediaBackdropMaskKey"), mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				masked++;
			} else if (!glass && mine) {
				[[sub layer] setMask:nil];
				objc_setAssociatedObject(sub, KEY("lgfix_kMediaBackdropMaskKey"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
		}
	}
	if (masked) vlog("media: backdrop over the module glass left out (%d)", masked);
}

static void ccMediaUpdate(id object) {
	static int off = -1;
	if (off < 0) off = access(CTLDIR "/no-media-glass", F_OK) == 0;
	if (off || !resolveLiquidAss() || !pHostEnabled(S("ControlCenter"))) return;
	Class containerClass = objc_getClass("CCUIContentModuleContainerView");
	UIView *container = nil;
	for (UIView *v = object; v && containerClass; v = [v superview])
		if ([v isKindOfClass:containerClass]) { container = v; break; }
	if (!container || ![container window]) return;
	if (objc_getAssociatedObject(container, KEY("lgfix_kMediaPendingKey"))) return;
	objc_setAssociatedObject(container, KEY("lgfix_kMediaPendingKey"), container, OBJC_ASSOCIATION_ASSIGN);
	__weak UIView *weakContainer = container;
	// after the stock tweak had its turn on the material
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		UIView *strong = weakContainer;
		if (!strong) return;
		objc_setAssociatedObject(strong, KEY("lgfix_kMediaPendingKey"), nil, OBJC_ASSOCIATION_ASSIGN);
		@try { ccMediaApply(strong); } @catch (id e) {}
	});
}

#pragma mark - Now Playing module on iOS 17: same glass variant as the other modules

static UIView *findView(UIView *view, Class cls, int levels) {
	if (!view || levels < 0) return nil;
	if ([view isKindOfClass:cls]) return view;
	for (UIView *sub in [view subviews]) {
		UIView *found = findView(sub, cls, levels - 1);
		if (found) return found;
	}
	return nil;
}

// The Now Playing module forces the dark interface style on its views, so its glass picked the ".dark" variant
// (clear dark tint) while every other module shows the light variant (white tint): it looked more transparent
// than the rest. Give its glass the interface style the glass of the other modules has.
// Kill switch CTLDIR/keep-media-style.
static int ccMediaStyleWalk(UIView *view, Class glassClass, NSInteger style, int depth) {
	if (!view || depth > 8) return 0;
	int changed = 0;
	for (UIView *sub in [view subviews]) {
		if ([sub isKindOfClass:glassClass]) {
			if ([sub overrideUserInterfaceStyle] != style) { [sub setOverrideUserInterfaceStyle:style]; changed++; }
		} else changed += ccMediaStyleWalk(sub, glassClass, style, depth + 1);
	}
	return changed;
}

static void ccMediaStyleApply(UIView *media) {
	Class glassClass = objc_getClass("LGLiveBackdropView");
	Class moduleClass = objc_getClass("CCUIContentModuleContainerView"), mediaClass = object_getClass(media);
	if (!glassClass || !moduleClass || ![media window]) return;
	// reference: the glass of a neighbouring module (remembered while the module is expanded on its own)
	static NSInteger sStyle = UIUserInterfaceStyleUnspecified;
	UIView *module = media;
	while (module && ![module isKindOfClass:moduleClass]) module = [module superview];
	for (UIView *other in [[module superview] subviews]) {
		if (other == module || ![other isKindOfClass:moduleClass] || findView(other, mediaClass, 10)) continue;
		UIView *glass = findView(other, glassClass, 20);
		if (!glass) continue;
		sStyle = [[glass traitCollection] userInterfaceStyle];
		break;
	}
	if (sStyle != UIUserInterfaceStyleLight && sStyle != UIUserInterfaceStyleDark) return;
	int changed = ccMediaStyleWalk(media, glassClass, sStyle, 0);
	if (changed) vlog("media: %d glass set to the style of the other modules (%ld)", changed, (long)sStyle);
}

static void ccMediaStyleUpdate(id object) {
	static int keep = -1;
	if (keep < 0) keep = access(CTLDIR "/keep-media-style", F_OK) == 0;
	if (keep || sLegacyOS) return;
	Class mediaClass = objc_getClass("MRUControlCenterView");
	if (!mediaClass) return;
	UIView *media = [object isKindOfClass:mediaClass] ? object : directSubviewOfClass(object, "MRUControlCenterView");
	if (!media) return;
	@try { ccMediaStyleApply(media); } @catch (id e) {}
	// the stock tweak may create the glass after this layout
	if (objc_getAssociatedObject(media, KEY("lgfix_kMediaStylePendingKey"))) return;
	objc_setAssociatedObject(media, KEY("lgfix_kMediaStylePendingKey"), media, OBJC_ASSOCIATION_ASSIGN);
	__weak UIView *weakMedia = media;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		UIView *strong = weakMedia;
		if (!strong) return;
		objc_setAssociatedObject(strong, KEY("lgfix_kMediaStylePendingKey"), nil, OBJC_ASSOCIATION_ASSIGN);
		@try { ccMediaStyleApply(strong); } @catch (id e) {}
	});
}

#pragma mark - Dynamic Island as the "pill HUD" (ringer / silent mode etc. on island phones)

// Phones with a Dynamic Island never show SBRingerPillView / PLPillView: those alerts expand the island.
// The island is a black blob (black fill views next to the curtain over the camera cutout). While it is
// expanded beyond the cutout, hide the black fill and put a
// PillHUD glass into the island's container. The cutout itself stays black (it is hardware).
static __weak UIView *sIslandCurtain;
static __weak UIView *sIslandContainer;

static BOOL layerOpaqueBlack(CALayer *layer) {
	CGColorRef bg = [layer backgroundColor];
	if (!bg || CGColorGetAlpha(bg) < 0.9) return NO;
	const CGFloat *c = CGColorGetComponents(bg);
	size_t n = CGColorGetNumberOfComponents(bg);
	for (size_t i = 0; i + 1 < n; i++)
		if (c[i] > 0.05) return NO;
	return YES;
}

// Hidden with an empty mask layer: the system animates alpha / hidden of these views during transitions,
// it never touches their mask.
static void islandSetFill(UIView *fill, BOOL hidden, BOOL requireBlack) {
	if (!fill) return;
	CALayer *mine = objc_getAssociatedObject(fill, KEY("lgfix_islandMask"));
	if (hidden) {
		if (mine || [[fill layer] mask] || (requireBlack && !layerOpaqueBlack([fill layer]))) return;
		CALayer *empty = [CALayer layer];
		[[fill layer] setMask:empty];
		objc_setAssociatedObject(fill, KEY("lgfix_islandMask"), empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		vlog("island: %s masked %.0fx%.0f", cname(fill), [fill bounds].size.width, [fill bounds].size.height);
	} else if (mine) {
		if ([[fill layer] mask] == mine) [[fill layer] setMask:nil];
		objc_setAssociatedObject(fill, KEY("lgfix_islandMask"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

// Gain map views (CAGainMapLayer) act on the display's brightness and do not show in screen captures.
// A mask alone left a dark outline on the real display, so they also get alpha 0 (re-applied on every
// layout, the system may animate it back).
static void islandSetGainHidden(UIView *view, BOOL hidden) {
	if (!view) return;
	islandSetFill(view, hidden, NO);
	// Collapses the gain map layers themselves; unlike alpha, nothing in the system animates this
	BOOL collapsed = objc_getAssociatedObject(view, KEY("lgfix_islandGainCollapsed")) != nil;
	if (hidden && !collapsed) {
		[[view layer] setSublayerTransform:CATransform3DMakeScale(0.0001, 0.0001, 1.0)];
		objc_setAssociatedObject(view, KEY("lgfix_islandGainCollapsed"), view, OBJC_ASSOCIATION_ASSIGN);
	} else if (!hidden && collapsed) {
		[[view layer] setSublayerTransform:CATransform3DIdentity];
		objc_setAssociatedObject(view, KEY("lgfix_islandGainCollapsed"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
	BOOL mine = objc_getAssociatedObject(view, KEY("lgfix_islandGainAlpha")) != nil;
	if (hidden) {
		if ([view alpha] > 0.01) {
			[view setAlpha:0.0];
			objc_setAssociatedObject(view, KEY("lgfix_islandGainAlpha"), view, OBJC_ASSOCIATION_ASSIGN);
		}
	} else if (mine) {
		[view setAlpha:1.0];
		objc_setAssociatedObject(view, KEY("lgfix_islandGainAlpha"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
}

static void islandSetGainMapsHidden(UIView *view, Class gainClass, Class curtainClass, BOOL hidden, int depth) {
	if (!view || depth > 5 || [view isKindOfClass:curtainClass]) return;
	if ([view isKindOfClass:gainClass]) {
		islandSetGainHidden(view, hidden);
		return;
	}
	for (UIView *sub in [view subviews]) islandSetGainMapsHidden(sub, gainClass, curtainClass, hidden, depth + 1);
}

// The island's black body on 17.3: opaque black views in the siblings of the cutout curtain
// (_SBSystemApertureMagiciansCurtainView) and the body's gain map view (CAGainMapLayer, draws black).
// The curtain itself stays, it covers the hardware cutout.
static void islandSetFillsHidden(UIView *window, BOOL hidden) {
	UIView *curtain = sIslandCurtain;
	Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
	Class gainClass = objc_getClass("_SBSystemApertureGainMapView");
	if (!curtainClass) return;
	if (!curtain || [curtain window] != window) sIslandCurtain = curtain = findView(window, curtainClass, 6);
	for (UIView *blob in [[curtain superview] subviews]) {
		if (blob == curtain) continue;
		for (UIView *fill in [blob subviews]) islandSetFill(fill, hidden, YES);
	}
	if (gainClass) islandSetGainMapsHidden(window, gainClass, curtainClass, hidden, 0);
}

// The black pill over the camera cutout (_SBSystemApertureMagiciansCurtainView, one in each island window).
// On the display the hardware sits there; in a screenshot it is a black bar in the middle of the glass
// island. With DynamicIsland.ClearCutout on it is left out (empty mask) for as long as the island is glass.
// Kill switch: CTLDIR/keep-cutout
static NSHashTable *sIslandCurtains;
static CFAbsoluteTime sIslandCurtainScan;

static BOOL islandClearCutoutWanted(void) {
	if (access(CTLDIR "/keep-cutout", F_OK) == 0) return NO;
	BOOL (*prefBool)(id, BOOL) = dlsym(RTLD_DEFAULT, "LG_prefBool");
	return prefBool ? prefBool(S("DynamicIsland.ClearCutout"), NO) : NO;
}

static void islandSetCutoutClear(BOOL clear) {
	Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
	if (!curtainClass) return;
	if (!sIslandCurtains) sIslandCurtains = [NSHashTable weakObjectsHashTable];
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (clear && [[sIslandCurtains allObjects] count] < 2 && now - sIslandCurtainScan > 1.0) {
		sIslandCurtainScan = now;
		for (UIWindow *window in allWindows()) {
			if (strcmp(cname(window), "SBSystemApertureWindow")) continue;
			UIView *curtain = findView(window, curtainClass, 6);
			if (curtain && ![sIslandCurtains containsObject:curtain]) [sIslandCurtains addObject:curtain];
		}
	}
	for (UIView *curtain in [sIslandCurtains allObjects]) {
		BOOL was = objc_getAssociatedObject(curtain, KEY("lgfix_islandMask")) != nil;
		islandSetFill(curtain, clear, NO);
		BOOL is = objc_getAssociatedObject(curtain, KEY("lgfix_islandMask")) != nil;
		if (was != is) flog("island: camera pill %s (%.0fx%.0f)", is ? "left out" : "back", [curtain bounds].size.width, [curtain bounds].size.height);
	}
}

// Views of the container itself that draw black: the fill that enables the blob effect (shown during
// transitions) and the container's gain map
static void islandSetContainerFillsHidden(UIView *container, BOOL hidden) {
	if (access(CTLDIR "/keep-blob-fill", F_OK) != 0)
		islandSetFill(ivarObject(container, "_blobEnablingBlackFillView"), hidden, NO);
	islandSetGainHidden(ivarObject(container, "_gainMapView"), hidden);
	// The transition shadow lies above the glass: on the stock island its inside is covered by the black
	// body, on glass it darkens the whole island for as long as the size animates
	if (access(CTLDIR "/keep-shadow", F_OK) != 0) islandSetFill(ivarObject(container, "_shadowView"), hidden, NO);
	// Key lines: rounded rects 1.7 pt larger than the island (a darkening backdrop and a plus-lighter fill).
	// The black body normally covers all but that outer ring; on glass the ring reads as a black border.
	if (access(CTLDIR "/keep-keyline", F_OK) != 0) {
		islandSetFill(ivarObject(container, "_lightBkgKeyLineView"), hidden, NO);
		islandSetFill(ivarObject(container, "_darkBkgKeyLineView"), hidden, NO);
	}
}

// System indicators (flashlight, ringer, ...) are CAPackages drawn on an opaque black square, invisible on the
// stock black island and a black box on glass. A color matrix on the portal that shows them turns brightness
// into alpha (black -> transparent, light stays). Only for package-based views: artwork etc. is left alone.
static BOOL viewTreeHasClass(UIView *view, Class cls, int depth) {
	if (!view || depth > 4) return NO;
	if ([view isKindOfClass:cls]) return YES;
	for (UIView *sub in [view subviews])
		if (viewTreeHasClass(sub, cls, depth + 1)) return YES;
	return NO;
}

static id blackKeyFilter(void) {
	Class filterClass = objc_getClass("CAFilter");
	SEL make = sel_registerName("filterWithType:");
	if (!filterClass || !class_getClassMethod(filterClass, make)) return nil;
	id filter = ((id (*)(id, SEL, id))objc_msgSend)((id)filterClass, make, S("colorMatrix"));
	// rows R, G, B, A; columns r, g, b, a, bias. Alpha = r + g + b: black turns transparent, anything with
	// a third of full brightness or a saturated color stays opaque.
	float m[20] = { 1, 0, 0, 0, 0,   0, 1, 0, 0, 0,   0, 0, 1, 0, 0,   1, 1, 1, 0, 0 };
	[filter setValue:[NSValue valueWithBytes:m objCType:"{CAColorMatrix=ffffffffffffffffffff}"] forKey:S("inputColorMatrix")];
	[filter setValue:S("lgfixBlackKey") forKey:S("name")];
	return filter;
}

// The view a CAPortalLayer-backed view shows
static UIView *portalSourceView(UIView *portal) {
	Class portalLayerClass = objc_getClass("CAPortalLayer");
	CALayer *layer = [portal layer];
	SEL sourceSel = sel_registerName("sourceLayer");
	if (!portalLayerClass || ![layer isKindOfClass:portalLayerClass] || ![layer respondsToSelector:sourceSel]) return nil;
	CALayer *source = ((id (*)(id, SEL))objc_msgSend)(layer, sourceSel);
	id delegate = [source delegate];
	return [delegate isKindOfClass:[UIView class]] ? delegate : nil;
}

// Opaque black layers that span the whole indicator package (its "Root Layer" and state root): the backing
// the glyph is drawn on. Smaller black layers are part of the glyph and stay.
static void packageSetBackingCleared(CALayer *layer, CGSize full, BOOL cleared, int depth) {
	if (!layer || depth > 4) return;
	CGSize size = [layer bounds].size;
	BOOL mine = objc_getAssociatedObject(layer, KEY("lgfix_islandBacking")) != nil;
	if (cleared && !mine && layerOpaqueBlack(layer) && size.width >= full.width * 0.9 && size.height >= full.height * 0.9) {
		[layer setBackgroundColor:[[UIColor clearColor] CGColor]];
		objc_setAssociatedObject(layer, KEY("lgfix_islandBacking"), layer, OBJC_ASSOCIATION_ASSIGN);
		const char *name = [[layer name] UTF8String];
		vlog("island: package backing cleared (%s)", name ? name : "?");
	} else if (!cleared && mine) {
		[layer setBackgroundColor:[[UIColor blackColor] CGColor]];
		objc_setAssociatedObject(layer, KEY("lgfix_islandBacking"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
	// sublayers are laid out in the package's own (unscaled) size
	for (CALayer *sub in [layer sublayers]) packageSetBackingCleared(sub, depth == 0 ? [sub bounds].size : full, cleared, depth + 1);
}

static void packageViewsSetBackingCleared(UIView *view, Class packageClass, BOOL cleared, int depth) {
	if (!view || depth > 4) return;
	if ([view isKindOfClass:packageClass]) {
		for (CALayer *sub in [[view layer] sublayers]) packageSetBackingCleared(sub, [sub bounds].size, cleared, 0);
		return;
	}
	for (UIView *sub in [view subviews]) packageViewsSetBackingCleared(sub, packageClass, cleared, depth + 1);
}

static void islandSetPortalKeyed(UIView *transformView, BOOL keyed) {
	Class packageClass = objc_getClass("_SBUISystemApertureCAPackageView");
	if (!transformView || !packageClass) return;
	for (UIView *portal in [transformView subviews]) {
		BOOL mine = objc_getAssociatedObject(portal, KEY("lgfix_islandKeyed")) != nil;
		UIView *source = portalSourceView(portal);
		BOOL want = keyed && viewTreeHasClass(source, packageClass, 0);
		if (source && (want || !keyed)) packageViewsSetBackingCleared(source, packageClass, want, 0);
		if (want && !mine && ![[[portal layer] filters] count]) {
			id filter = blackKeyFilter();
			if (!filter) return;
			[[portal layer] setFilters:[NSArray arrayWithObject:filter]];
			objc_setAssociatedObject(portal, KEY("lgfix_islandKeyed"), portal, OBJC_ASSOCIATION_ASSIGN);
			vlog("island: black keyed out of %s %.0fx%.0f", cname(portal), [portal bounds].size.width, [portal bounds].size.height);
		} else if (!want && mine) {
			[[portal layer] setFilters:nil];
			objc_setAssociatedObject(portal, KEY("lgfix_islandKeyed"), nil, OBJC_ASSOCIATION_ASSIGN);
		}
	}
}

static void islandSetFill(UIView *fill, BOOL hidden, BOOL requireBlack);

// Now Playing: the audio wave (MRUWaveformView) comes in the variant made for the black island: an opaque black
// view over the color layers with the bars punched out of it (destOut). On glass that is a black box behind the
// wave. Drawn plain instead: no backing, the bars as they are (white), the color layers left out. Nothing here
// blends with what lies behind the wave: a destIn on the bars view (the view's own clear variant) took the whole
// island with it. Kill switch: CTLDIR/keep-waveform-black
static void islandSetWaveformClear(UIView *wave, BOOL clear) {
	UIView *bars = ivarObject(wave, "_barsView");
	if (!bars) return;
	CALayer *layer = [bars layer];
	BOOL mine = objc_getAssociatedObject(wave, KEY("lgfix_islandWave")) != nil;
	if (clear) {
		// only the black variant, and only while it is exactly that
		if (!mine && (!layerOpaqueBlack(layer) || [layer compositingFilter])) return;
		if ([layer backgroundColor]) [bars setBackgroundColor:nil];
		for (CALayer *bar in [layer sublayers])
			if ([bar compositingFilter]) [bar setCompositingFilter:nil];
		// the color layers under the bars view (a blurred color field and a gray multiply layer): left out with
		// an empty mask, the view animates their opacity itself
		int colors = 0;
		for (CALayer *sibling in [[layer superlayer] sublayers]) {
			if (sibling == layer) continue;
			colors++;
			if (objc_getAssociatedObject(sibling, KEY("lgfix_islandWaveMask")) || [sibling mask]) continue;
			CALayer *empty = [CALayer layer];
			[sibling setMask:empty];
			objc_setAssociatedObject(sibling, KEY("lgfix_islandWaveMask"), empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if (!mine) {
			objc_setAssociatedObject(wave, KEY("lgfix_islandWave"), wave, OBJC_ASSOCIATION_ASSIGN);
			flog("island: audio wave drawn plain, without its black backing (%lu bars, %d color layers left out)",
			     (unsigned long)[[layer sublayers] count], colors);
		}
	} else if (mine) {
		for (CALayer *sibling in [[layer superlayer] sublayers]) {
			CALayer *empty = objc_getAssociatedObject(sibling, KEY("lgfix_islandWaveMask"));
			if (!empty) continue;
			if ([sibling mask] == empty) [sibling setMask:nil];
			objc_setAssociatedObject(sibling, KEY("lgfix_islandWaveMask"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		[bars setBackgroundColor:[UIColor blackColor]];
		for (CALayer *bar in [layer sublayers]) [bar setCompositingFilter:S("destOut")];
		objc_setAssociatedObject(wave, KEY("lgfix_islandWave"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
}

static void islandWaveformWalk(UIView *view, Class waveClass, BOOL clear, int depth) {
	if (!view || depth > 12) return;
	if ([view isKindOfClass:waveClass]) {
		islandSetWaveformClear(view, clear);
		return;
	}
	for (UIView *sub in [view subviews]) islandWaveformWalk(sub, waveClass, clear, depth + 1);
}

// The wave is not a subview of the element view (the island shows it through a portal), so the walk above does
// not reach it: the wave views report themselves at their own layout and are kept here (weakly).
static NSHashTable *sIslandWaves;

static void islandWavesApply(BOOL clear) {
	for (UIView *wave in [sIslandWaves allObjects]) islandSetWaveformClear(wave, clear);
}

static void islandWaveUpdate(id object) {
	if (!sIslandWaves) sIslandWaves = [NSHashTable weakObjectsHashTable];
	if (![sIslandWaves containsObject:object]) [sIslandWaves addObject:object];
	UIView *container = sIslandContainer;
	UIView *glass = container ? objc_getAssociatedObject(container, KEY("lgfix_kIslandGlassKey")) : nil;
	islandSetWaveformClear(object, glass && ![glass isHidden] && access(CTLDIR "/keep-waveform-black", F_OK) != 0);
}

// Content of the element shown in the island: its indicator views and the snapshot the system cross-fades
// from during a size transition (it is taken of the black island)
static void islandSetElementAdapted(UIView *container, BOOL adapted) {
	id controller = ivarObject(container, "_elementViewController");
	if (!controller) return;
	BOOL keyOut = adapted && access(CTLDIR "/keep-indicator-black", F_OK) != 0;
	id elementView = ivarObject(controller, "_elementView");
	islandSetPortalKeyed(ivarObject(elementView, "_leadingTransformView"), keyOut);
	islandSetPortalKeyed(ivarObject(elementView, "_trailingTransformView"), keyOut);
	islandSetPortalKeyed(ivarObject(elementView, "_minimalTransformView"), keyOut);
	Class waveClass = objc_getClass("MRUWaveformView");
	if (waveClass && [elementView isKindOfClass:[UIView class]])
		islandWaveformWalk(elementView, waveClass, adapted && access(CTLDIR "/keep-waveform-black", F_OK) != 0, 0);
	islandWavesApply(adapted && access(CTLDIR "/keep-waveform-black", F_OK) != 0);
	if (access(CTLDIR "/keep-snapshot", F_OK) != 0) {
		islandSetFill(ivarObject(controller, "_snapshotView"), adapted, NO);
		// Image view next to the element view, centered on the island and clipped to its shape: alpha 1 at the
		// start of a size transition, fading to 0. On glass it shows as a black blob growing out of the cutout.
		SEL loadedSel = sel_registerName("isViewLoaded");
		if ([controller respondsToSelector:loadedSel] && ((BOOL (*)(id, SEL))objc_msgSend)(controller, loadedSel)) {
			for (UIView *sub in [[(UIViewController *)controller view] subviews])
				if ([sub isKindOfClass:[UIImageView class]]) islandSetFill(sub, adapted, NO);
		}
	}
}

static void islandElementUpdate(id object) {
	Class containerClass = objc_getClass("SBSystemApertureContainerView");
	if (!containerClass) return;
	int level = 0;
	for (UIView *v = [(UIView *)object superview]; v && level < 10; v = [v superview], level++) {
		if (![v isKindOfClass:containerClass]) continue;
		UIView *glass = objc_getAssociatedObject(v, KEY("lgfix_kIslandGlassKey"));
		if (glass && ![glass isHidden]) islandSetElementAdapted(v, YES);
		return;
	}
}

static BOOL (*pPrefBool)(id, BOOL);
static id (*pPrefString)(id, id);

static BOOL islandEnabled(void) {
	if (access(CTLDIR "/no-island", F_OK) == 0 || !pHostEnabled(S("PillHUD"))) return NO;
	if (!pPrefBool) pPrefBool = dlsym(RTLD_DEFAULT, "LG_prefBool");
	return pPrefBool ? pPrefBool(S("DynamicIsland.Enabled"), YES) : YES;
}

// "#RRGGBBAA" from DynamicIsland.TintColor (alpha scaled down); nil when unset or fully transparent
static UIColor *islandTintColor(void) {
	if (!pPrefString) pPrefString = dlsym(RTLD_DEFAULT, "LG_prefString");
	id value = pPrefString ? pPrefString(S("DynamicIsland.TintColor"), nil) : nil;
	if (![value isKindOfClass:[NSString class]]) return nil;
	const char *hex = [value UTF8String];
	unsigned int r = 0, g = 0, b = 0, a = 255;
	if (!hex || hex[0] != '#' || sscanf(hex + 1, "%2x%2x%2x%2x", &r, &g, &b, &a) < 3 || a == 0) return nil;
	// The overlay sits above the glass, so a fully opaque pick (the Settings color picker writes alpha FF)
	// would cover it completely. Full alpha maps to a 35 % wash.
	CGFloat strength = access(CTLDIR "/island-tint-opaque", F_OK) == 0 ? 1.0 : 0.35;
	return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0 * strength];
}

static void islandUpdate(id object) {
	UIView *container = object;
	sIslandContainer = container;
	UIView *window = [container window];
	if (!window || !resolveLiquidAss()) return;
	UIView *glass = objc_getAssociatedObject(container, KEY("lgfix_kIslandGlassKey"));
	CGSize size = [container bounds].size;
	// Resting size on this phone is about 125 x 37: only treat a clearly expanded island
	BOOL expanded = size.width > 150.0 || size.height > 48.0;
	BOOL enabled = islandEnabled();
	// Collapsing: the size jumps to the resting size when the animation starts. Stay glass until it has
	// played out, otherwise the black body is back for the whole animation.
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (enabled && expanded) {
		objc_setAssociatedObject(container, KEY("lgfix_islandLinger"), [NSNumber numberWithDouble:now + 0.7], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	} else if (enabled && glass && ![glass isHidden] && access(CTLDIR "/no-island-linger", F_OK) != 0) {
		double until = [objc_getAssociatedObject(container, KEY("lgfix_islandLinger")) doubleValue];
		// The collapse can run longer than the fixed linger: as long as the island on screen is still larger
		// than its resting size, the black body would show as a black pill shrinking.
		CALayer *presentation = [[container layer] presentationLayer];
		CGSize shown = presentation ? [presentation bounds].size : size;
		BOOL animating = fabs(shown.width - size.width) > 1.0 || fabs(shown.height - size.height) > 1.0;
		if (now >= until && animating && now < until + 2.5) until = now + 0.05;
		if (now < until) {
			expanded = YES;
			if (!objc_getAssociatedObject(container, KEY("lgfix_islandLingerTimer"))) {
				objc_setAssociatedObject(container, KEY("lgfix_islandLingerTimer"), container, OBJC_ASSOCIATION_ASSIGN);
				__weak UIView *weakContainer = container;
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((until - now + 0.03) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					UIView *strong = weakContainer;
					if (!strong) return;
					objc_setAssociatedObject(strong, KEY("lgfix_islandLingerTimer"), nil, OBJC_ASSOCIATION_ASSIGN);
					[strong setNeedsLayout];
				});
			}
		}
	}
	UIView *tint = objc_getAssociatedObject(container, KEY("lgfix_islandTint"));
	if (!enabled || !expanded) {
		[tint setHidden:YES];
		if (glass && ![glass isHidden]) {
			[glass setHidden:YES];
			CALayer *presentation = [[container layer] presentationLayer];
			vlog("island: stock look restored, model %.0fx%.0f on screen %.0fx%.0f", size.width, size.height,
			     presentation ? [presentation bounds].size.width : -1.0, presentation ? [presentation bounds].size.height : -1.0);
			islandSetFillsHidden(window, NO);
			islandSetContainerFillsHidden(container, NO);
			islandSetElementAdapted(container, NO);
			islandSetCutoutClear(NO);
		}
		return;
	}
	CGRect frame = [container bounds];
	if (!glass) {
		glass = pCreateGlass(frame, nil, S("PillHUD"));
		if (!glass) return;
		[glass setUserInteractionEnabled:NO];
		[glass setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		objc_setAssociatedObject(container, KEY("lgfix_kIslandGlassKey"), glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (pTrackGlass) pTrackGlass(glass, S("PillHUD"), container);
		vlog("island: glass created %.0fx%.0f", size.width, size.height);
	}
	CGFloat radius = [[container layer] cornerRadius];
	if (radius <= 0.0 || radius > MIN(size.width, size.height) * 0.5) radius = MIN(size.width, size.height) * 0.5;
	// The renderer draws a directional highlight on the outermost ring of the glass; at the island's size it
	// shows as a dotted line at the top left. The glass is made a little larger than the island and clipped
	// to the island's shape by a wrapper view, which cuts that ring off.
	CGFloat outset = access(CTLDIR "/no-island-outset", F_OK) != 0 ? 4.0 : 0.0;
	UIView *clip = objc_getAssociatedObject(container, KEY("lgfix_islandClip"));
	if (!clip) {
		clip = [[UIView alloc] initWithFrame:frame];
		[clip setUserInteractionEnabled:NO];
		[clip setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		objc_setAssociatedObject(container, KEY("lgfix_islandClip"), clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if ([clip superview] != container) [container insertSubview:clip atIndex:0];
	if (!CGRectEqualToRect([clip frame], frame)) [clip setFrame:frame];
	setContinuousCorners([clip layer], radius);
	[[clip layer] setMasksToBounds:YES];
	if ([glass superview] != clip) [clip addSubview:glass];
	CGRect glassFrame = CGRectInset(frame, -outset, -outset);
	CGSize oldSize = [glass bounds].size;
	BOOL resized = fabs(oldSize.width - glassFrame.size.width) > 0.5 || fabs(oldSize.height - glassFrame.size.height) > 0.5;
	[glass setHidden:NO];
	if (resized) [glass setFrame:glassFrame];
	setContinuousCorners([glass layer], radius + outset);
	[[glass layer] setMasksToBounds:YES];
	if (resized && [glass respondsToSelector:@selector(applyFilters)])
		((void (*)(id, SEL))objc_msgSend)(glass, @selector(applyFilters));
	// The highlight ring is up to 2.5 capture pixels wide. At the stock capture scale for this size (about 0.3
	// with Global.Quality 0.1) that is 8 pt of coarse dots, more than the outset cuts off; at scale 1 it is
	// 2.5 pt and falls entirely into the clipped part.
	if (access(CTLDIR "/no-island-scale", F_OK) != 0) {
		@try {
			id current = [[glass layer] valueForKey:S("scale")];
			if (![current respondsToSelector:@selector(doubleValue)] || fabs([current doubleValue] - 1.0) > 0.01)
				[[glass layer] setValue:[NSNumber numberWithDouble:1.0] forKey:S("scale")];
		} @catch (id e) {}
	}
	// The glass draws a specular rim, strongest at the top left: on the small island it reads as a stray
	// line. Off unless DynamicIsland.SpecularEnabled is set.
	SEL overrideSel = sel_registerName("lgSpecularEnabledOverride"), setOverrideSel = sel_registerName("setLgSpecularEnabledOverride:");
	if ([glass respondsToSelector:overrideSel] && [glass respondsToSelector:setOverrideSel]) {
		if (!pPrefBool) pPrefBool = dlsym(RTLD_DEFAULT, "LG_prefBool");
		BOOL specular = pPrefBool ? pPrefBool(S("DynamicIsland.SpecularEnabled"), NO) : NO;
		id current = ((id (*)(id, SEL))objc_msgSend)(glass, overrideSel);
		if (!current || [current boolValue] != specular)
			((void (*)(id, SEL, id))objc_msgSend)(glass, setOverrideSel, [NSNumber numberWithBool:specular]);
		// The glass also keeps an edge line (shape layer) and the specular gradient as sublayers; the edge
		// line is shown regardless of the override.
		if (!specular) {
			Class shapeClass = objc_getClass("CAShapeLayer"), gradientClass = objc_getClass("CAGradientLayer");
			for (CALayer *sub in [[glass layer] sublayers])
				if (([sub isKindOfClass:shapeClass] || [sub isKindOfClass:gradientClass]) && ![sub isHidden]) [sub setHidden:YES];
		}
	}
	islandSetFillsHidden(window, YES);
	islandSetContainerFillsHidden(container, YES);
	islandSetElementAdapted(container, YES);
	islandSetCutoutClear(islandClearCutoutWanted());
	// The element's views are filled in after this layout without another one: look again a few times
	if (!objc_getAssociatedObject(container, KEY("lgfix_islandRecheck"))) {
		objc_setAssociatedObject(container, KEY("lgfix_islandRecheck"), container, OBJC_ASSOCIATION_ASSIGN);
		__weak UIView *weakContainer = container;
		static const int delays[5] = { 30, 80, 160, 320, 700 };
		for (int i = 0; i < 5; i++) {
			BOOL last = i == 4;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
				UIView *strong = weakContainer;
				if (!strong) return;
				if (last) objc_setAssociatedObject(strong, KEY("lgfix_islandRecheck"), nil, OBJC_ASSOCIATION_ASSIGN);
				UIView *current = objc_getAssociatedObject(strong, KEY("lgfix_kIslandGlassKey"));
				@try {
					if (current && ![current isHidden]) {
						islandSetElementAdapted(strong, YES);
						islandSetContainerFillsHidden(strong, YES);
						if ([strong window]) islandSetFillsHidden([strong window], YES);
					}
				} @catch (id e) {}
			});
		}
	}

	UIColor *tintColor = islandTintColor();
	if (tintColor && !tint) {
		tint = [[UIView alloc] initWithFrame:frame];
		[tint setUserInteractionEnabled:NO];
		[tint setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		objc_setAssociatedObject(container, KEY("lgfix_islandTint"), tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	[tint setHidden:!tintColor];
	if (tintColor) {
		if ([tint superview] != container) [container insertSubview:tint aboveSubview:clip];
		[tint setFrame:frame];
		[tint setBackgroundColor:tintColor];
		setContinuousCorners([tint layer], radius);
		[[tint layer] setMasksToBounds:YES];
	}
}

#pragma mark - helpers

static const char *cname(id obj) {
	return obj ? class_getName(object_getClass(obj)) : "nil";
}

static NSArray *allWindows(void) {
	Class win = objc_getClass("UIWindow");
	SEL sel = sel_registerName("allWindowsIncludingInternalWindows:onlyVisibleWindows:");
	if (!win || !class_getClassMethod(win, sel)) return nil;
	return ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)((id)win, sel, YES, YES);
}

#pragma mark - cover sheet: icons behind the glass

static dispatch_source_t sCoverTimer;

// iOS 17 hides SBIconContentView while the cover sheet is up and only shows it when the unlock finishes,
// so the cover sheet glass has nothing but wallpaper behind it. Keep the icons visible while the device is
// authenticated (never while locked). Off unless CTLDIR/icons-behind exists: the original tweak leaves the
// icons to the system, and on 17.0.3 this made them (and the widgets with them) blink out for a moment when
// the notification centre came down. CTLDIR/no-icons-behind still switches it off.
static BOOL iconsBehindEnabled(void) {
	return access(CTLDIR "/icons-behind", F_OK) == 0 && access(CTLDIR "/no-icons-behind", F_OK) != 0;
}

static IMP sIconSetHiddenOrig;
static __weak UIView *sIconContentView;

static BOOL deviceAuthenticated(void) {
	@try {
		SEL getter = sel_registerName("authenticationController"), auth = sel_registerName("isAuthenticated");
		id app = [UIApplication sharedApplication];
		id controller = [app respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(app, getter) : nil;
		return [controller respondsToSelector:auth] && ((BOOL (*)(id, SEL))objc_msgSend)(controller, auth);
	} @catch (id e) {}
	return NO;
}

static BOOL coverSheetVisible(void) {
	@try {
		Class cls = objc_getClass("SBCoverSheetPresentationManager");
		SEL shared = sel_registerName("sharedInstance"), visible = sel_registerName("isVisible");
		if (!cls || !class_getClassMethod(cls, shared)) return NO;
		id manager = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
		return [manager respondsToSelector:visible] && ((BOOL (*)(id, SEL))objc_msgSend)(manager, visible);
	} @catch (id e) {}
	return NO;
}

// Only while the cover sheet is on screen: other reasons the system hides the icons are left alone
static BOOL iconsBehindWanted(void) {
	return iconsBehindEnabled() && resolveLiquidAss() && pHostEnabled(S("CoverSheet")) &&
	       coverSheetVisible() && deviceAuthenticated();
}

static void iconContentCallOrig(id self, BOOL hidden) {
	SEL sel = @selector(setHidden:);
	if (sIconSetHiddenOrig) {
		((void (*)(id, SEL, BOOL))sIconSetHiddenOrig)(self, sel, hidden);
	} else {
		struct objc_super sup = { self, class_getSuperclass(objc_getClass("SBIconContentView")) };
		((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, sel, hidden);
	}
}

static void coverStartTimer(void);

static void iconContentSetHidden(id self, SEL _cmd, BOOL hidden) {
	sIconContentView = self;
	if (hidden) {
		coverStartTimer();
		BOOL keep = NO;
		@try { keep = iconsBehindWanted(); } @catch (id e) {}
		objc_setAssociatedObject(self, KEY("lgfix_iconsWantHidden"), self, OBJC_ASSOCIATION_ASSIGN);
		if (keep) hidden = NO;
	} else {
		objc_setAssociatedObject(self, KEY("lgfix_iconsWantHidden"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
	iconContentCallOrig(self, hidden);
}

// Follows lock state: the system asked for hidden icons -> hidden while locked, visible while authenticated
static void coverStopTimer(void) {
	if (!sCoverTimer) return;
	dispatch_source_cancel(sCoverTimer);
	sCoverTimer = nil;
}

// Runs from the timer. Stops it once there is nothing to follow (the icons are not hidden by the system).
static void iconContentSync(void) {
	UIView *view = sIconContentView;
	if (!view) {
		Class cls = objc_getClass("SBIconContentView");
		if (!cls) return;
		for (UIWindow *window in allWindows()) {
			if (!strstr(cname(window), "HomeScreen")) continue;
			sIconContentView = view = findView(window, cls, 6);
			if (view) break;
		}
		if (!view) { coverStopTimer(); return; }
		// Found hidden before the hook saw a call: the system wants it hidden
		if ([view isHidden]) objc_setAssociatedObject(view, KEY("lgfix_iconsWantHidden"), view, OBJC_ASSOCIATION_ASSIGN);
	}
	if (!objc_getAssociatedObject(view, KEY("lgfix_iconsWantHidden"))) { coverStopTimer(); return; }
	BOOL shouldHide = !iconsBehindWanted();
	if ([view isHidden] != shouldHide) iconContentCallOrig(view, shouldHide);
}

static void iconContentInstall(void) {
	if (getenv("LGFIX_ICONHOOK")) return;   // an earlier build owns the hook
	Class cls = objc_getClass("SBIconContentView");
	if (!cls) return;
	SEL sel = @selector(setHidden:);
	if (!class_addMethod(cls, sel, (IMP)iconContentSetHidden, "v@:B")) {
		unsigned int count = 0;
		Method *methods = class_copyMethodList(cls, &count);
		for (unsigned int m = 0; m < count; m++)
			if (method_getName(methods[m]) == sel)
				sIconSetHiddenOrig = method_setImplementation(methods[m], (IMP)iconContentSetHidden);
		free(methods);
	}
	setenv("LGFIX_ICONHOOK", BUILD_TAG, 1);
	flog("icons: setHidden hook installed own=%d", sIconSetHiddenOrig != NULL);
}

// The timer follows the lock state while the system keeps the icons hidden (cover sheet up); the setHidden:
// hook starts it, iconContentSync stops it.
static void coverStartTimer(void) {
	if (sCoverTimer) return;
	const char *owner = getenv("LGFIX_ICONHOOK");
	if (!owner || strcmp(owner, BUILD_TAG)) return;
	sCoverTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(sCoverTimer, DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(sCoverTimer, ^{
		@try { iconContentSync(); } @catch (id e) {}
	});
	dispatch_resume(sCoverTimer);
}

// Nothing is hooked and no timer runs unless the feature is switched on (CTLDIR/icons-behind, read at start)
static void coverStartPoll(void) {
	if (!iconsBehindEnabled()) return;
	iconContentInstall();
	coverStartTimer();   // once, for icons that were already hidden before the hook
}

// For the private test host
static int sTestHits;
static void testHandler1(id view) { sTestHits += 1; }
static void testHandler2(id view) { sTestHits += 10; }
int lgfix_selftest(const char *path) {
	@autoreleasepool {
		UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 300)];
		UIView *child = [[UISlider alloc] initWithFrame:CGRectMake(1, 2, 50, 20)];
		[[child layer] setCornerRadius:7];
		[child setBackgroundColor:[UIColor redColor]];
		[root addSubview:child];
		FILE *f = fopen(path, "w");
		if (!f) return -1;
		fprintf(f, "# selftest windows=%p\n", (__bridge void *)allWindows());

		// hook plumbing: a class with its own layoutSubviews (UISlider) and one without (UIStackView subclass)
		lgfix_register("t1", testHandler1);
		lgfix_register("t2", testHandler2);
		fprintf(f, "# registered\n"); fflush(f);
		Class sub = objc_allocateClassPair([UIView class], "LGFixSelfTestView", 0);
		objc_registerClassPair(sub);
		int h1 = lgfix_hook_layout("UISlider", "t1");
		int h2 = lgfix_hook_layout("LGFixSelfTestView", "t2");
		fprintf(f, "# hooked %d %d\n", h1, h2); fflush(f);
		[child setNeedsLayout];
		[child layoutIfNeeded];
		UIView *plain = [[sub alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
		[plain setNeedsLayout];
		[plain layoutIfNeeded];
		fprintf(f, "# hooks h1=%d h2=%d hits=%d (want 11)\n", h1, h2, sTestHits); fflush(f);

		// volume handler against a stand-in object without liquidass loaded: must be a no-op
		volumeUpdate(child);
		fprintf(f, "# volumeUpdate without liquidass ok, resolve=%d\n", resolveLiquidAss());
		// color matrix filter: the value must survive a round trip through the filter
		@try {
			id filter = blackKeyFilter();
			NSValue *back = [filter valueForKey:S("inputColorMatrix")];
			float m[20] = { 0 };
			if (back && !strcmp([back objCType], "{CAColorMatrix=ffffffffffffffffffff}")) [back getValue:m];
			fprintf(f, "# blackKey filter=%s type=%s m11=%.2f m42=%.4f (want 1.00 1.0000)\n", cname(filter),
			        back ? [back objCType] : "-", m[0], m[16]);
		} @catch (id e) { fprintf(f, "# blackKey threw\n"); }
		// island audio wave: the real view in its island variant, switched to the clear variant and back
		@try {
			dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
			Class waveClass = objc_getClass("MRUWaveformView");
			SEL initSel = sel_registerName("initWithFrame:context:");
			UIView *wave = waveClass && [waveClass instancesRespondToSelector:initSel]
				? ((id (*)(id, SEL, CGRect, unsigned long long))objc_msgSend)([waveClass alloc], initSel, CGRectMake(0, 0, 40, 24), 0ULL) : nil;
			UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
			if (wave) [holder addSubview:wave];
			[wave layoutIfNeeded];
			CALayer *bars = [(UIView *)ivarObject(wave, "_barsView") layer];
			CALayer *bar = [[bars sublayers] firstObject];
			if (wave) islandWaveUpdate(wave);
			int before = layerOpaqueBlack(bars) && ![bars compositingFilter] && [bar compositingFilter] && [sIslandWaves containsObject:wave];
			if (waveClass) islandWaveformWalk(holder, waveClass, YES, 0);
			[wave setNeedsLayout];
			[wave layoutIfNeeded];
			if (waveClass) islandWaveformWalk(holder, waveClass, YES, 0);
			CALayer *color = [[[bars superlayer] sublayers] firstObject];
			int cleared = ![bars backgroundColor] && ![bars compositingFilter] && ![bar compositingFilter] && color != bars && [color mask];
			if (waveClass) islandWaveformWalk(holder, waveClass, NO, 0);
			int restored = layerOpaqueBlack(bars) && ![bars compositingFilter] && [[bar compositingFilter] isEqual:S("destOut")] && ![color mask];
			fprintf(f, "# wave view=%d bars=%lu black variant=%d cleared=%d restored=%d (want 1 6 1 1 1)\n", wave != nil,
			        (unsigned long)[[bars sublayers] count], before, cleared, restored);
		} @catch (id e) { fprintf(f, "# wave threw\n"); }
		fclose(f);
		return 200 + sTestHits;
	}
}

// For the private test host with the original loaded: the radius lock on a whole-module slider's material
int lgfix_cctest(const char *path) {
	@autoreleasepool {
		FILE *f = fopen(path, "w");
		if (!f) return -1;
		Class containerClass = objc_getClass("CCUIContentModuleContentContainerView");
		Class sliderClass = objc_getClass("CCUIContinuousSliderView"), materialClass = objc_getClass("MTMaterialView");
		fprintf(f, "# classes %d %d %d original=%d\n", containerClass != nil, sliderClass != nil, materialClass != nil,
		        dlsym(RTLD_DEFAULT, "LG_prefBool") != NULL); fflush(f);
		if (!containerClass || !sliderClass || !materialClass) { fclose(f); return -2; }
		UIView *container = [[containerClass alloc] initWithFrame:CGRectMake(0, 0, 150, 400)];
		UIView *material = [[materialClass alloc] initWithFrame:CGRectMake(0, 0, 150, 400)];
		UIView *slider = [[sliderClass alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
		[container addSubview:material];
		[container addSubview:slider];
		fprintf(f, "# built\n"); fflush(f);
		[slider layoutSubviews];
		CGFloat a = [[material layer] cornerRadius];
		[[material layer] setCornerRadius:10];
		CGFloat b = [[material layer] cornerRadius];
		fprintf(f, "# original rounded the material to %.1f, after setting 10: %.1f (locked when unchanged)\n", a, b); fflush(f);
		[slider setFrame:CGRectMake(0, 0, 150, 400)];
		ccContainerPillUpdate(container);
		CGFloat c = [[material layer] cornerRadius];
		[[material layer] setCornerRadius:20];
		CGFloat d = [[material layer] cornerRadius];
		fprintf(f, "# pill: %.1f, after setting 20: %.1f (want 75 75) key=%d\n", c, d, sDesiredRadiusKey != NULL); fflush(f);
		[container setFrame:CGRectMake(0, 0, 70, 70)];
		ccContainerPillUpdate(container);
		CGFloat e = [[material layer] cornerRadius];
		fprintf(f, "# small again: %.1f (want %.1f)\n", e, b);
		fclose(f);
		return (fabs(c - 75) < 0.5 && fabs(d - 75) < 0.5 && fabs(e - b) < 0.5) ? 1 : 0;
	}
}

#pragma mark - dev loader and constructor

// Timers and notifications of a build that was taken over stay registered; only the newest one acts
static BOOL isNewestBuild(void) {
	const char *newest = getenv("LGFIX_NEWEST");
	return newest && !strcmp(newest, BUILD_TAG);
}

// dlopen the dylib named in CTLDIR/next (root-owned), so new builds can be tried without a respring
static void loadNext(void) {
	char path[512] = "";
	FILE *f = fopen(CTLDIR "/next", "r");
	if (!f) return;
	if (!fgets(path, sizeof(path), f)) path[0] = 0;
	fclose(f);
	path[strcspn(path, "\r\n")] = 0;
	if (!path[0]) return;
	void *handle = dlopen(path, RTLD_NOW);
	flog("load %s -> %p %s", path, handle, handle ? "ok" : dlerror());
}

static void registerHandlers(void (*reg)(const char *, LGFixHandler)) {
	reg("volume", volumeUpdate);
	reg("cc.container", ccContainerUpdate);
	reg("cc.slider", ccSliderUpdate);
	reg("cc.toggle", ccToggleUpdate);
	reg("cc.mediastyle", ccMediaStyleUpdate);
	reg("island", islandUpdate);
	reg("island.element", islandElementUpdate);
	reg("island.wave", islandWaveUpdate);
	reg("widget.fill", widgetFillUpdate);
	reg("widget.list", widgetListUpdate);
}

static void installHooks(int (*hook)(const char *, const char *), const char *why) {
	flog("%s: island=%d element=%d wave=%d", why, hook("SBSystemApertureContainerView", "island"),
	     hook("SAUIElementView", "island.element"), hook("MRUWaveformView", "island.wave"));
	flog("%s: widgetFill=%d list=%d", why, hook("CHUISWidgetHostViewControllerView", "widget.fill"),
	     hook("SBIconListView", "widget.list"));
	@try {
		Class widgetClass = objc_getClass("CHUISWidgetHostViewControllerView");
		if (widgetClass)
			for (UIWindow *window in allWindows())
				if (!strcmp(cname(window), "SBHomeScreenWindow")) widgetFillWalk(window, widgetClass, 0);
	} @catch (id e) {}
	flog("%s: hooks volume=%d container=%d slider=%d liquidass=%d", why,
	     hook("SBElasticSliderView", "volume"),
	     hook("CCUIContentModuleContentContainerView", "cc.container"),
	     hook("CCUIContinuousSliderView", "cc.slider"),
	     resolveLiquidAss());
	flog("%s: toggle=%d mediastyle=%d", why, hook("CCUIButtonModuleView", "cc.toggle"),
	     hook("MRUControlCenterView", "cc.mediastyle"));
	@try {
		Class mediaClass = objc_getClass("MRUControlCenterView");
		NSArray *windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)((id)objc_getClass("UIWindow"),
		    sel_registerName("allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, NO);
		if (mediaClass)
			for (UIWindow *window in windows)
				if (!strncmp(cname(window), "SBControlCenter", 15)) ccMediaStyleUpdate(findView(window, mediaClass, 40));
	} @catch (id e) {}
}

#pragma mark - widgets drawn smaller than their slot (widget page left of the home screen)

// iOS 17 renders the widgets of the widget page in a way the stock background removal does not catch (Calendar
// kept its whole background, Screen Time half of it) and they covered the glass behind them. Ask the system
// itself to leave the background out: for every widget on the widget page, and elsewhere for those that may
// also appear on the lock screen. Kill switch: CTLDIR/no-widget-background
static BOOL widgetIsOnWidgetPage(UIView *content) {
	Class listClass = objc_getClass("SBIconListView");
	int depth = 0;
	for (UIView *v = [content superview]; v && depth < 24; v = [v superview], depth++)
		if (listClass && [v isKindOfClass:listClass]) return !strcmp(cname([v superview]), "UIStackView");
	return NO;
}

static void widgetBackgroundUpdate(UIView *content) {
	id vc = nil;
	@try {
		vc = ((id (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("UIViewController"), sel_registerName("viewControllerForView:"), content);
	} @catch (id e) {}
	SEL getSel = sel_registerName("backgroundViewPolicy"), setSel = sel_registerName("setBackgroundViewPolicy:");
	SEL secureSel = sel_registerName("canAppearInSecureEnvironment");
	if (!vc || ![vc respondsToSelector:getSel] || ![vc respondsToSelector:setSel] || ![vc respondsToSelector:secureSel]) return;
	const void *key = KEY("lgfix_widgetBackground");
	BOOL mine = objc_getAssociatedObject(vc, key) != nil;
	BOOL secure = ((BOOL (*)(id, SEL))objc_msgSend)(vc, secureSel);
	BOOL onPage = widgetIsOnWidgetPage(content);
	BOOL want = access(CTLDIR "/no-widget-background", F_OK) != 0 && resolveLiquidAss() && pHostEnabled(S("Widgets")) &&
	            (secure || onPage);
	unsigned long long policy = ((unsigned long long (*)(id, SEL))objc_msgSend)(vc, getSel);
	// 2 = background removed without the widget changing its layout, 0 = the default
	unsigned long long target = want ? 2 : 0;
	if (policy == target || (!want && !mine)) return;
	if (want && policy != 0 && !mine) return;   // someone else chose a policy
	objc_setAssociatedObject(vc, key, want ? vc : nil, OBJC_ASSOCIATION_ASSIGN);
	const char *bundle = "?";
	@try {
		id widget = [vc respondsToSelector:sel_registerName("widget")] ? ((id (*)(id, SEL))objc_msgSend)(vc, sel_registerName("widget")) : nil;
		id name = [widget respondsToSelector:sel_registerName("extensionBundleIdentifier")]
			? ((id (*)(id, SEL))objc_msgSend)(widget, sel_registerName("extensionBundleIdentifier")) : nil;
		if ([name isKindOfClass:[NSString class]]) bundle = [(NSString *)name UTF8String];
	} @catch (id e) {}
	char label[160];
	snprintf(label, sizeof(label), "%s page=%d lock=%d", bundle ? bundle : "?", onPage, secure);
	NSString *labelString = S(label);
	__weak id weakController = vc;
	dispatch_async(dispatch_get_main_queue(), ^{
		id controller = weakController;
		if (!controller) return;
		@try {
			((void (*)(id, SEL, unsigned long long))objc_msgSend)(controller, setSel, target);
			vlog("widget: background policy -> %llu (%s)", target, [labelString UTF8String]);
		} @catch (id e) { flog("widget: background policy threw"); }
	});
}

// With a grid tweak the widget content is laid out at the home screen's reduced size (315x147) while the widget
// page keeps full-size slots (364x170): the content sat in the top left corner of its glass. Scale it to fill.
static void widgetFillUpdate(id object) {
	UIView *content = object;
	@try { widgetBackgroundUpdate(content); } @catch (id e) {}
	UIView *slot = [content superview];
	if (!slot) return;
	const void *key = KEY("lgfix_widgetFill");
	CGSize own = [content bounds].size, outer = [slot bounds].size;
	CGFloat scale = own.width > 1.0 ? outer.width / own.width : 1.0;
	BOOL fill = access(CTLDIR "/no-widget-fill", F_OK) != 0 && own.height > 1.0 && scale > 1.02 && scale < 1.5 &&
	            fabs(outer.height / own.height - scale) < 0.03 && CGAffineTransformIsIdentity([content transform]) &&
	            fabs([content frame].origin.x) < 0.5 && fabs([content frame].origin.y) < 0.5;
	CALayer *layer = [slot layer];
	if (fill) {
		// sublayerTransform works around the slot's centre; move it so the top left corner stays in place
		CATransform3D t = CATransform3DMakeScale(scale, scale, 1.0);
		t.m41 = (scale - 1.0) * outer.width * 0.5;
		t.m42 = (scale - 1.0) * outer.height * 0.5;
		if (!CATransform3DEqualToTransform([layer sublayerTransform], t)) {
			[layer setSublayerTransform:t];
			vlog("widget: content %.0fx%.0f scaled %.3f to fill %.0fx%.0f", own.width, own.height, scale, outer.width, outer.height);
		}
		objc_setAssociatedObject(slot, key, slot, OBJC_ASSOCIATION_ASSIGN);
	} else if (objc_getAssociatedObject(slot, key)) {
		[layer setSublayerTransform:CATransform3DIdentity];
		objc_setAssociatedObject(slot, key, nil, OBJC_ASSOCIATION_ASSIGN);
	}
}

static void widgetFillWalk(UIView *view, Class cls, int depth) {
	if (!view || depth > 40) return;
	if ([view isKindOfClass:cls]) { widgetFillUpdate(view); return; }
	for (UIView *sub in [view subviews]) widgetFillWalk(sub, cls, depth + 1);
}

// The widget page puts a material behind its whole widget list (and, one level up, behind the page). The glass
// samples what is behind it, so that material shows as a soft dark veil around the widgets. That is part of the
// look; hiding it is opt-in (CTLDIR/clear-widget-page-material) and done with an empty mask, not alpha: the
// system writes alpha back, and the one build that fought over it had backboardd killed for memory.
static BOOL widgetPageMaterialAllowed(void) {
	return access(CTLDIR "/clear-widget-page-material", F_OK) == 0;
}

static void widgetPageSetMaterialMasked(UIView *material, BOOL masked, const char *what) {
	const void *key = KEY("lgfix_widgetPageMaterial"), *countKey = KEY("lgfix_widgetPageMaterialCount");
	BOOL mine = objc_getAssociatedObject(material, key) != nil;
	CALayer *layer = [material layer];
	if (masked) {
		if ([layer mask]) return;
		// someone removing the mask again must not turn into a per-frame fight
		long count = [objc_getAssociatedObject(material, countKey) longValue];
		if (count >= 20) return;
		objc_setAssociatedObject(material, countKey, [NSNumber numberWithLong:count + 1], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[layer setMask:[CALayer layer]];
		if (!mine) vlog("widget page: %s material masked %.0fx%.0f", what, [material bounds].size.width, [material bounds].size.height);
		objc_setAssociatedObject(material, key, material, OBJC_ASSOCIATION_ASSIGN);
	} else if (mine) {
		[layer setMask:nil];
		objc_setAssociatedObject(material, key, nil, OBJC_ASSOCIATION_ASSIGN);
	}
}

static void widgetPageMaterialUpdate(UIView *list) {
	if (strcmp(cname([list superview]), "UIStackView")) return;   // only the widget page's list
	Class materialClass = objc_getClass("MTMaterialView");
	if (!materialClass) return;
	BOOL clear = resolveLiquidAss() && pHostEnabled(S("Widgets")) && widgetPageMaterialAllowed();
	for (UIView *sub in [list subviews])
		if ([sub isKindOfClass:materialClass]) widgetPageSetMaterialMasked(sub, clear, "list");
	// Optional second step for testing: the page's own full-screen material (CTLDIR/widget-page-clear-backdrop)
	BOOL clearPage = clear && access(CTLDIR "/widget-page-clear-backdrop", F_OK) == 0;
	int depth = 0;
	for (UIView *v = [list superview]; v && depth < 8; v = [v superview], depth++) {
		if (strcmp(cname(v), "SBFFocusIsolationView")) continue;
		for (UIView *sub in [v subviews])
			if ([sub isKindOfClass:materialClass]) widgetPageSetMaterialMasked(sub, clearPage, "page");
		break;
	}
}

// Widget views that come back from the recycling pool are not laid out again; catch them when their page lays out
static void widgetListUpdate(id object) {
	UIView *list = object;
	@try { widgetPageMaterialUpdate(list); } @catch (id e) {}
	const void *key = KEY("lgfix_widgetListPending");
	if (objc_getAssociatedObject(list, key)) return;
	objc_setAssociatedObject(list, key, list, OBJC_ASSOCIATION_ASSIGN);
	__weak UIView *weakList = list;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		UIView *strongList = weakList;
		if (!strongList) return;
		objc_setAssociatedObject(strongList, key, nil, OBJC_ASSOCIATION_ASSIGN);
		Class widgetClass = objc_getClass("CHUISWidgetHostViewControllerView");
		@try {
			if (widgetClass) widgetFillWalk(strongList, widgetClass, 0);
		} @catch (id e) {}
	});
}

// The stock tweak tints some surfaces black in dark mode (widgets and context menus 30 %, banners 50 %, ...).
// Make clear the default once, for every key the user has not set. Kill switch: CTLDIR/keep-dark-tints
static void darkTintDefaults(void) {
	if (access(CTLDIR "/keep-dark-tints", F_OK) == 0) return;
	const char *hosts[] = { "Widgets", "ContextMenu", "Alerts", "Banner", "Spotlight", "Passcode", "Keyboard" };
	CFStringRef domain = CFStringCreateWithCString(NULL, "dylv.liquidassprefs", kCFStringEncodingUTF8);
	CFStringRef marker = CFStringCreateWithCString(NULL, "LGFix.DarkTintDefaultsApplied", kCFStringEncodingUTF8);
	CFPropertyListRef done = CFPreferencesCopyAppValue(marker, domain);
	if (!done) {
		CFStringRef clear = CFStringCreateWithCString(NULL, "#00000000", kCFStringEncodingUTF8);
		int changed = 0;
		for (unsigned i = 0; i < sizeof(hosts) / sizeof(hosts[0]); i++) {
			char name[64];
			snprintf(name, sizeof(name), "%s.DarkTintColor", hosts[i]);
			CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
			CFPropertyListRef chosen = CFPreferencesCopyAppValue(key, domain);
			if (chosen) CFRelease(chosen);
			else { CFPreferencesSetAppValue(key, clear, domain); changed++; }
			CFRelease(key);
		}
		CFRelease(clear);
		CFPreferencesSetAppValue(marker, kCFBooleanTrue, domain);
		CFPreferencesAppSynchronize(domain);
		flog("dark tint defaults: %d keys set to clear", changed);
		// the renderer reads the plist file; give cfprefsd time to write it
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			notify_post("dylv.liquidassprefs/Reload");
		});
	} else CFRelease(done);
	CFRelease(marker);

	// The stock list of widgets whose own background is removed lacks Stocks: with the dark tint gone it was the
	// only widget left with a (black) background. Add it once, unless the user edited the list.
	marker = CFStringCreateWithCString(NULL, "LGFix.WidgetListDefaultApplied", kCFStringEncodingUTF8);
	done = CFPreferencesCopyAppValue(marker, domain);
	if (!done) {
		CFStringRef key = CFStringCreateWithCString(NULL, "RWB.ThirdPartyBundleIDs", kCFStringEncodingUTF8);
		CFPropertyListRef chosen = CFPreferencesCopyAppValue(key, domain);
		if (chosen) CFRelease(chosen);
		else {
			CFStringRef list = CFStringCreateWithCString(NULL,
				"com.apple.mobiletimer.WorldClockWidget\ncom.apple.mobilecal.CalendarWidgetExtension\n"
				"com.apple.mobilemail.MailWidgetExtension\n"
				"com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension\n"
				"com.apple.reminders.WidgetExtension\ncom.apple.weather.widget\ncom.apple.Fitness.FitnessWidget\n"
				"com.apple.Passbook.PassbookWidgets\ncom.apple.Health.Sleep.SleepWidgetExtension\n"
				"com.apple.tips.TipsSwift\ncom.apple.Music.MusicWidgets\ncom.apple.gamecenter.widgets.extension\n"
				"com.apple.tv.TVWidgetExtension\ncom.apple.news.widget\ncom.apple.Maps.GeneralMapsWidget\n"
				"com.apple.stocks.widget", kCFStringEncodingUTF8);
			CFPreferencesSetAppValue(key, list, domain);
			CFRelease(list);
			flog("widget list: default with Stocks written");
		}
		CFRelease(key);
		CFPreferencesSetAppValue(marker, kCFBooleanTrue, domain);
		CFPreferencesAppSynchronize(domain);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			notify_post("dylv.liquidassprefs/Reload");
		});
	} else CFRelease(done);
	CFRelease(marker);

	// Batteries is not in the stock list either and kept its background on the widget page. Append it once.
	marker = CFStringCreateWithCString(NULL, "LGFix.WidgetListBatteriesApplied", kCFStringEncodingUTF8);
	done = CFPreferencesCopyAppValue(marker, domain);
	if (!done) {
		CFStringRef key = CFStringCreateWithCString(NULL, "RWB.ThirdPartyBundleIDs", kCFStringEncodingUTF8);
		CFStringRef batteries = CFStringCreateWithCString(NULL, "com.apple.Batteries.BatteriesAvocadoWidgetExtension", kCFStringEncodingUTF8);
		CFPropertyListRef chosen = CFPreferencesCopyAppValue(key, domain);
		if (chosen && CFGetTypeID(chosen) == CFStringGetTypeID() &&
		    CFStringFind((CFStringRef)chosen, batteries, 0).location == kCFNotFound) {
			CFMutableStringRef list = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)chosen);
			CFIndex length = CFStringGetLength(list);
			if (length > 0 && CFStringGetCharacterAtIndex(list, length - 1) != '\n') CFStringAppendCString(list, "\n", kCFStringEncodingUTF8);
			CFStringAppend(list, batteries);
			CFPreferencesSetAppValue(key, list, domain);
			CFRelease(list);
			flog("widget list: Batteries appended");
		}
		if (chosen) CFRelease(chosen);
		CFRelease(key); CFRelease(batteries);
		CFPreferencesSetAppValue(marker, kCFBooleanTrue, domain);
		CFPreferencesAppSynchronize(domain);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			notify_post("dylv.liquidassprefs/Reload");
		});
	} else CFRelease(done);
	CFRelease(domain); CFRelease(marker);
}

// Keyboard: iOS keeps the drawn keys in a system-wide image cache (Library/Caches/com.apple.keyboards) whose keys
// do not include the tweak's key radius or font, and the stock tweak never empties it: keys drawn before a
// settings change (or without the tweak) keep their old shape, so one keyboard shows a mix. Empty the cache whenever
// those settings differ from the ones it was last filled with. Kill switch: CTLDIR/keep-keyboard-cache
static void keyboardCacheSync(void) {
	if (access(CTLDIR "/keep-keyboard-cache", F_OK) == 0) return;
	const char *names[] = { "Global.Enabled", "Keyboard.Enabled", "Keyboard.KeyRadius", "Keyboard.CustomFont.Enabled" };
	CFStringRef domain = CFStringCreateWithCString(NULL, "dylv.liquidassprefs", kCFStringEncodingUTF8);
	CFPreferencesAppSynchronize(domain);
	char now[160] = "";
	for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
		CFPropertyListRef value = CFPreferencesCopyAppValue(key, domain);
		char part[40] = "-";
		double number = 0;
		if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) snprintf(part, sizeof(part), "%d", CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0);
		else if (value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number))
			snprintf(part, sizeof(part), "%.2f", number);
		if (value) CFRelease(value);
		CFRelease(key);
		strlcat(now, part, sizeof(now));
		strlcat(now, "|", sizeof(now));
	}
	CFRelease(domain);

	char before[160] = "";
	FILE *f = fopen(OUTDIR "/keyboard-cache-state", "r");
	if (f) {
		if (!fgets(before, sizeof(before), f)) before[0] = 0;
		fclose(f);
		before[strcspn(before, "\r\n")] = 0;
	}
	if (!strcmp(before, now)) return;

	Class cacheClass = objc_getClass("UIKeyboardCache");
	SEL shared = sel_registerName("sharedInstance"), purge = sel_registerName("purge");
	id cache = cacheClass && [cacheClass respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cacheClass, shared) : nil;
	BOOL purged = cache && [cache respondsToSelector:purge];
	if (purged) ((void (*)(id, SEL))objc_msgSend)(cache, purge);
	Class rendererClass = objc_getClass("UIKBRenderer");
	SEL clear = sel_registerName("clearInternalCaches");
	if (rendererClass && [rendererClass respondsToSelector:clear]) ((void (*)(id, SEL))objc_msgSend)(rendererClass, clear);
	flog("keyboard: settings %s -> %s, key image cache emptied=%d", before[0] ? before : "(none)", now, purged);
	if (!purged) return;
	f = fopen(OUTDIR "/keyboard-cache-state", "w");
	if (f) { fputs(now, f); fclose(f); }
}

static void keyboardCacheWatch(void) {
	static int token, generation;
	notify_register_dispatch("dylv.liquidassprefs/Reload", &token, dispatch_get_main_queue(), ^(int t) {
		if (!isNewestBuild()) return;
		// a slider sends many reloads while it is dragged: wait until they stop
		int mine = ++generation;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			if (mine != generation) return;
			@try { keyboardCacheSync(); } @catch (id e) {}
		});
	});
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!isNewestBuild()) return;
		@try { keyboardCacheSync(); } @catch (id e) {}
	});
}

static void registerRuntime(void) {
	dispatch_async(dispatch_get_main_queue(), ^{ coverStartPoll(); });
	static int prefsToken;
	notify_register_dispatch("dylv.liquidassprefs/Reload", &prefsToken, dispatch_get_main_queue(), ^(int t) {
		if (!isNewestBuild()) return;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			[sIslandContainer setNeedsLayout];
		});
	});
}

__attribute__((constructor)) static void lgfixInit(void) {
	if (getenv("LGFIX_SELFTEST")) return;
	if (access(CTLDIR "/disabled", F_OK) == 0) return;
	mkdir(OUTDIR, 0755);
	logSetup();
	// a preference default, not a hook: applies on every iOS version (once per process, by the first build)
	if (!dlsym(RTLD_DEFAULT, "lgfix_register") || dlsym(RTLD_DEFAULT, "lgfix_register") == (void *)lgfix_register)
		dispatch_async(dispatch_get_main_queue(), ^{ @try { darkTintDefaults(); } @catch (id e) {} });
	// a cache fix, not a hook: applies on every iOS version
	keyboardCacheWatch();
	if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 17) {
		// iOS 15 and 16: the stock hooks cover the volume HUD and there is no island or widget page to fix.
		// Only the Control Center fixes apply (kill switch CTLDIR/no-cc-slider).
		if (access(CTLDIR "/no-cc-slider", F_OK) == 0) return;
		sLegacyOS = YES;
		if (dlsym(RTLD_DEFAULT, "lgfix_register") != (void *)lgfix_register) return;
		setenv("LGFIX_NEWEST", BUILD_TAG, 1);
		lgfix_register("cc.container", ccContainerUpdate);
		lgfix_register("cc.slider", ccSliderUpdate);
		lgfix_register("cc.toggle", ccToggleUpdate);
		lgfix_register("cc.media", ccMediaUpdate);
		dispatch_async(dispatch_get_main_queue(), ^{
			flog("init (iOS < 17): hooks container=%d slider=%d",
			     lgfix_hook_layout("CCUIContentModuleContentContainerView", "cc.container"),
			     lgfix_hook_layout("CCUIContinuousSliderView", "cc.slider"));
			flog("init (iOS < 17): toggle=%d media=%d/%d", lgfix_hook_layout("CCUIButtonModuleView", "cc.toggle"),
			     lgfix_hook_layout("MRUControlCenterView", "cc.media"), lgfix_hook_layout("MRUNowPlayingView", "cc.media"));
		});
		return;
	}
	setenv("LGFIX_NEWEST", BUILD_TAG, 1);

	// A build that is already in the process owns hooks and notifications; just take its handlers over
	void (*firstRegister)(const char *, LGFixHandler) = dlsym(RTLD_DEFAULT, "lgfix_register");
	int (*firstHook)(const char *, const char *) = dlsym(RTLD_DEFAULT, "lgfix_hook_layout");
	BOOL first = !firstRegister || firstRegister == lgfix_register;
	if (!first) {
		registerHandlers(firstRegister);
		if (firstHook) dispatch_async(dispatch_get_main_queue(), ^{ installHooks(firstHook, "takeover"); });
		registerRuntime();
		return;
	}

	registerHandlers(lgfix_register);
	static int loadToken;
	notify_register_dispatch("dylv.liquidass.diag/load", &loadToken, dispatch_get_main_queue(), ^(int t) {
		loadNext();
	});
	dispatch_async(dispatch_get_main_queue(), ^{
		installHooks(lgfix_hook_layout, "init");
		registerRuntime();
	});
}
