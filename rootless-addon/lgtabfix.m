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
#define BUILD_TAG "t2"
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

__attribute__((constructor)) static void lgtabfix_init(void) {
	if (access(CTLDIR "/disabled", F_OK) == 0) return;
	install();
	installKeyRadius();
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
