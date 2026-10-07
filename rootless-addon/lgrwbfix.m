// LiquidAssFixRenderer: add-on for the widget renderer (WidgetRenderer_Default / _CarPlay).
// Runtime style like lgfix.m: no @"" literals, no @implementation, no CFSTR (arm64e, on-device toolchain).
//
// The original LiquidAssRWB.dylib removes the widgets' own backgrounds inside these processes. Its
// constructor reads the tweak's preferences once and, when "Global.Enabled" does not come back true, returns
// before it installs a single hook or the reload observer. On iOS 17 the widgets are drawn by the sandboxed
// WidgetRenderer, and there the preferences daemon can answer with nothing for the tweak's domain: the
// widgets then keep their backgrounds (no glass) for the life of that process. Measured on an iPhone 15 Pro
// Max with iOS 17.3: the library was loaded with its enabled flag at 0 and no saved original
// implementations, while chronod and SpringBoard had both; the preferences file was readable.
//
// This library loads before the original (tweaks load in ascending name order). It reads the preferences
// file itself and sets those values for the tweak's domain inside this process, so the original's own read
// finds them and the original does its own work, unchanged. Nothing of the original is replaced or patched. (Patching the
// preferences function is not possible: the renderer is killed for it, OS_REASON_GUARD. Doing the
// original's hooks from here was tried and left widgets without their content.)
//
//
// One hook of its own, below the original's: a widget the host already shows without its background (render
// scheme background policy 2; LiquidAssFix asks for that on the widget page left of the home screen) has no
// background rect in its drawing. The original's rule "the second large rect is the background" then empties
// content instead, and the widget came out transparent and without text. For those draws the original's
// per-draw mark is taken off again, so its rule does not run; every other widget is left to the original.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-renderer-fix

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <notify.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define PREFS_FILE "/var/jb/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"
#define PREFS_DOMAIN "dylv.liquidassprefs"
#define RWB_NAME "LiquidAssRWB"
#define BUILD_TAG "r8"
#define MAX_PREFS_BYTES (512 * 1024)

#pragma mark - status log (a few lines per process start, in the process's own temporary directory)

static void rlog(const char *fmt, ...) {
	char path[1024];
	const char *dir = getenv("TMPDIR");
	if (!dir || !dir[0]) dir = "/tmp";
	snprintf(path, sizeof(path), "%s/lgfix-renderer.log", dir);
	struct stat st;
	if (stat(path, &st) == 0 && st.st_size > 16 * 1024) truncate(path, 0);
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

#pragma mark - preferences

// 1 = on, 0 = off, -1 = no value
static int boolState(CFTypeRef value) {
	if (!value) return -1;
	if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
	if (CFGetTypeID(value) == CFNumberGetTypeID()) {
		int number = 0;
		CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
		return number ? 1 : 0;
	}
	return -1;
}

static int globalEnabled(CFDictionaryRef dict) {
	if (!dict) return -1;
	CFStringRef key = CFStringCreateWithCString(NULL, "Global.Enabled", kCFStringEncodingUTF8);
	int state = boolState(CFDictionaryGetValue(dict, key));
	CFRelease(key);
	return state;
}

// The preferences file as a dictionary (caller releases), NULL when it cannot be read
static CFDictionaryRef copyPreferencesFile(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	UInt8 *buffer = malloc(MAX_PREFS_BYTES);
	size_t length = buffer ? fread(buffer, 1, MAX_PREFS_BYTES, f) : 0;
	fclose(f);
	CFPropertyListRef plist = NULL;
	if (length && length < MAX_PREFS_BYTES) {
		CFDataRef data = CFDataCreate(NULL, buffer, (CFIndex)length);
		if (data) {
			plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
			CFRelease(data);
		}
		if (plist && CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
			CFRelease(plist);
			plist = NULL;
		}
	}
	free(buffer);
	return plist;
}

// The read the original does (LGCopyPreferencesDictionary): keys that came back in *count,
// result = state of "Global.Enabled"
static int normalRead(long *count) {
	CFStringRef domain = CFStringCreateWithCString(NULL, PREFS_DOMAIN, kCFStringEncodingUTF8);
	CFPreferencesAppSynchronize(domain);
	CFDictionaryRef values = CFPreferencesCopyMultiple(NULL, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFRelease(domain);
	if (count) *count = values ? (long)CFDictionaryGetCount(values) : -1;
	int state = globalEnabled(values);
	if (values) CFRelease(values);
	return state;
}

// Makes the preferences system of this process hold exactly the file's values: the file's keys are set, keys
// it no longer has are removed. In the renderer this lands in a copy inside the process's own container; the
// real preferences file is not written. Returns the number of keys, -1 = no file
static long seedFromFile(void) {
	CFDictionaryRef file = copyPreferencesFile(PREFS_FILE);
	if (!file) return -1;
	long keys = (long)CFDictionaryGetCount(file);
	CFStringRef domain = CFStringCreateWithCString(NULL, PREFS_DOMAIN, kCFStringEncodingUTF8);
	CFMutableArrayRef gone = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFDictionaryRef held = CFPreferencesCopyMultiple(NULL, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFIndex heldCount = held ? CFDictionaryGetCount(held) : 0;
	if (heldCount > 0) {
		const void **names = malloc(sizeof(void *) * (size_t)heldCount);
		if (names) {
			CFDictionaryGetKeysAndValues(held, names, NULL);
			for (CFIndex i = 0; i < heldCount; i++)
				if (!CFDictionaryContainsKey(file, names[i])) CFArrayAppendValue(gone, names[i]);
			free(names);
		}
	}
	CFPreferencesSetMultiple(file, gone, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (held) CFRelease(held);
	CFRelease(gone);
	CFRelease(domain);
	CFRelease(file);
	return keys;
}

#pragma mark - state of the original library (for the status line only)

static BOOL rwbLoaded(void) {
	uint32_t count = _dyld_image_count();
	for (uint32_t i = 0; i < count; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name && strstr(name, RWB_NAME)) return YES;
	}
	return NO;
}

static BOOL impInRWB(const char *className, const char *selName) {
	Class cls = objc_getClass(className);
	if (!cls) return NO;
	Method method = class_getInstanceMethod(cls, sel_registerName(selName));
	if (!method) return NO;
	void *imp = ptrauth_strip((void *)method_getImplementation(method), ptrauth_key_function_pointer);
	Dl_info info;
	if (!imp || !dladdr(imp, &info) || !info.dli_fname) return NO;
	return strstr(info.dli_fname, RWB_NAME) != NULL;
}

// Another tweak hooking one of these later hides the original behind its own implementation: any hit counts
static BOOL rwbHooksInstalled(void) {
	return impInRWB("RBLayer", "display") || impInRWB("RBShape", "setRect:") ||
	       impInRWB("CHUISWidgetScene", "colorScheme") || impInRWB("CHSScreenshotPresentationAttributes", "colorScheme") ||
	       impInRWB("CHSMutableScreenshotPresentationAttributes", "colorScheme") ||
	       impInRWB("UIWindow", "initWithWindowScene:");
}

#pragma mark - widgets the host already shows without their background

// Replaces cls's method and hands back what to call in its place. A method the class only inherits gets an
// override that calls the inherited implementation.
static BOOL hookMethod(const char *className, const char *selName, IMP replacement, IMP *orig) {
	Class cls = objc_getClass(className);
	SEL sel = sel_registerName(selName);
	Method inherited = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!inherited) return NO;
	unsigned int count = 0;
	Method *own = class_copyMethodList(cls, &count);
	Method found = NULL;
	for (unsigned int i = 0; i < count; i++)
		if (method_getName(own[i]) == sel) found = own[i];
	free(own);
	if (found) {
		*orig = method_setImplementation(found, replacement);
	} else {
		*orig = method_getImplementation(inherited);
		if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(inherited))) return NO;
	}
	return YES;
}

static IMP sOrigLayerDisplay;
static NSString *sMarkKey;   // the original's per-draw mark in the thread dictionary
static BOOL sLoggedLeftAlone;

// YES when the scene this layer draws for has background policy 2
static BOOL hostLeavesBackgroundOut(id layer) {
	SEL delegateSel = sel_registerName("delegate"), windowSel = sel_registerName("window"), sceneSel = sel_registerName("windowScene");
	SEL schemeSel = sel_registerName("renderScheme"), policySel = sel_registerName("backgroundViewPolicy");
	if (![layer respondsToSelector:delegateSel]) return NO;
	id view = ((id (*)(id, SEL))objc_msgSend)(layer, delegateSel);
	if (!view || ![view respondsToSelector:windowSel]) return NO;
	id window = ((id (*)(id, SEL))objc_msgSend)(view, windowSel);
	if (!window || ![window respondsToSelector:sceneSel]) return NO;
	id scene = ((id (*)(id, SEL))objc_msgSend)(window, sceneSel);
	if (!scene || ![scene respondsToSelector:schemeSel]) return NO;
	id scheme = ((id (*)(id, SEL))objc_msgSend)(scene, schemeSel);
	if (!scheme || ![scheme respondsToSelector:policySel]) return NO;
	return ((unsigned long long (*)(id, SEL))objc_msgSend)(scheme, policySel) == 2;
}

// Runs inside the original's -[RBLayer display] (the original hooks after this library and calls this as its
// original implementation), i.e. after it has set its mark
static void layerDisplay(id self, SEL _cmd) {
	@try {
		NSMutableDictionary *thread = [[NSThread currentThread] threadDictionary];
		if (sMarkKey && [thread objectForKey:sMarkKey] && hostLeavesBackgroundOut(self)) {
			[thread removeObjectForKey:sMarkKey];
			if (!sLoggedLeftAlone) {
				sLoggedLeftAlone = YES;
				rlog("a widget the host shows without background is drawn untouched (logged once)");
			}
		}
	} @catch (id e) {}
	((void (*)(id, SEL))sOrigLayerDisplay)(self, _cmd);
}

#pragma mark - start

static BOOL sSeeded;

// The renderer's own read is not the tweak's real preferences (nothing, or the copy an earlier start left in
// the container), so the file's values are handed over at every start
static void seed(void) {
	BOOL originalFirst = rwbLoaded();
	long before = 0, after = 0;
	int state = normalRead(&before);
	long keys = seedFromFile();
	if (keys < 0) {
		rlog("the preferences file cannot be read (own read: %ld keys, tweak on=%d): left as it is", before, state);
		return;
	}
	sSeeded = YES;
	int seeded = normalRead(&after);
	rlog("own read gave %ld keys, tweak on=%d; %ld keys handed over from the file, the read now gives %ld keys, tweak on=%d%s",
	     before, state, keys, after, seeded, originalFirst ? "; the original was loaded BEFORE this, too late for it" : "");
}

static IMP sTestOrig;
static long testReplacement(id self, SEL _cmd) { return 7 + ((long (*)(id, SEL))sTestOrig)(self, _cmd); }
static long testBase(id self, SEL _cmd) { return 35; }

// For the private test host: reads the file only, the preferences system is not touched
__attribute__((visibility("default"))) int lgrwbfix_selftest(const char *path) {
	FILE *f = fopen(path, "w");
	if (!f) return -1;
	CFDictionaryRef file = copyPreferencesFile(PREFS_FILE);
	long keys = file ? (long)CFDictionaryGetCount(file) : -1;
	int state = globalEnabled(file);
	if (file) CFRelease(file);
	CFDictionaryRef none = copyPreferencesFile("/var/jb/nonexistent.plist");
	fprintf(f, "# preferences file keys=%ld tweak on=%d (want >0 and 1), missing file=%d (want 0), no dictionary=%d (want -1)\n",
	        keys, state, none != NULL, globalEnabled(NULL));
	fprintf(f, "# original library loaded=%d hooks=%d, impInRWB(NSObject description)=%d (want 0 0 0)\n", rwbLoaded(), rwbHooksInstalled(),
	        impInRWB("NSObject", "description"));
	// hook plumbing: a class with its own method, and a subclass that only inherits it
	Class base = objc_allocateClassPair([NSObject class], "LGRWBFixTestBase", 0);
	class_addMethod(base, sel_registerName("lgValue"), (IMP)testBase, "q@:");
	objc_registerClassPair(base);
	Class sub = objc_allocateClassPair(base, "LGRWBFixTestSub", 0);
	objc_registerClassPair(sub);
	BOOL h = hookMethod("LGRWBFixTestSub", "lgValue", (IMP)testReplacement, &sTestOrig);
	long subValue = ((long (*)(id, SEL))objc_msgSend)([[sub alloc] init], sel_registerName("lgValue"));
	long baseValue = ((long (*)(id, SEL))objc_msgSend)([[base alloc] init], sel_registerName("lgValue"));
	fprintf(f, "# inherited hook=%d sub=%ld base=%ld (want 1 42 35)\n", h, subValue, baseValue);
	// the policy check on objects that are no widget layer
	id plain = [[NSObject alloc] init];
	fprintf(f, "# policy check on a plain object=%d (want 0)\n", hostLeavesBackgroundOut(plain));
	fclose(f);
	return 100 + (keys > 0) + (state == 1) + (subValue == 42 ? 10 : 0);
}

__attribute__((constructor)) static void lgrwbfixInit(void) {
	if (getenv("LGFIX_SELFTEST")) return;
	if (access(CTLDIR "/disabled", F_OK) == 0 || access(CTLDIR "/no-renderer-fix", F_OK) == 0) return;
	if (strncmp(getprogname(), "WidgetRenderer", 14) != 0) return;
	seed();
	sMarkKey = [NSString stringWithUTF8String:"rwb_shouldHideBackground"];
	BOOL hooked = hookMethod("RBLayer", "display", (IMP)layerDisplay, &sOrigLayerDisplay);
	// After every constructor is through: did the original take up its work?
	dispatch_async(dispatch_get_main_queue(), ^{
		rlog("original loaded=%d, its background removal active=%d, own draw hook=%d", rwbLoaded(), rwbHooksInstalled(), hooked);
	});
	if (!sSeeded) return;
	// Settings changed while the process runs: hand the file's values over again
	int token = 0;
	notify_register_dispatch(PREFS_DOMAIN "/Reload", &token, dispatch_get_main_queue(), ^(int t) {
		seedFromFile();
	});
}
