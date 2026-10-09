// LiquidAssFixApps: add-on for the apps (every process that loads UIKit, like the original tweak).
// Runtime style like lgfix.m: no @"" literals, no @implementation, no CFSTR (arm64e, on-device toolchain).
//
// The original's floating tab bar moves the bar's buttons into the glass pill from inside
// -[UITabBarButton setFrame:] (LGTabBarRemapButtonFrame in Hooks/TabBar.x). The scale it uses is
// pill width / width of all buttons' stock frames seen so far. In the first layout after the glass exists
// the stock frames arrive one button at a time, so the first button is scaled as if it were alone (it gets
// the whole pill), the second as one of two, and so on: all titles end up on top of each other at the right
// end of the pill. Any later layout of the bar is right, because by then every stock frame is known. An app
// whose bar is laid out exactly once after it appears keeps the broken first result; seen in the App Store.
// Measured in a private process with a plain five-item UITabBar on iOS 17.3: first layout
// x = 20 / 220 / 284 / 316 / 335, all ending at 410; second layout five equal buttons.
//
// The fix: after a layout of a bar that carries the original's glass, when its buttons overlap, the bar is
// laid out once more. Nothing of the original is replaced or patched, and a bar without the glass is not
// touched.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-tabbar-fix
//
// Keyboard key shape: the original rounds the keys in -[UIKBRenderer renderBackgroundTraits:allowCaching:]
// (Hooks/Keyboard.x). Whether the keyboard glass is on it takes from the settings FILE (lgHostEnabled), but
// the radius it takes from the preferences system (LG_prefFloat "Keyboard.KeyRadius", fallback 10). A
// sandboxed app gets no values for the tweak's domain from the preferences system, so every such app draws
// the keys with radius 10 while SpringBoard and the unsandboxed apps draw them with the radius that was set.
// The system keeps the drawn key layers in one cache for all processes, without the radius in the name:
// whichever process draws a layer first decides its shape everywhere. Seen as keys of two shapes on one
// keyboard page (measured in the cache on iOS 17.3 with the radius set to 17.9: layers with about 17 pt next
// to layers with about 10 pt, all drawn after the setting was made).
//
// The fix: this library loads before the original, so its own replacement of that method is what the
// original calls as the stock implementation. In there the radius is set once more, to the value the
// original's own file reader gives (LGGlassPreferenceValue, the one lgHostEnabled uses), and put back after
// the draw. Only when the original is loaded, has replaced the method itself and has the keyboard switched
// on; a setting that is not in the file leaves the original's value alone.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-key-radius-fix
//
// Dynamic Island audio wave: what the island shows while music plays is not drawn by SpringBoard. It is a
// scene of the MediaRemoteUI app, and the island only hosts its layers. The wave in it (MRUWaveformView,
// MediaControls) comes in the variant made for the black island: an opaque black view over the color layers
// with the bars punched out of it (destOut). On the add-on's island glass that is a black box behind the
// wave. In MediaRemoteUI only, and only while the island glass is switched on, the wave is drawn plain:
// no backing, the bars as they are (white), the color layers left out. Nothing here blends with what lies
// behind the wave.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/keep-waveform-black
//
// Text loupe: the small lens that appears over the finger while the insertion point is dragged through text
// (_UITextLightLoupeView on iOS 17, _UITextMagnifiedLoupeView before). It is a clipped view holding a portal
// of the window (the enlarged text), a border and a shadow. The original has no code for it. Here a glass of
// the original (LGCreateRegisteredGlass, host "PrefsSlider": no blur, clear, 10 pt rim) is put INSIDE the
// loupe's clipped content view. The lens is a pane of frosted glass over what lies behind it, holding only the
// text being edited; it keeps the system's shape. The
// glass follows the lens and is cut by the lens's own clip. The system lets the lens hang over the top of the
// screen when the text is near the top (search field under the status bar); the renderer cannot draw glass there,
// so the lens is moved down until it is on screen. A lens still hanging over an edge keeps the frosted pane and
// the text but gets no glass of the original, only a thin light edge.
// Not host "PrefsSwitch": the renderer draws that one with the backdrop shrunk to 0.75 (the switch knob's
// look, LiquidAssBackboardd "backdropZoom"), which showed a small copy of the lens inside the lens with its
// edges smeared out to the rim. "TabBarSelection" (0.80) and "PrefsSegment" (0.70) shrink as well.
// On when the tweak is on; setting "TextLoupe.Enabled" = false in the tweak's settings file switches it off.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-loupe-glass

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define BUILD_TAG "t25"
#define MAX_BUTTONS 16
#define MAX_TRIES 3

#define KEY(name) ((const void *)sel_registerName(name))

static IMP origLayout;
static BOOL hookInstalled;
static BOOL logged;

#pragma mark - status log (one line per process, in the process's own temporary directory)

static void tlog(const char *fmt, ...) {
	char path[1024];
	const char *dir = getenv("TMPDIR");
	if (!dir || !dir[0]) dir = "/tmp";
	snprintf(path, sizeof(path), "%s/lgfix-tabbar.log", dir);
	struct stat st;
	if (stat(path, &st) == 0 && st.st_size > 8 * 1024) truncate(path, 0);
	FILE *f = fopen(path, "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	fprintf(f, "%.2f [" BUILD_TAG "] %s[%d] ", CFAbsoluteTimeGetCurrent(), getprogname(), getpid());
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	va_end(ap);
	fclose(f);
}

#pragma mark - tab bar

// YES when the bar carries the original's glass and two of its buttons lie on top of each other
static BOOL buttonsOverlap(UIView *bar) {
	Class glassClass = objc_getClass("LGLiveBackdropView");
	Class buttonClass = objc_getClass("UITabBarButton");
	if (!glassClass || !buttonClass) return NO;
	CGFloat minX[MAX_BUTTONS], maxX[MAX_BUTTONS];
	int count = 0;
	BOOL glass = NO;
	for (UIView *view in [bar subviews]) {
		if ([view isKindOfClass:glassClass]) glass = YES;
		if (![view isKindOfClass:buttonClass] || [view isHidden] || count == MAX_BUTTONS) continue;
		CGRect frame = [view frame];
		minX[count] = CGRectGetMinX(frame);
		maxX[count] = CGRectGetMaxX(frame);
		count++;
	}
	if (!glass || count < 2) return NO;
	for (int i = 0; i < count; i++) {
		for (int j = i + 1; j < count; j++) {
			CGFloat shared = MIN(maxX[i], maxX[j]) - MAX(minX[i], minX[j]);
			if (shared > 1.0) return YES;
		}
	}
	return NO;
}

static void tabBarLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origLayout)(self, _cmd);
	if (![self window]) return;
	const void *triesKey = KEY("lgtabfix_tries");
	if (!buttonsOverlap(self)) {
		if (objc_getAssociatedObject(self, triesKey)) objc_setAssociatedObject(self, triesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}
	int tries = [objc_getAssociatedObject(self, triesKey) intValue];
	if (tries >= MAX_TRIES) return;
	objc_setAssociatedObject(self, triesKey, [NSNumber numberWithInt:tries + 1], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if (!logged) {
		logged = YES;
		tlog("tab bar: buttons lay on top of each other after the first layout, laid out once more (logged once)");
	}
	// The stock frames of all buttons are known now: the next layout puts every button in its place
	[self setNeedsLayout];
	__weak UIView *weakBar = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIView *bar = weakBar;
		if (!bar || ![bar window] || !buttonsOverlap(bar)) return;
		[bar setNeedsLayout];
		[bar layoutIfNeeded];
	});
}

static void install(void) {
	if (hookInstalled || access(CTLDIR "/no-tabbar-fix", F_OK) == 0) return;
	Class cls = objc_getClass("UITabBar");
	SEL sel = sel_registerName("layoutSubviews");
	if (!cls) return;
	unsigned int count = 0;
	Method *own = class_copyMethodList(cls, &count);
	Method found = NULL;
	for (unsigned int i = 0; i < count; i++)
		if (method_getName(own[i]) == sel) found = own[i];
	free(own);
	if (!found) return;
	origLayout = method_setImplementation(found, (IMP)tabBarLayout);
	hookInstalled = YES;
}

#pragma mark - keyboard key radius

#define ORIGINAL_NAME "/liquidass.dylib"
#define MAX_KEY_RADIUS 23.0   // the original's own upper limit

static IMP origRenderBackground;
static BOOL keyHookInstalled;
static BOOL keyLogged;
static int originalState;      // 0 = not looked up yet, 1 = usable, -1 = not usable in this process
static id (*originalFileValue)(NSString *);
static BOOL (*originalHostEnabled)(NSString *);
static NSString *radiusName, *keyboardName;

// The original's image, NULL when it is not loaded
static const char *originalPath(void) {
	uint32_t count = _dyld_image_count();
	size_t tail = strlen(ORIGINAL_NAME);
	for (uint32_t i = 0; i < count; i++) {
		const char *name = _dyld_get_image_name(i);
		size_t length = name ? strlen(name) : 0;
		if (length >= tail && strcmp(name + length - tail, ORIGINAL_NAME) == 0) return name;
	}
	return NULL;
}

static BOOL impInOriginal(IMP imp) {
	void *address = ptrauth_strip((void *)imp, ptrauth_key_function_pointer);
	Dl_info info;
	if (!address || !dladdr(address, &info) || !info.dli_fname) return NO;
	size_t length = strlen(info.dli_fname), tail = strlen(ORIGINAL_NAME);
	return length >= tail && strcmp(info.dli_fname + length - tail, ORIGINAL_NAME) == 0;
}

// Looked up at the first key draw, when every tweak is loaded. Usable = the original is there, exports its
// file reader and has put its own replacement on the method (it does not in the processes it leaves alone).
static BOOL originalUsable(void) {
	if (originalState) return originalState > 0;
	originalState = -1;
	const char *path = originalPath();
	if (!path) return NO;
	void *handle = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
	if (!handle) return NO;
	originalFileValue = (id (*)(NSString *))dlsym(handle, "LGGlassPreferenceValue");
	originalHostEnabled = (BOOL (*)(NSString *))dlsym(handle, "lgHostEnabled");
	if (!originalFileValue || !originalHostEnabled) return NO;
	Class cls = objc_getClass("UIKBRenderer");
	Method method = cls ? class_getInstanceMethod(cls, sel_registerName("renderBackgroundTraits:allowCaching:")) : NULL;
	if (!method || !impInOriginal(method_getImplementation(method))) return NO;
	radiusName = [NSString stringWithUTF8String:"Keyboard.KeyRadius"];
	keyboardName = [NSString stringWithUTF8String:"Keyboard"];
	originalState = 1;
	return YES;
}

// The radius from the settings file, -1 = leave the draw alone
static CGFloat fileKeyRadius(void) {
	if (!originalUsable() || !originalHostEnabled(keyboardName)) return -1.0;
	id value = originalFileValue(radiusName);
	if (![value isKindOfClass:[NSNumber class]]) return -1.0;
	CGFloat radius = (CGFloat)[value doubleValue];
	if (!(radius >= 0.0)) radius = 0.0;
	return radius > MAX_KEY_RADIUS ? MAX_KEY_RADIUS : radius;
}

// Draws with the given radius on the traits' geometry and puts back what was there (radius < 0: plain call)
static void renderWithRadius(id self, SEL _cmd, id traits, BOOL allowCaching, IMP orig, CGFloat radius) {
	SEL geometrySel = sel_registerName("geometry"), getter = sel_registerName("roundRectRadius"), setter = sel_registerName("setRoundRectRadius:");
	id geometry = nil;
	if (radius >= 0.0 && traits && [traits respondsToSelector:geometrySel]) geometry = ((id (*)(id, SEL))objc_msgSend)(traits, geometrySel);
	if (!geometry || ![geometry respondsToSelector:getter] || ![geometry respondsToSelector:setter]) {
		((void (*)(id, SEL, id, BOOL))orig)(self, _cmd, traits, allowCaching);
		return;
	}
	CGFloat before = ((CGFloat (*)(id, SEL))objc_msgSend)(geometry, getter);
	((void (*)(id, SEL, CGFloat))objc_msgSend)(geometry, setter, radius);
	@try {
		((void (*)(id, SEL, id, BOOL))orig)(self, _cmd, traits, allowCaching);
	} @finally {
		((void (*)(id, SEL, CGFloat))objc_msgSend)(geometry, setter, before);
	}
	if (!keyLogged && fabs(before - radius) > 0.01) {
		keyLogged = YES;
		tlog("keyboard: keys drawn with radius %.2f from the settings file, the original had set %.2f (logged once)", radius, before);
	}
}

static void renderBackground(id self, SEL _cmd, id traits, BOOL allowCaching) {
	CGFloat radius = -1.0;
	@try { radius = fileKeyRadius(); } @catch (id e) {}
	renderWithRadius(self, _cmd, traits, allowCaching, origRenderBackground, radius);
}

static void installKeyRadius(void) {
	if (keyHookInstalled || access(CTLDIR "/no-key-radius-fix", F_OK) == 0) return;
	// Only as the first one on the method: after the original it would be the original's value that counts
	if (originalPath()) return;
	Class cls = objc_getClass("UIKBRenderer");
	SEL sel = sel_registerName("renderBackgroundTraits:allowCaching:");
	if (!cls) return;
	unsigned int count = 0;
	Method *own = class_copyMethodList(cls, &count);
	Method found = NULL;
	for (unsigned int i = 0; i < count; i++)
		if (method_getName(own[i]) == sel) found = own[i];
	free(own);
	if (!found) return;
	origRenderBackground = method_setImplementation(found, (IMP)renderBackground);
	keyHookInstalled = YES;
}

#pragma mark - Dynamic Island audio wave (MediaRemoteUI)

#define WAVE_PROCESS "MediaRemoteUI"
#define PREFS_FILE "/var/jb/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"

static IMP origWaveLayout;
static BOOL waveHookInstalled, waveLogged;
static int waveForce;               // self-test: 1 = glass on, -1 = glass off
static int waveGlass = -1;          // last answer, -1 = not asked yet
static CFAbsoluteTime waveAskedAt;
static int waveInstallTries;

static id ivarObject(id object, const char *name) {
	if (!object) return nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	if (!ivar) return nil;
	const char *type = ivar_getTypeEncoding(ivar);
	if (!type || type[0] != '@') return nil;
	return object_getIvar(object, ivar);
}

static BOOL layerOpaqueBlack(CALayer *layer) {
	CGColorRef bg = [layer backgroundColor];
	if (!bg || CGColorGetAlpha(bg) < 0.9) return NO;
	const CGFloat *c = CGColorGetComponents(bg);
	size_t n = CGColorGetNumberOfComponents(bg);
	for (size_t i = 0; i + 1 < n; i++)
		if (c[i] > 0.05) return NO;
	return YES;
}

// A switch from the settings file; missing = fallback
static BOOL fileSwitch(NSDictionary *prefs, const char *name, BOOL fallback) {
	id value = [prefs objectForKey:[NSString stringWithUTF8String:name]];
	return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

// Is the island drawn as glass? SpringBoard decides that; here only the same switches can be read (the
// tweak, the Pill HUD surface the island glass belongs to, the add-on's Dynamic Island switch). Asked again
// at most every two seconds. A settings file that cannot be read leaves the wave as it is.
static BOOL islandGlassOn(void) {
	if (waveForce) return waveForce > 0;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (waveGlass >= 0 && now - waveAskedAt < 2.0) return waveGlass;
	waveAskedAt = now;
	int answer = 0;
	const char *why = "settings file not readable";
	if (access(CTLDIR "/keep-waveform-black", F_OK) == 0 || access(CTLDIR "/disabled", F_OK) == 0) {
		why = "switched off by file";
	} else {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:PREFS_FILE]];
		if (prefs) {
			answer = fileSwitch(prefs, "Global.Enabled", YES) && fileSwitch(prefs, "PillHUD.Enabled", NO)
			      && fileSwitch(prefs, "DynamicIsland.Enabled", YES);
			why = answer ? "island glass on" : "island glass off in the settings";
		}
	}
	if (answer != waveGlass) tlog("audio wave: %s", why);
	waveGlass = answer;
	return answer;
}

static void waveSetClear(UIView *wave, BOOL clear) {
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
		// the color layers under the bars view (a blurred color field and a gray multiply layer): left out
		// with an empty mask, the view animates their opacity itself
		for (CALayer *sibling in [[layer superlayer] sublayers]) {
			if (sibling == layer) continue;
			if (objc_getAssociatedObject(sibling, KEY("lgfix_islandWaveMask")) || [sibling mask]) continue;
			CALayer *empty = [CALayer layer];
			[sibling setMask:empty];
			objc_setAssociatedObject(sibling, KEY("lgfix_islandWaveMask"), empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if (!mine) {
			objc_setAssociatedObject(wave, KEY("lgfix_islandWave"), wave, OBJC_ASSOCIATION_ASSIGN);
			if (!waveLogged) {
				waveLogged = YES;
				tlog("audio wave: drawn plain, without its black backing (%lu bars, logged once)",
				     (unsigned long)[[layer sublayers] count]);
			}
		}
	} else if (mine) {
		for (CALayer *sibling in [[layer superlayer] sublayers]) {
			CALayer *empty = objc_getAssociatedObject(sibling, KEY("lgfix_islandWaveMask"));
			if (!empty) continue;
			if ([sibling mask] == empty) [sibling setMask:nil];
			objc_setAssociatedObject(sibling, KEY("lgfix_islandWaveMask"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		[bars setBackgroundColor:[UIColor blackColor]];
		for (CALayer *bar in [layer sublayers]) [bar setCompositingFilter:[NSString stringWithUTF8String:"destOut"]];
		objc_setAssociatedObject(wave, KEY("lgfix_islandWave"), nil, OBJC_ASSOCIATION_ASSIGN);
	}
}

static void waveLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origWaveLayout)(self, _cmd);
	@try { waveSetClear(self, islandGlassOn()); } @catch (id e) {}
}

// MediaControls may not be loaded yet when this library is: tried again for a while
static void installWave(void *force) {
	if (waveHookInstalled) return;
	if (!force && strcmp(getprogname(), WAVE_PROCESS) != 0) return;
	Class cls = objc_getClass("MRUWaveformView");
	SEL sel = sel_registerName("layoutSubviews");
	Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!method) {
		if (++waveInstallTries <= 20)
			dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), force, installWave);
		return;
	}
	// the class's own method is replaced; one it only inherits gets an own method that calls the inherited one
	origWaveLayout = method_getImplementation(method);
	if (!class_addMethod(cls, sel, (IMP)waveLayout, method_getTypeEncoding(method)))
		origWaveLayout = method_setImplementation(method, (IMP)waveLayout);
	waveHookInstalled = YES;
	tlog("audio wave: watching the wave view");
}

#pragma mark - text loupe

#define LOUPE_HOST "PrefsSlider"
#define LOUPE_CLASSES 2

static const char *loupeClassNames[LOUPE_CLASSES] = { "_UITextLightLoupeView", "_UITextMagnifiedLoupeView" };
static IMP origLoupeLayout[LOUPE_CLASSES];
static IMP origLoupeTick[LOUPE_CLASSES];
static int loupeHooks;
static BOOL loupeLogged;
static int loupeForce;               // self-test: 1 = on, -1 = off
static int loupeWanted = -1;         // last answer, -1 = not asked yet
static CFAbsoluteTime loupeAskedAt;
#define LOUPE_BLUR 6.0               // frost of the lens, fixed
static id (*loupeCreateGlass)(CGRect, id, id);
static BOOL (*loupeHostEnabled)(id);
static id (*loupeTestCreate)(CGRect, id, id);

// Asked again at most every two seconds. Needs the original in this process (it makes the glass).
static BOOL loupeGlassWanted(void) {
	if (loupeForce) return loupeForce > 0;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (loupeWanted >= 0 && now - loupeAskedAt < 2.0) return loupeWanted;
	loupeAskedAt = now;
	int answer = 0;
	if (access(CTLDIR "/no-loupe-glass", F_OK) != 0 && access(CTLDIR "/disabled", F_OK) != 0) {
		if (!loupeCreateGlass) loupeCreateGlass = dlsym(RTLD_DEFAULT, "LGCreateRegisteredGlass");
		if (!loupeHostEnabled) loupeHostEnabled = dlsym(RTLD_DEFAULT, "lgHostEnabled");
		if (loupeCreateGlass && loupeHostEnabled)
			answer = loupeHostEnabled([NSString stringWithUTF8String:"TextLoupe"]) ? 1 : 0;
	}
	loupeWanted = answer;
	return answer;
}

// The renderer shapes the glass from the part of it that is on screen: a lens hanging over a screen edge (text
// field at the very top) would get the rim of a smaller pill drawn across it. Such a lens stays without glass.
static BOOL loupeCutByScreen(UIView *view) {
	UIWindow *window = [view window];
	if (!window) return NO;
	CGRect rect = [view convertRect:[view bounds] toView:nil];
	CGRect visible = [window bounds];
	UIScreen *screen = [window screen];
	if (screen) {
		CGRect onScreen = CGRectIntersection(visible, [window convertRect:[screen bounds] fromWindow:nil]);
		if (!CGRectIsEmpty(onScreen)) visible = onScreen;
	}
	return CGRectGetMinX(rect) < CGRectGetMinX(visible) - 0.5 || CGRectGetMinY(rect) < CGRectGetMinY(visible) - 0.5
	    || CGRectGetMaxX(rect) > CGRectGetMaxX(visible) + 0.5 || CGRectGetMaxY(rect) > CGRectGetMaxY(visible) + 0.5;
}

// The lens' pane is lifted above the finger by its own transform; near the top of the screen that puts part of
// it off screen. Its position is moved down by what is missing (plus a small gap), on top of whatever the system
// sets, and taken back as soon as the system's place fits again.
#define LOUPE_TOP_GAP 6.0
static int loupeKeepForce;           // self-test: -1 = leave the lens where the system puts it
static void loupeKeepOnScreen(UIView *content) {
	UIWindow *window = [content window];
	if (!window || loupeKeepForce < 0) return;
	NSNumber *setNumber = objc_getAssociatedObject(content, KEY("lgfix_loupeSetY")), *baseNumber = objc_getAssociatedObject(content, KEY("lgfix_loupeBaseY"));
	CGPoint center = [content center];
	// the system's own place: what is there now, unless it is still the place set here
	CGFloat base = (setNumber && baseNumber && fabs(center.y - [setNumber doubleValue]) < 0.01) ? [baseNumber doubleValue] : center.y;
	CGRect rect = [content convertRect:[content bounds] toView:nil];
	CGRect visible = [window bounds];
	UIScreen *screen = [window screen];
	if (screen) {
		CGRect onScreen = CGRectIntersection(visible, [window convertRect:[screen bounds] fromWindow:nil]);
		if (!CGRectIsEmpty(onScreen)) visible = onScreen;
	}
	CGFloat top = CGRectGetMinY(rect) - (center.y - base);
	CGFloat need = CGRectGetMinY(visible) + LOUPE_TOP_GAP - top;
	if (need < 0.0) need = 0.0;
	if (need > rect.size.height) need = rect.size.height;
	CGFloat y = base + need;
	if (fabs(center.y - y) > 0.01) {
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		[content setCenter:CGPointMake(center.x, y)];
		[CATransaction commit];
	}
	objc_setAssociatedObject(content, KEY("lgfix_loupeSetY"), [NSNumber numberWithDouble:y], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(content, KEY("lgfix_loupeBaseY"), [NSNumber numberWithDouble:base], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#define LOUPE_RING_MAX 3.0           // the lens' coloured ring is its container's border, about 1.5 pt when open

// Clear lens: the lens is a pane of glass over whatever lies behind it on screen, not a picture of the text
// line. The enlarged copy of the text (a portal of the app's window) and the container's white backing are
// left out and the coloured ring goes once the lens is open. clear = NO puts the system's lens back.
// So that the text under the finger can still be read, the copy of the text line is not dropped but laid into
// the clear lens as a band around the line (text field and text as they are); above and below the band the lens
// stays clear glass. The band is a plain clip of the copy's container: on screen the copy vanished altogether
// under any mask layer (empty, gradient) and under a blend mode.
// For UITextField / UITextView the band is not used: there only the text itself is copied (loupeSetTextOnly).
#define LOUPE_BAND 0.46              // share of the lens height the text line keeps
#define LOUPE_BAND_RADIUS 12.0

// Clips the container of the text copy to a band across the middle of the lens: the bounds shrink around the
// unchanged centre, with their origin moved so that the copy inside stays where it was. on = NO undoes it.
static void loupeSetBand(UIView *portal, BOOL on) {
	NSValue *full = objc_getAssociatedObject(portal, KEY("lgfix_loupeFull"));
	CGRect bounds = [portal bounds];
	if (!on) {
		if (!full) return;
		if (bounds.origin.y != 0.0) [portal setBounds:[full CGRectValue]];
		[[portal layer] setMasksToBounds:NO];
		[[portal layer] setCornerRadius:0.0];
		objc_setAssociatedObject(portal, KEY("lgfix_loupeFull"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}
	// bounds starting at 0 are the lens' own (first time, or set again by its layout)
	if (bounds.origin.y == 0.0) {
		full = [NSValue valueWithCGRect:bounds];
		objc_setAssociatedObject(portal, KEY("lgfix_loupeFull"), full, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if (!full) return;
	CGRect whole = [full CGRectValue];
	CGFloat height = floor(whole.size.height * LOUPE_BAND);
	if (height < 12.0) return;
	CGRect band = CGRectMake(0.0, floor((whole.size.height - height) * 0.5), whole.size.width, height);
	if (!CGRectEqualToRect(bounds, band)) [portal setBounds:band];
	if (![[portal layer] masksToBounds]) {
		[[portal layer] setMasksToBounds:YES];
		[[portal layer] setCornerRadius:LOUPE_BAND_RADIUS];
		[[portal layer] setCornerCurve:kCACornerCurveContinuous];
	}
}

#define FIELD_BLUR_DEFAULT 5.0
static double fieldBlur = FIELD_BLUR_DEFAULT;   // search fields: "SearchField.Blur", asked together with fieldWanted
static UIColor *fieldTint;             // search fields: "SearchField.TintColor" (#RRGGBBAA), nil = none
#define LOUPE_STRIP 240.0             // height of the window strips above and below a glass text bar
static UIView *loupeTestResponder;    // self-test: stands in for the window's first responder

// Text only: the lens' own picture is a copy of the whole window, text field fill included. In its place the
// lens gets copies of just the parts of the text view being edited (its subviews: text, insertion point, icons)
// without the view's fill, so the text stands directly on the clear glass. The copies sit in a view that takes
// over the geometry of the lens' own window copy every frame, at the places those parts have in the window, so
// they move and enlarge exactly as the lens does it. Only for UITextField / UITextView; anything else (web
// pages) returns NO and keeps the band. on = NO removes the copies and shows the lens' own picture again.
static BOOL loupeSetTextOnly(UIView *loupe, UIView *holder, BOOL on) {
	UIView *wrap = objc_getAssociatedObject(loupe, KEY("lgfix_loupeTextWrap"));
	SEL portalViewSel = sel_registerName("portalView"), sourceSel = sel_registerName("sourceView");
	UIView *system = [loupe respondsToSelector:portalViewSel] ? ((id (*)(id, SEL))objc_msgSend)(loupe, portalViewSel) : nil;
	UIView *root = [system respondsToSelector:sourceSel] ? ((id (*)(id, SEL))objc_msgSend)(system, sourceSel) : nil;
	UIView *responder = nil;
	Class portalClass = objc_getClass("_UIPortalView");
	if (on && portalClass && [root isKindOfClass:[UIView class]] && [system superview] == holder) {
		UIWindow *window = [root isKindOfClass:[UIWindow class]] ? (UIWindow *)root : [root window];
		SEL firstSel = sel_registerName("firstResponder");
		responder = loupeTestResponder ? loupeTestResponder
		          : ([window respondsToSelector:firstSel] ? ((id (*)(id, SEL))objc_msgSend)(window, firstSel) : nil);
		if (!([responder isKindOfClass:[UITextField class]] || [responder isKindOfClass:[UITextView class]])
		    || ![responder isDescendantOfView:root]) responder = nil;
	}
	if (!responder) {
		if (wrap) {
			[wrap removeFromSuperview];
			objc_setAssociatedObject(loupe, KEY("lgfix_loupeTextWrap"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			if ([system isHidden]) [system setHidden:NO];
		}
		return NO;
	}
	// the parts: everything in the text view but the view it draws its fill with
	UIView *fill = nil;
	SEL fillSel = sel_registerName("_backgroundView");
	if ([responder respondsToSelector:fillSel]) fill = ((id (*)(id, SEL))objc_msgSend)(responder, fillSel);
	// (the glass and tint this library lays into a search field are not parts of the text either: the lens shows
	// the bar by its own stand-in)
	UIView *ownGlass = objc_getAssociatedObject(responder, KEY("lgfix_fieldGlass")), *ownTint = objc_getAssociatedObject(responder, KEY("lgfix_fieldTint"));
	NSMutableArray *parts = [NSMutableArray array];
	for (UIView *sub in [responder subviews]) if (sub != fill && sub != ownGlass && sub != ownTint) [parts addObject:sub];
	if ([parts count] == 0 || [parts count] > 24) parts = [NSMutableArray arrayWithObject:responder];
	BOOL whole = [parts count] == 1 && [parts objectAtIndex:0] == responder;

	UIView *clip = objc_getAssociatedObject(wrap, KEY("lgfix_loupeClip"));
	if (!wrap) {
		wrap = [[UIView alloc] initWithFrame:CGRectZero];
		[wrap setUserInteractionEnabled:NO];
		clip = [[UIView alloc] initWithFrame:CGRectZero];
		[clip setClipsToBounds:YES];
		[wrap addSubview:clip];
		objc_setAssociatedObject(wrap, KEY("lgfix_loupeClip"), clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(loupe, KEY("lgfix_loupeTextWrap"), wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if ([wrap superview] != holder) [holder addSubview:wrap];
	NSArray *known = objc_getAssociatedObject(wrap, KEY("lgfix_loupeParts"));
	if (![known isEqualToArray:parts]) {
		for (UIView *old in [[clip subviews] copy]) [old removeFromSuperview];
		for (UIView *part in parts) {
			UIView *copy = ((id (*)(id, SEL, id))objc_msgSend)([portalClass alloc], sel_registerName("initWithSourceView:"), part);
			if (!copy) continue;
			[copy setUserInteractionEnabled:NO];
			// each copy sits at the origin of a view of its own, and that view is put at the part's place: a copy
			// moved by its own frame still drew its part at the origin of the view around it (seen in the App Store:
			// text and clear button at the field's left end)
			UIView *spot = [[UIView alloc] initWithFrame:CGRectZero];
			[spot setUserInteractionEnabled:NO];
			[spot addSubview:copy];
			[clip addSubview:spot];
		}
		objc_setAssociatedObject(wrap, KEY("lgfix_loupeParts"), [parts copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	CALayer *from = [system layer], *to = [wrap layer];
	[to setAnchorPoint:[from anchorPoint]];
	[to setBounds:[from bounds]];
	[to setPosition:[from position]];
	[to setTransform:[from transform]];
	// the clip is the text view's place in the window, with the text view's own (scrolled) coordinates inside
	CGRect place = [responder convertRect:[responder bounds] toView:root];
	[clip setBounds:[responder bounds]];
	[clip setCenter:CGPointMake(CGRectGetMidX(place), CGRectGetMidY(place))];
	NSArray *copies = [clip subviews];
	for (NSUInteger i = 0; i < [copies count] && i < [parts count]; i++) {
		UIView *part = [parts objectAtIndex:i];
		UIView *spot = [copies objectAtIndex:i];
		[spot setFrame:whole ? [responder bounds] : [part frame]];
		[(UIView *)[[spot subviews] firstObject] setFrame:[spot bounds]];
	}
	// the glass text bar the text sits in (search field glass of this library): shown in the lens as its shape,
	// a light edge (and the bar's tint colour) at the bar's place in the window, under the text. What makes a glass bar
	// readable as a bar is its surroundings: the window as it is above and below the bar is copied into the lens
	// too (two strips, each a plain clip holding a copy of the window; a mask would make the copy vanish), so the
	// bar is the see-through band between them.
	UIView *barGlass = nil;
	for (UIView *view = responder; view && view != root && !barGlass; view = [view superview]) {
		UIView *candidate = objc_getAssociatedObject(view, KEY("lgfix_fieldGlass"));
		if (candidate && ![candidate isHidden] && [candidate window]) barGlass = candidate;
	}
	UIView *bar = objc_getAssociatedObject(wrap, KEY("lgfix_loupeBar"));
	if (barGlass) {
		if (!bar) {
			bar = [[UIView alloc] initWithFrame:CGRectZero];
			[bar setUserInteractionEnabled:NO];
			objc_setAssociatedObject(wrap, KEY("lgfix_loupeBar"), bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if ([bar superview] != wrap) [wrap insertSubview:bar atIndex:0];
		[bar setFrame:[barGlass convertRect:[barGlass bounds] toView:root]];
		[[bar layer] setCornerRadius:[[barGlass layer] cornerRadius]];
		[[bar layer] setCornerCurve:kCACornerCurveContinuous];
		BOOL dark = [[responder traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark;
		[bar setClipsToBounds:YES];
		[[bar layer] setBorderWidth:1.0];
		[[bar layer] setBorderColor:[[UIColor colorWithWhite:1.0 alpha:dark ? 0.45 : 0.7] CGColor]];
		// the frosted lens blurs the whole pane already: the band keeps its edge and the wash of the bar's tint
		UIView *wash = objc_getAssociatedObject(bar, KEY("lgfix_loupeBarWash"));
		if (!wash) {
			wash = [[UIView alloc] initWithFrame:[bar bounds]];
			[wash setUserInteractionEnabled:NO];
			[wash setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
			[bar addSubview:wash];
			objc_setAssociatedObject(bar, KEY("lgfix_loupeBarWash"), wash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		UIColor *washColor = fieldTint ? fieldTint : [UIColor clearColor];
		if (![[wash backgroundColor] isEqual:washColor]) [wash setBackgroundColor:washColor];
		if ([bar isHidden]) [bar setHidden:NO];
		CGRect barRect = [bar frame], rootBounds = [root bounds];
		for (int i = 0; i < 2; i++) {
			const void *key = i == 0 ? KEY("lgfix_loupeStripAbove") : KEY("lgfix_loupeStripBelow");
			UIView *strip = objc_getAssociatedObject(wrap, key);
			if (!strip) {
				strip = [[UIView alloc] initWithFrame:CGRectZero];
				[strip setUserInteractionEnabled:NO];
				[strip setClipsToBounds:YES];
				UIView *copy = ((id (*)(id, SEL, id))objc_msgSend)([portalClass alloc], sel_registerName("initWithSourceView:"), root);
				if (copy) {
					[copy setUserInteractionEnabled:NO];
					[strip addSubview:copy];
				}
				objc_setAssociatedObject(wrap, key, strip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
			if ([strip superview] != wrap) [wrap insertSubview:strip atIndex:0];
			// the strip's own coordinates are the window's, so the copy lies in it at the window's bounds
			CGFloat top = i == 0 ? CGRectGetMinY(barRect) - LOUPE_STRIP : CGRectGetMaxY(barRect);
			CGRect part = CGRectMake(CGRectGetMinX(rootBounds), top, rootBounds.size.width, LOUPE_STRIP);
			[strip setBounds:part];
			[strip setCenter:CGPointMake(CGRectGetMidX(part), CGRectGetMidY(part))];
			[(UIView *)[[strip subviews] firstObject] setFrame:rootBounds];
			if ([strip isHidden]) [strip setHidden:NO];
		}
	} else {
		if (bar && ![bar isHidden]) [bar setHidden:YES];
		for (int i = 0; i < 2; i++) {
			UIView *strip = objc_getAssociatedObject(wrap, i == 0 ? KEY("lgfix_loupeStripAbove") : KEY("lgfix_loupeStripBelow"));
			if (strip && ![strip isHidden]) [strip setHidden:YES];
		}
	}
	[CATransaction commit];
	if (![system isHidden]) [system setHidden:YES];
	return YES;
}

// Frost: the clear lens does not show what lies behind it sharply but softened and under a faint veil, like
// frosted glass (the original's blur view and a wash over it, both at the very bottom of the lens). The text
// being edited, the insertion point and the window strips lie above it and stay sharp.
static void loupeSetFrost(UIView *loupe, UIView *container, BOOL on) {
	UIView *frost = objc_getAssociatedObject(container, KEY("lgfix_loupeFrost"));
	if (!on) {
		if (frost && ![frost isHidden]) [frost setHidden:YES];
		return;
	}
	UIView *blur = objc_getAssociatedObject(frost, KEY("lgfix_loupeFrostBlur")), *wash = objc_getAssociatedObject(frost, KEY("lgfix_loupeFrostWash"));
	if (!frost) {
		frost = [[UIView alloc] initWithFrame:[container bounds]];
		[frost setUserInteractionEnabled:NO];
		Class blurClass = objc_getClass("LGSettingsLowBlurView");
		if (blurClass) {
			blur = [[blurClass alloc] initWithFrame:[frost bounds]];
			[blur setUserInteractionEnabled:NO];
			[blur setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
			[frost addSubview:blur];
			objc_setAssociatedObject(frost, KEY("lgfix_loupeFrostBlur"), blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		wash = [[UIView alloc] initWithFrame:[frost bounds]];
		[wash setUserInteractionEnabled:NO];
		[wash setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
		[frost addSubview:wash];
		objc_setAssociatedObject(frost, KEY("lgfix_loupeFrostWash"), wash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(container, KEY("lgfix_loupeFrost"), frost, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if ([frost superview] != container) [container insertSubview:frost atIndex:0];
	else if ([[container subviews] firstObject] != frost) [container sendSubviewToBack:frost];
	if (!CGRectEqualToRect([frost frame], [container bounds])) [frost setFrame:[container bounds]];
	if (blur && !objc_getAssociatedObject(blur, KEY("lgfix_loupeBarRadius"))) {
		@try { [blur setValue:[NSNumber numberWithDouble:LOUPE_BLUR] forKey:[NSString stringWithUTF8String:"lgBlurRadius"]]; } @catch (id e) {}
		objc_setAssociatedObject(blur, KEY("lgfix_loupeBarRadius"), [NSNumber numberWithDouble:LOUPE_BLUR], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	BOOL dark = [[loupe traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark;
	UIColor *color = [UIColor colorWithWhite:1.0 alpha:dark ? 0.10 : 0.18];
	if (![[wash backgroundColor] isEqual:color]) [wash setBackgroundColor:color];
	if ([frost isHidden]) [frost setHidden:NO];
}

static void loupeSetClear(UIView *loupe, UIView *container, UIView *glass, BOOL clear) {
	SEL portalSel = sel_registerName("portalContainerView");
	if (!container || ![loupe respondsToSelector:portalSel]) return;
	UIView *portal = ((id (*)(id, SEL))objc_msgSend)(loupe, portalSel);
	if (![portal isKindOfClass:[UIView class]]) return;
	loupeSetFrost(loupe, container, clear);
	if (!clear) {
		loupeSetTextOnly(loupe, portal, NO);
		loupeSetBand(portal, NO);
		UIColor *backing = objc_getAssociatedObject(container, KEY("lgfix_loupeBacking"));
		if (backing) {
			[container setBackgroundColor:backing];
			NSNumber *ring = objc_getAssociatedObject(container, KEY("lgfix_loupeRing"));
			if (ring && [[container layer] borderWidth] == 0.0) [[container layer] setBorderWidth:[ring doubleValue]];
			objc_setAssociatedObject(container, KEY("lgfix_loupeBacking"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(container, KEY("lgfix_loupeRing"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		return;
	}
	// text only where the text view allows it, else the band with the text field in it
	BOOL textOnly = loupeSetTextOnly(loupe, portal, YES);
	loupeSetBand(portal, !textOnly);
	UIColor *backing = [container backgroundColor];
	if (backing && CGColorGetAlpha([backing CGColor]) > 0.0) {
		objc_setAssociatedObject(container, KEY("lgfix_loupeBacking"), backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[container setBackgroundColor:[UIColor clearColor]];
	}
	CGFloat ring = [[container layer] borderWidth];
	if (ring > 0.0 && ring <= LOUPE_RING_MAX) {
		objc_setAssociatedObject(container, KEY("lgfix_loupeRing"), [NSNumber numberWithDouble:ring], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[[container layer] setBorderWidth:0.0];
	}
}

static void loupeUpdate(UIView *loupe) {
	UIView *glass = objc_getAssociatedObject(loupe, KEY("lgfix_loupeGlass"));
	if (!loupeGlassWanted()) {
		if (glass) {
			if (![glass isHidden]) [glass setHidden:YES];
			loupeSetClear(loupe, [glass superview], glass, NO);
		}
		return;
	}
	// The loupe's own clipped content view gives the shape
	UIView *content = nil;
	for (UIView *sub in [loupe subviews]) {
		if (sub == glass) continue;
		if ([[sub layer] masksToBounds] && [[sub layer] cornerRadius] > 0.0) { content = sub; break; }
	}
	UIView *parent = content ? content : loupe;
	CGRect frame = [parent bounds];
	CGFloat shortSide = MIN(frame.size.width, frame.size.height);
	if (shortSide < 20.0) {
		if (glass) {
			if (![glass isHidden]) [glass setHidden:YES];
			loupeSetClear(loupe, [glass superview], glass, NO);
		}
		return;
	}
	CGFloat radius = content ? [[content layer] cornerRadius] : shortSide * 0.5;
	if (radius > shortSide * 0.5) radius = shortSide * 0.5;
	if (!glass) {
		id (*create)(CGRect, id, id) = loupeTestCreate ? loupeTestCreate : loupeCreateGlass;
		if (!create) return;
		glass = create(frame, nil, [NSString stringWithUTF8String:LOUPE_HOST]);
		if (!glass) return;
		[glass setUserInteractionEnabled:NO];
		objc_setAssociatedObject(loupe, KEY("lgfix_loupeGlass"), glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (!loupeLogged) {
			loupeLogged = YES;
			tlog("text loupe: glass laid over %s, %.0fx%.0f radius %.1f (logged once)", class_getName(object_getClass(loupe)),
			     frame.size.width, frame.size.height, radius);
		}
	}
	if ([glass superview] != parent) [parent addSubview:glass];
	else if ([[parent subviews] lastObject] != glass) [parent bringSubviewToFront:glass];
	if (content) loupeKeepOnScreen(content);
	BOOL cut = loupeCutByScreen(parent);
	if ([glass isHidden] != cut) [glass setHidden:cut];
	// the frosted pane and the text stay also where the glass cannot be drawn; a light edge stands in for its rim
	loupeSetClear(loupe, content, glass, YES);
	UIView *frost = content ? objc_getAssociatedObject(content, KEY("lgfix_loupeFrost")) : nil;
	CGFloat edge = cut ? 1.0 : 0.0;
	if (frost && ([[frost layer] borderWidth] != edge || (cut && fabs([[frost layer] cornerRadius] - radius) > 0.25))) {
		BOOL dark = [[loupe traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark;
		[[frost layer] setCornerRadius:radius];
		[[frost layer] setCornerCurve:[[content layer] cornerCurve]];
		[[frost layer] setBorderColor:[[UIColor colorWithWhite:1.0 alpha:dark ? 0.45 : 0.7] CGColor]];
		[[frost layer] setBorderWidth:edge];
	}
	CGSize oldSize = [glass bounds].size;
	BOOL changed = fabs(oldSize.width - frame.size.width) > 0.5 || fabs(oldSize.height - frame.size.height) > 0.5
	            || fabs([[glass layer] cornerRadius] - radius) > 0.25;
	if (!CGRectEqualToRect([glass frame], frame)) [glass setFrame:frame];
	if (changed) {
		[[glass layer] setCornerRadius:radius];
		if (content) [[glass layer] setCornerCurve:[[content layer] cornerCurve]];
		[[glass layer] setMasksToBounds:YES];
		// the glass picks its filter by its radius
		if ([glass respondsToSelector:@selector(applyFilters)]) ((void (*)(id, SEL))objc_msgSend)(glass, @selector(applyFilters));
	}
	// Full capture resolution: the text in the lens has to stay sharp
	@try {
		NSString *scaleKey = [NSString stringWithUTF8String:"scale"];
		id current = [[glass layer] valueForKey:scaleKey];
		if (![current respondsToSelector:@selector(doubleValue)] || fabs([current doubleValue] - 1.0) > 0.01)
			[[glass layer] setValue:[NSNumber numberWithDouble:1.0] forKey:scaleKey];
	} @catch (id e) {}
}

static void loupeLayoutFor(UIView *self, SEL _cmd, int index) {
	((void (*)(id, SEL))origLoupeLayout[index])(self, _cmd);
	@try { loupeUpdate(self); } @catch (id e) {}
}
static void loupeLayout0(UIView *self, SEL _cmd) { loupeLayoutFor(self, _cmd, 0); }
static void loupeLayout1(UIView *self, SEL _cmd) { loupeLayoutFor(self, _cmd, 1); }

// The lens moves without a layout; its own display link runs while it does
static void loupeTickFor(UIView *self, SEL _cmd, id link, int index) {
	((void (*)(id, SEL, id))origLoupeTick[index])(self, _cmd, link);
	// the lens also sets its ring width here, frame by frame
	@try { loupeUpdate(self); } @catch (id e) {}
}
static void loupeTick0(UIView *self, SEL _cmd, id link) { loupeTickFor(self, _cmd, link, 0); }
static void loupeTick1(UIView *self, SEL _cmd, id link) { loupeTickFor(self, _cmd, link, 1); }

static void installLoupe(void) {
	if (loupeHooks || access(CTLDIR "/no-loupe-glass", F_OK) == 0) return;
	SEL sel = sel_registerName("layoutSubviews");
	SEL tickSel = sel_registerName("_displayLinkFired:");
	for (int i = 0; i < LOUPE_CLASSES; i++) {
		Class cls = objc_getClass(loupeClassNames[i]);
		Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
		if (!method) continue;
		IMP mine = i == 0 ? (IMP)loupeLayout0 : (IMP)loupeLayout1;
		// the class's own method is replaced; one it only inherits gets an own method that calls the inherited one
		origLoupeLayout[i] = method_getImplementation(method);
		if (!class_addMethod(cls, sel, mine, method_getTypeEncoding(method)))
			origLoupeLayout[i] = method_setImplementation(method, mine);
		loupeHooks++;
		Method tick = class_getInstanceMethod(cls, tickSel);
		if (tick) {
			IMP mineTick = i == 0 ? (IMP)loupeTick0 : (IMP)loupeTick1;
			origLoupeTick[i] = method_getImplementation(tick);
			if (!class_addMethod(cls, tickSel, mineTick, method_getTypeEncoding(tick)))
				origLoupeTick[i] = method_setImplementation(tick, mineTick);
		}
	}
}

#pragma mark - search fields

// Search fields as a pane of glass: the system's search field (UISearchTextField, every app) and Safari's
// address capsule (SFCapsuleView). The field's own grey backing is left out (empty mask, nothing is removed) and
// a glass of the original (host "SearchPill", so the Search Pill values apply) lies in its place, under the
// field's text. On when the tweak is on; "SearchField.Enabled" = false in the settings switches it off.
// Own values: "SearchField.Blur" (the glass's blur, in place of the Search Pill's) and "SearchField.TintColor"
// (a colour laid over the glass). Rim and refraction are the Search Pill's.
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-searchfield-glass

#define FIELD_HOST "SearchPill"
#define FIELD_KINDS 2                // 0 = system search field, 1 = Safari capsule

static const char *fieldClassNames[FIELD_KINDS] = { "UISearchTextField", "SFCapsuleView" };
static IMP origFieldLayout[FIELD_KINDS];
static BOOL fieldLogged[FIELD_KINDS];
static int fieldInstallTries;
static int fieldForce;               // self-test: 1 = on, -1 = off
static int fieldWanted = -1;
static CFAbsoluteTime fieldAskedAt;
static id (*fieldTestCreate)(CGRect, id, id);
static NSHashTable *fieldOwners;                // weak: fields that carry a glass, laid out again when the settings change
static BOOL fieldObserving;

// "#RRGGBBAA" -> colour, nil when it is not one or fully transparent
static UIColor *fieldColorFromHex(id text) {
	if (![text isKindOfClass:[NSString class]]) return nil;
	const char *hex = [(NSString *)text UTF8String];
	unsigned int r, g, b, a;
	if (!hex || strlen(hex) != 9 || sscanf(hex, "#%02x%02x%02x%02x", &r, &g, &b, &a) != 4 || a == 0) return nil;
	return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

static void fieldsRefresh(void *unused) {
	fieldWanted = -1;
	for (UIView *owner in [fieldOwners allObjects]) [owner setNeedsLayout];
}

// the settings were changed: ask again and lay the fields out, after the original has re-read its own values
static void fieldSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL, fieldsRefresh);
}

static BOOL fieldGlassWanted(void) {
	if (fieldForce) return fieldForce > 0;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (fieldWanted >= 0 && now - fieldAskedAt < 2.0) return fieldWanted;
	fieldAskedAt = now;
	int answer = 0;
	if (access(CTLDIR "/no-searchfield-glass", F_OK) != 0 && access(CTLDIR "/disabled", F_OK) != 0) {
		if (!loupeCreateGlass) loupeCreateGlass = dlsym(RTLD_DEFAULT, "LGCreateRegisteredGlass");
		if (!loupeHostEnabled) loupeHostEnabled = dlsym(RTLD_DEFAULT, "lgHostEnabled");
		if (loupeCreateGlass && loupeHostEnabled)
			answer = loupeHostEnabled([NSString stringWithUTF8String:"SearchField"]) ? 1 : 0;
		// own values: read from the settings file itself (the original's cached copy did not follow the settings in apps)
		NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:PREFS_FILE]];
		id blurValue = [file objectForKey:[NSString stringWithUTF8String:"SearchField.Blur"]];
		id tintValue = [file objectForKey:[NSString stringWithUTF8String:"SearchField.TintColor"]];
		if (![file isKindOfClass:[NSDictionary class]]) {
			double (*prefFloat)(id, double) = dlsym(RTLD_DEFAULT, "LG_prefFloat");
			id (*prefString)(id, id) = dlsym(RTLD_DEFAULT, "LG_prefString");
			if (prefFloat) blurValue = [NSNumber numberWithDouble:prefFloat([NSString stringWithUTF8String:"SearchField.Blur"], FIELD_BLUR_DEFAULT)];
			if (prefString) tintValue = prefString([NSString stringWithUTF8String:"SearchField.TintColor"], nil);
		}
		double blur = [blurValue isKindOfClass:[NSNumber class]] ? [blurValue doubleValue] : FIELD_BLUR_DEFAULT;
		fieldBlur = isfinite(blur) ? fmin(50.0, fmax(0.0, blur)) : FIELD_BLUR_DEFAULT;
		fieldTint = fieldColorFromHex(tintValue);
	}
	fieldWanted = answer;
	return answer;
}

static UIView *fieldViewIvar(id object, const char *name) {
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	id value = ivar ? object_getIvar(object, ivar) : nil;
	return [value isKindOfClass:[UIView class]] ? value : nil;
}

static void fieldSetBacking(UIView *backing, BOOL leftOut) {
	if (!backing) return;
	CALayer *mask = objc_getAssociatedObject(backing, KEY("lgfix_fieldMask"));
	if (leftOut) {
		if (!mask) {
			mask = [CALayer layer];
			objc_setAssociatedObject(backing, KEY("lgfix_fieldMask"), mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if ([[backing layer] mask] != mask) [[backing layer] setMask:mask];
	} else if (mask) {
		if ([[backing layer] mask] == mask) [[backing layer] setMask:nil];
		objc_setAssociatedObject(backing, KEY("lgfix_fieldMask"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

// owner keeps the glass; it lies directly under backing (the view the field draws its fill with) and takes over
// its frame, alpha and hidden state; other = a second fill view of the same field, may be nil
static void fieldUpdate(UIView *owner, UIView *backing, UIView *other, CGFloat radius, int kind) {
	UIView *glass = objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass"));
	UIView *parent = [backing superview];
	CGRect frame = backing ? [backing frame] : CGRectZero;
	CGFloat shortSide = MIN(frame.size.width, frame.size.height);
	if (!fieldGlassWanted() || !parent || shortSide < 20.0) {
		if (glass && ![glass isHidden]) [glass setHidden:YES];
		UIView *oldTint = objc_getAssociatedObject(owner, KEY("lgfix_fieldTint"));
		if (oldTint && ![oldTint isHidden]) [oldTint setHidden:YES];
		fieldSetBacking(backing, NO);
		fieldSetBacking(other, NO);
		return;
	}
	if (radius <= 0.0 || radius > shortSide * 0.5) radius = shortSide * 0.5;
	if (!glass) {
		id (*create)(CGRect, id, id) = fieldTestCreate ? fieldTestCreate : loupeCreateGlass;
		if (!create) return;
		glass = create(frame, nil, [NSString stringWithUTF8String:FIELD_HOST]);
		if (!glass) return;
		[glass setUserInteractionEnabled:NO];
		objc_setAssociatedObject(owner, KEY("lgfix_fieldGlass"), glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (!fieldOwners) fieldOwners = [NSHashTable weakObjectsHashTable];
		[fieldOwners addObject:owner];
		if (!fieldObserving) {
			fieldObserving = YES;
			CFStringRef name = CFStringCreateWithCString(NULL, "dylv.liquidassprefs/Reload", kCFStringEncodingUTF8);
			CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, fieldSettingsChanged, name, NULL,
			                                CFNotificationSuspensionBehaviorDeliverImmediately);
			CFRelease(name);
		}
		if (!fieldLogged[kind]) {
			fieldLogged[kind] = YES;
			tlog("search field: glass laid under %s, %.0fx%.0f radius %.1f (logged once)", class_getName(object_getClass(owner)),
			     frame.size.width, frame.size.height, radius);
		}
	}
	if ([glass superview] != parent) [parent insertSubview:glass belowSubview:backing];
	BOOL hidden = [backing isHidden];
	if ([glass isHidden] != hidden) [glass setHidden:hidden];
	if (fabs([glass alpha] - [backing alpha]) > 0.005) [glass setAlpha:[backing alpha]];
	CGSize oldSize = [glass bounds].size;
	BOOL changed = fabs(oldSize.width - frame.size.width) > 0.5 || fabs(oldSize.height - frame.size.height) > 0.5
	            || fabs([[glass layer] cornerRadius] - radius) > 0.25;
	if (!CGRectEqualToRect([glass frame], frame)) [glass setFrame:frame];
	if (changed) {
		[[glass layer] setCornerRadius:radius];
		[[glass layer] setCornerCurve:kCACornerCurveContinuous];
		[[glass layer] setMasksToBounds:YES];
		// the glass picks its filter by its radius
		if ([glass respondsToSelector:@selector(applyFilters)]) ((void (*)(id, SEL))objc_msgSend)(glass, @selector(applyFilters));
	}
	// own blur in place of the host's (the glass sets the host's again whenever it applies its filter)
	SEL blurSel = sel_registerName("updateNativeBlurOverlayWithRadius:");
	if ([glass respondsToSelector:blurSel]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(glass, blurSel, fieldBlur);
	UIView *tint = objc_getAssociatedObject(owner, KEY("lgfix_fieldTint"));
	if (fieldTint) {
		if (!tint) {
			tint = [[UIView alloc] initWithFrame:frame];
			[tint setUserInteractionEnabled:NO];
			objc_setAssociatedObject(owner, KEY("lgfix_fieldTint"), tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if ([tint superview] != parent) [parent insertSubview:tint aboveSubview:glass];
		if (!CGRectEqualToRect([tint frame], frame)) [tint setFrame:frame];
		if (fabs([[tint layer] cornerRadius] - radius) > 0.25) {
			[[tint layer] setCornerRadius:radius];
			[[tint layer] setCornerCurve:kCACornerCurveContinuous];
		}
		if (![[tint backgroundColor] isEqual:fieldTint]) [tint setBackgroundColor:fieldTint];
		if ([tint isHidden] != hidden) [tint setHidden:hidden];
		if (fabs([tint alpha] - [backing alpha]) > 0.005) [tint setAlpha:[backing alpha]];
	} else if (tint && ![tint isHidden]) {
		[tint setHidden:YES];
	}
	fieldSetBacking(backing, YES);
	fieldSetBacking(other, YES);
}

static double fieldDoubleIvar(id object, const char *name) {
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
	if (!type || type[0] != 'd') return 0.0;
	return *(double *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
}

// The view the text field draws its rounded grey fill with (a direct subview of the field)
static UIView *searchFieldBacking(UIView *field) {
	SEL sel = sel_registerName("_backgroundView");
	if (![field respondsToSelector:sel]) return nil;
	UIView *backing = ((id (*)(id, SEL))objc_msgSend)(field, sel);
	return [backing isKindOfClass:[UIView class]] && [backing superview] == field ? backing : nil;
}

static void searchFieldLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origFieldLayout[0])(self, _cmd);
	@try {
		UIView *backing = searchFieldBacking(self);
		if (!backing) return;
		CGFloat radius = fieldDoubleIvar(backing, "_cornerRadius");
		if (radius <= 0.0) radius = [[backing layer] cornerRadius];
		if (radius <= 0.0) radius = 10.0;
		fieldUpdate(self, backing, nil, radius, 0);
	} @catch (id e) {}
}

static void capsuleLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origFieldLayout[1])(self, _cmd);
	@try {
		UIView *backing = fieldViewIvar(self, "_background");
		if (!backing) return;
		CGFloat radius = fieldDoubleIvar(self, "_backgroundCornerRadius");
		if (radius <= 0.0) radius = [[backing layer] cornerRadius];
		fieldUpdate(self, backing, nil, radius, 1);
	} @catch (id e) {}
}

// Safari's classes come with a framework that may be loaded after this library: tried again for a while
static void installFields(void *unused) {
	if (access(CTLDIR "/no-searchfield-glass", F_OK) == 0) return;
	SEL sel = sel_registerName("layoutSubviews");
	BOOL missing = NO;
	for (int i = 0; i < FIELD_KINDS; i++) {
		if (origFieldLayout[i]) continue;
		Class cls = objc_getClass(fieldClassNames[i]);
		Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
		if (!method) { missing = YES; continue; }
		IMP mine = i == 0 ? (IMP)searchFieldLayout : (IMP)capsuleLayout;
		// the class's own method is replaced; one it only inherits gets an own method that calls the inherited one
		origFieldLayout[i] = method_getImplementation(method);
		if (!class_addMethod(cls, sel, mine, method_getTypeEncoding(method)))
			origFieldLayout[i] = method_setImplementation(method, mine);
	}
	if (missing && ++fieldInstallTries <= 20)
		dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL, installFields);
}

static id fieldTestGlass(CGRect frame, id group, id prefix) { return [[UIView alloc] initWithFrame:frame]; }

// Private self-test (host), a plain view standing in for the glass. System search field: 1 hook in, 2 no glass
// while off, 4 glass directly under the field's fill in its frame with the fill left out, 8 still one glass
// after a second layout, 16 fill back and glass hidden when off. Safari capsule the same times 100 (0 when its
// framework cannot be loaded here).
int lgtabfix_fieldtest(const char *arg) {
	(void)arg;
	@autoreleasepool {
		int result = 0;
		dlopen("/System/Library/PrivateFrameworks/MobileSafari.framework/MobileSafari", RTLD_NOW);
		fieldTestCreate = fieldTestGlass;
		fieldInstallTries = 100;
		installFields(NULL);
		UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 430, 932)];
		for (int i = 0; i < FIELD_KINDS; i++) {
			int unit = i == 0 ? 1 : 100, got = 0;
			if (!origFieldLayout[i]) continue;
			got += 1;
			fieldForce = -1;
			UIView *owner = nil, *container = nil;
			@try {
				if (i == 0) {
					container = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 100, 430, 56)];
					[window addSubview:container];
					[container layoutIfNeeded];
					owner = [(UISearchBar *)container searchTextField];
				} else {
					owner = container = [[objc_getClass(fieldClassNames[i]) alloc] initWithFrame:CGRectMake(20, 700, 390, 52)];
					[window addSubview:container];
				}
				[owner setNeedsLayout]; [container layoutIfNeeded]; [owner layoutIfNeeded];
				UIView *backing = i == 0 ? searchFieldBacking(owner) : fieldViewIvar(owner, "_background");
				fprintf(stderr, "field test %s: backing=%s frame %.0fx%.0f in %s\n", fieldClassNames[i],
				        backing ? class_getName(object_getClass(backing)) : "none", [backing frame].size.width, [backing frame].size.height,
				        backing ? class_getName(object_getClass([backing superview])) : "-");
				if (!objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass"))) got += 2;
				fieldForce = 1;
				[owner setNeedsLayout]; [owner layoutIfNeeded];
				UIView *glass = objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass"));
				NSArray *siblings = [[backing superview] subviews];
				NSUInteger at = glass ? [siblings indexOfObject:glass] : NSNotFound;
				if (glass && at != NSNotFound && at + 1 < [siblings count] && [siblings objectAtIndex:at + 1] == backing
				    && CGRectEqualToRect([glass frame], [backing frame]) && [[backing layer] mask] && ![glass isHidden]) got += 4;
				NSUInteger count = [siblings count];
				[owner setNeedsLayout]; [owner layoutIfNeeded];
				if ([[[backing superview] subviews] count] == count && objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass")) == glass) got += 8;
				fieldForce = -1;
				[owner setNeedsLayout]; [owner layoutIfNeeded];
				if (glass && [glass isHidden] && ![[backing layer] mask]) got += 16;
			} @catch (id e) { fprintf(stderr, "field test %s: exception\n", fieldClassNames[i]); }
			result += got * unit;
		}
		fieldForce = 0;
		fieldTestCreate = NULL;
		return result;
	}
}

__attribute__((constructor)) static void lgtabfix_init(void) {
	if (access(CTLDIR "/disabled", F_OK) == 0) return;
	install();
	installKeyRadius();
	installWave(NULL);
	installLoupe();
	installFields(NULL);
}

static id loupeTestGlass(CGRect frame, id group, id prefix) { return [[UIView alloc] initWithFrame:frame]; }

// Private self-test (host) with the real loupe views and a plain view standing in for the glass (arg "real":
// the original's glass, when the original is loaded in the host). Per class, light loupe first: 1 hook in,
// 2 no glass while switched off, 4 glass on top inside the content view in its bounds and radius after a layout, 8 still one
// glass after a second layout, 16 hidden again when switched off, 32 hidden while the lens hangs over the top of
// the screen (64 by its display link alone, where the class has one), 128 shown again. Second class the same times 1000.
int lgtabfix_loupetest(const char *arg) {
	@autoreleasepool {
		int result = 0;
		BOOL real = arg && strcmp(arg, "real") == 0;
		if (real) {
			loupeCreateGlass = dlsym(RTLD_DEFAULT, "LGCreateRegisteredGlass");
			if (!loupeCreateGlass) return -1;
		} else {
			loupeTestCreate = loupeTestGlass;
		}
		installLoupe();
		UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 430, 932)];
		UIView *source = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 430, 932)];
		[window addSubview:source];
		for (int i = 0; i < LOUPE_CLASSES; i++) {
			int unit = i == 0 ? 1 : 1000, got = 0;
			Class cls = objc_getClass(loupeClassNames[i]);
			if (!cls || !origLoupeLayout[i]) continue;
			got += 1;
			loupeForce = -1; loupeKeepForce = -1;
			UIView *loupe = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], sel_registerName("initWithSourceView:"), source);
			CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(loupe, sel_registerName("preferredSize"));
			[window addSubview:loupe];
			[loupe setFrame:CGRectMake(100, 300, size.width, size.height)];
			[loupe layoutIfNeeded];
			if (!objc_getAssociatedObject(loupe, KEY("lgfix_loupeGlass"))) got += 2;
			loupeForce = 1;
			[loupe setNeedsLayout];
			[loupe layoutIfNeeded];
			UIView *glass = objc_getAssociatedObject(loupe, KEY("lgfix_loupeGlass"));
			UIView *content = [[loupe subviews] firstObject];
			if (glass && [[content subviews] lastObject] == glass && ![glass isHidden] && CGRectEqualToRect([glass frame], [content bounds])
			    && fabs([[glass layer] cornerRadius] - [[content layer] cornerRadius]) < 0.01 && [[glass layer] cornerRadius] > 10.0) got += 4;
			NSUInteger count = [[content subviews] count] + 100 * [[loupe subviews] count];
			[loupe setNeedsLayout];
			[loupe layoutIfNeeded];
			if ([[content subviews] count] + 100 * [[loupe subviews] count] == count && objc_getAssociatedObject(loupe, KEY("lgfix_loupeGlass")) == glass) got += 8;
			[loupe setFrame:CGRectMake(100, -30, size.width, size.height)];
			[loupe setNeedsLayout];
			[loupe layoutIfNeeded];
			if (glass && [glass isHidden]) got += 32;
			[loupe setFrame:CGRectMake(100, 300, size.width, size.height)];
			[loupe setNeedsLayout];
			[loupe layoutIfNeeded];
			if (glass && ![glass isHidden]) got += 128;
			if (origLoupeTick[i]) {
				[loupe setCenter:CGPointMake(160, 10)];
				((void (*)(id, SEL, id))objc_msgSend)(loupe, sel_registerName("_displayLinkFired:"), nil);
				if (glass && [glass isHidden]) got += 64;
				[loupe setCenter:CGPointMake(160, 340)];
				((void (*)(id, SEL, id))objc_msgSend)(loupe, sel_registerName("_displayLinkFired:"), nil);
				if (!glass || [glass isHidden]) got -= 64;
			}
			loupeForce = -1;
			[loupe setNeedsLayout];
			[loupe layoutIfNeeded];
			if (glass && [glass isHidden]) got += 16;
			SEL portalSel = sel_registerName("portalContainerView");
			if ([loupe respondsToSelector:portalSel]) {
				UIView *portal = ((id (*)(id, SEL))objc_msgSend)(loupe, portalSel);
				int clear = 0;
				loupeForce = 1;
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				CGPoint inLens = [portal convertPoint:CGPointMake(57, 42) toView:content];
				fprintf(stderr, "loupe text-in-lens test %s: mask=%d band %.0f,%.0f %.0fx%.0f frame y %.0f clip=%d centre maps to %.0f,%.0f backing clear=%d (want 0, 0,23 115x39, 23, 1, 57,42, 1)\n",
				        loupeClassNames[i], [[portal layer] mask] != nil, [portal bounds].origin.x, [portal bounds].origin.y, [portal bounds].size.width,
				        [portal bounds].size.height, [portal frame].origin.y, [[portal layer] masksToBounds], inLens.x, inLens.y,
				        CGColorGetAlpha([[content backgroundColor] CGColor]) == 0.0);
				{
					UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(40, 500, 300, 36)];
					UIView *partA = [[UIView alloc] initWithFrame:CGRectMake(8, 4, 200, 28)], *partB = [[UIView alloc] initWithFrame:CGRectMake(150, 6, 2, 24)];
					[field addSubview:partA]; [field addSubview:partB];
					UIView *holderView = [[UIView alloc] initWithFrame:CGRectMake(30, 490, 320, 56)], *standIn = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
					[[standIn layer] setCornerRadius:28.0];
					[holderView addSubview:standIn];
					[source addSubview:holderView];
					[field setFrame:CGRectMake(10, 10, 300, 36)];
					[holderView addSubview:field];
					objc_setAssociatedObject(holderView, KEY("lgfix_fieldGlass"), standIn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
					loupeTestResponder = field;
					[loupe setNeedsLayout]; [loupe layoutIfNeeded];
					UIView *system = ((id (*)(id, SEL))objc_msgSend)(loupe, sel_registerName("portalView"));
					UIView *wrap = objc_getAssociatedObject(loupe, KEY("lgfix_loupeTextWrap")), *clip = objc_getAssociatedObject(wrap, KEY("lgfix_loupeClip"));
					UIView *lensBar = objc_getAssociatedObject(wrap, KEY("lgfix_loupeBar"));
					UIView *above = objc_getAssociatedObject(wrap, KEY("lgfix_loupeStripAbove")), *below = objc_getAssociatedObject(wrap, KEY("lgfix_loupeStripBelow"));
					CGRect copyInWrap = [above convertRect:[(UIView *)[[above subviews] firstObject] frame] toView:wrap];
					fprintf(stderr, "loupe strips test: above %.0f..%.0f below %.0f..%.0f copy class=%s lies at %.0f,%.0f %.0fx%.0f order ok=%d (want 250..490, 546..786, _UIPortalView, 0,0 430x932, 1)\n",
					        CGRectGetMinY([above frame]), CGRectGetMaxY([above frame]), CGRectGetMinY([below frame]), CGRectGetMaxY([below frame]),
					        class_getName(object_getClass([[above subviews] firstObject])), copyInWrap.origin.x, copyInWrap.origin.y, copyInWrap.size.width, copyInWrap.size.height,
					        [[wrap subviews] indexOfObject:lensBar] == 2 && [[wrap subviews] lastObject] == clip);
					fprintf(stderr, "loupe bar look test: parts in the bar=%d wash colour=%d clip=%d blur class there=%d (want 1, 1, 1)\n", (int)[[lensBar subviews] count],
					        [(UIView *)[[lensBar subviews] lastObject] backgroundColor] != nil, [lensBar clipsToBounds], objc_getClass("LGSettingsLowBlurView") != nil);
					{
						UIView *frost = objc_getAssociatedObject(content, KEY("lgfix_loupeFrost"));
						fprintf(stderr, "loupe frost test: there=%d shown=%d at the bottom=%d fills the lens=%d wash=%d glass on top=%d (want 1 1 1 1 1 1)\n", frost != nil, frost && ![frost isHidden],
						        [[content subviews] firstObject] == frost, CGRectEqualToRect([frost frame], [content bounds]),
						        [(UIView *)[[frost subviews] lastObject] backgroundColor] != nil, [[content subviews] lastObject] == glass);
					}
					fprintf(stderr, "loupe bar test: bar=%d under the text=%d at %.0f,%.0f %.0fx%.0f radius %.0f (want 1 1 30,490 320x56 28)\n", lensBar && ![lensBar isHidden],
					        [[wrap subviews] indexOfObject:lensBar] < [[wrap subviews] indexOfObject:clip], [lensBar frame].origin.x, [lensBar frame].origin.y, [lensBar frame].size.width, [lensBar frame].size.height,
					        [[lensBar layer] cornerRadius]);
					NSArray *copies = [clip subviews];
					UIView *last = [copies lastObject];
					CGRect inRoot = last ? [clip convertRect:[last frame] toView:wrap] : CGRectZero;
					fprintf(stderr, "loupe text-only test %s: in holder=%d copies=%d of %d class=%s system hidden=%d band off=%d wrap %.0fx%.0f last copy at %.0f,%.0f %.0fx%.0f (want 1, n of n, _UIPortalView, 1, 1, 430x932, 190,506 2x24)\n",
					        loupeClassNames[i], [wrap superview] == portal, (int)[copies count], (int)[[field subviews] count], last ? class_getName(object_getClass([[last subviews] firstObject])) : "-",
					        [system isHidden], [portal bounds].origin.y == 0.0, [wrap bounds].size.width, [wrap bounds].size.height,
					        inRoot.origin.x, inRoot.origin.y, inRoot.size.width, inRoot.size.height);
					loupeTestResponder = nil;
					[loupe setNeedsLayout]; [loupe layoutIfNeeded];
					fprintf(stderr, "  back to the band: copies gone=%d system shown=%d band=%.0f (want 1 1 39)\n", !objc_getAssociatedObject(loupe, KEY("lgfix_loupeTextWrap")) && ![wrap superview],
					        ![system isHidden], [portal bounds].size.height);
					[holderView removeFromSuperview];
				}
				UIView *frost = objc_getAssociatedObject(content, KEY("lgfix_loupeFrost"));
				if (![[portal layer] mask] && CGColorGetAlpha([[content backgroundColor] CGColor]) == 0.0 && frost && ![frost isHidden]
				    && [[content subviews] lastObject] == glass) clear += 1;
				[[content layer] setBorderWidth:1.5];
				((void (*)(id, SEL, id))objc_msgSend)(loupe, sel_registerName("_displayLinkFired:"), nil);
				if (origLoupeTick[i] && [[content layer] borderWidth] <= 1.5) clear += 2;   // the tick itself may set a width
				[loupe setFrame:CGRectMake(100, -30, size.width, size.height)];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				if (CGColorGetAlpha([[content backgroundColor] CGColor]) == 0.0 && ![frost isHidden] && [glass isHidden]
				    && [[frost layer] borderWidth] == 1.0 && fabs([[frost layer] cornerRadius] - [[content layer] cornerRadius]) < 0.01) clear += 4;
				[loupe setFrame:CGRectMake(100, 300, size.width, size.height)];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				if (![glass isHidden] && [[frost layer] borderWidth] == 0.0) clear += 8;
				loupeForce = -1;
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				if (CGColorGetAlpha([[content backgroundColor] CGColor]) > 0.0 && [frost isHidden] && [glass isHidden]
				    && [portal bounds].origin.y == 0.0) clear += 16;
				fprintf(stderr, "loupe clear test %s: %d (want 31)\n", loupeClassNames[i], clear);
			}
			{
				loupeKeepForce = 0; loupeForce = 1;
				[loupe setFrame:CGRectMake(100, -30, size.width, size.height)];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				CGRect moved = [content convertRect:[content bounds] toView:nil];
				int shown = glass && ![glass isHidden];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				CGRect again = [content convertRect:[content bounds] toView:nil];
				[loupe setFrame:CGRectMake(100, 300, size.width, size.height)];
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
				CGRect back = [content convertRect:[content bounds] toView:nil];
				fprintf(stderr, "loupe on-screen test: top %.1f glass shown=%d, second layout top %.1f, free again top %.1f centre y %.1f (want 6.0 1, 6.0, the system's place)\n",
				        CGRectGetMinY(moved), shown, CGRectGetMinY(again), CGRectGetMinY(back), [content center].y);
				loupeForce = -1; loupeKeepForce = -1;
				[loupe setNeedsLayout]; [loupe layoutIfNeeded];
			}
			if (real && glass) tlog("loupe test: %s glass=%s frame %.0fx%.0f", loupeClassNames[i], class_getName(object_getClass(glass)), [glass frame].size.width, [glass frame].size.height);
			result += got * unit;
		}
		loupeForce = 0; loupeKeepForce = 0;
		return result;
	}
}

// Private self-test (host) with the real wave view in its island variant: 1 hook in, 10 black variant as
// expected, 100 cleared by its own layout, 1000 stays cleared over a second layout, 10000 put back
int lgtabfix_wavetest(const char *arg) {
	(void)arg;
	@autoreleasepool {
		int result = 0;
		dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
		waveForce = -1;
		installWave((void *)1);
		if (waveHookInstalled) result += 1;
		Class cls = objc_getClass("MRUWaveformView");
		SEL initSel = sel_registerName("initWithFrame:context:");
		if (!cls || ![cls instancesRespondToSelector:initSel]) return result;
		UIView *wave = ((id (*)(id, SEL, CGRect, unsigned long long))objc_msgSend)([cls alloc], initSel, CGRectMake(0, 0, 40, 24), 0ULL);
		UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
		[holder addSubview:wave];
		[wave layoutIfNeeded];
		CALayer *bars = [(UIView *)ivarObject(wave, "_barsView") layer];
		CALayer *bar = [[bars sublayers] firstObject];
		NSUInteger siblings = [[[bars superlayer] sublayers] count];
		if (layerOpaqueBlack(bars) && [bar compositingFilter] && [[bars sublayers] count] == 6 && siblings == 2) result += 10;
		waveForce = 1;
		[wave setNeedsLayout];
		[wave layoutIfNeeded];
		CALayer *colors = nil;
		for (CALayer *sibling in [[bars superlayer] sublayers]) if (sibling != bars) colors = sibling;
		if (![bars backgroundColor] && ![bar compositingFilter] && [colors mask]) result += 100;
		[wave setNeedsLayout];
		[wave layoutIfNeeded];
		if (![bars backgroundColor] && ![bar compositingFilter] && [colors mask]) result += 1000;
		waveForce = -1;
		[wave setNeedsLayout];
		[wave layoutIfNeeded];
		if (layerOpaqueBlack(bars) && [bar compositingFilter] && ![colors mask]) result += 10000;
		return result;
	}
}

static CGFloat testRadius = 4.5, testSeen;
static CGFloat testGetRadius(id self, SEL _cmd) { return testRadius; }
static void testSetRadius(id self, SEL _cmd, CGFloat radius) { testRadius = radius; }
static id testGeometry(id self, SEL _cmd) { return self; }
static void testRender(id self, SEL _cmd, id traits, BOOL allowCaching) { testSeen = testRadius; }

// Private self-test (host): 100 + tab bar hook installed + 10 key hook installed + 100 the draw sees the
// given radius and the old one is back afterwards + 1000 a plain call leaves the radius alone
int lgtabfix_selftest(const char *arg) {
	(void)arg;
	int result = 100 + (hookInstalled ? 1 : 0) + (keyHookInstalled ? 10 : 0);
	Class cls = objc_allocateClassPair([NSObject class], "LGTabFixTestTraits", 0);
	if (!cls) return result;
	class_addMethod(cls, sel_registerName("roundRectRadius"), (IMP)testGetRadius, "d@:");
	class_addMethod(cls, sel_registerName("setRoundRectRadius:"), (IMP)testSetRadius, "v@:d");
	class_addMethod(cls, sel_registerName("geometry"), (IMP)testGeometry, "@@:");
	objc_registerClassPair(cls);
	id traits = [[cls alloc] init];
	renderWithRadius(traits, sel_registerName("renderBackgroundTraits:allowCaching:"), traits, YES, (IMP)testRender, 17.92);
	if (fabs(testSeen - 17.92) < 0.001 && fabs(testRadius - 4.5) < 0.001) result += 100;
	renderWithRadius(traits, sel_registerName("renderBackgroundTraits:allowCaching:"), traits, YES, (IMP)testRender, -1.0);
	if (fabs(testSeen - 4.5) < 0.001 && fabs(testRadius - 4.5) < 0.001 && fileKeyRadius() < 0.0) result += 1000;
	return result;
}

// Private test with the real original (a test app with a bundle id that loads this library first, then the
// original): the radius from the settings file in hundredths, -100 = the draw would be left alone
int lgtabfix_keytest(const char *arg) {
	(void)arg;
	return (int)lround(fileKeyRadius() * 100.0);
}
