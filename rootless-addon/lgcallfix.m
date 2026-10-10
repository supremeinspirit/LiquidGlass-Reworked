// LiquidAssFixCall: the Dynamic Island call wave fix of the Liquid (Gl)ass Reworked add-on, for InCallService only
// (filter: bundle com.apple.InCallService). Kept apart from LiquidAssFixApps on purpose: the phone call process
// gets nothing but these few lines. Runtime style (no @"" literals, no @implementation), see lgfix.m.
//
// Kill switches: /var/jb/usr/lib/LiquidAssFix/keep-callwave-frame or .../disabled

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define BUILD_TAG "c2"
#define PREFS_FILE "/var/jb/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"
#define KEY(name) ((const void *)sel_registerName(name))

#pragma mark - status log

static void tlog(const char *fmt, ...) {
	char path[1024];
	const char *dir = getenv("TMPDIR");
	if (!dir || !dir[0]) dir = "/tmp";
	snprintf(path, sizeof(path), "%s/lgfix-call.log", dir);
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

// Is the island drawn as glass? SpringBoard decides that; here only the same switches can be read from the
// settings file, at most every two seconds. A file that cannot be read leaves the view as it is.
static int glassAnswer = -1;
static CFAbsoluteTime glassAskedAt;
static BOOL islandGlassOn(void) {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (glassAnswer >= 0 && now - glassAskedAt < 2.0) return glassAnswer;
	glassAskedAt = now;
	int answer = 0;
	const char *why = "settings file not readable";
	if (access(CTLDIR "/disabled", F_OK) == 0) {
		why = "switched off by file";
	} else {
		NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:PREFS_FILE]];
		if (prefs) {
			answer = fileSwitch(prefs, "Global.Enabled", YES) && fileSwitch(prefs, "PillHUD.Enabled", NO)
			      && fileSwitch(prefs, "DynamicIsland.Enabled", YES);
			why = answer ? "island glass on" : "island glass off in the settings";
		}
	}
	if (answer != glassAnswer) tlog("call wave: %s", why);
	glassAnswer = answer;
	return answer;
}

#pragma mark - Dynamic Island call wave (InCallService)

// During a call the island's trailing side shows the call's audio waves: ConversationKit's
// SystemApertureInCallWaveformTrailingView, in a scene of InCallService. Its own layer has a 1 pt border, and
// besides the two wave views (green bars, drawn with plusL) it holds a backdrop layer (plusL, 55 %). On the black
// island neither shows; on the add-on's glass there was a dark box / frame behind the waves. While the island
// glass is on, the border's colour is made clear (the width stays) and every backdrop layer and every plain
// opaque black layer inside the view is left out with an empty mask; all put back when the glass goes off.
// Which of the two parts was the visible box was not separated; with both changes it is gone on iOS 17.3.
// On the first three layouts per process the view's layer tree is written as text to TMPDIR/lgfix-callwave.txt
// (classes, frames, colours, filters; no pixels). Kill switch: create /var/jb/usr/lib/LiquidAssFix/keep-callwave-frame

#define CALLWAVE_PROCESS "InCallService"
#define CALLWAVE_CLASS "ConversationKit.SystemApertureInCallWaveformTrailingView"

static IMP origCallWaveLayout;
static BOOL callWaveHookInstalled, callWaveLogged;
static int callWaveDumped;
static int callWaveInstallTries;
static int callWaveForce;           // self-test: 1 = glass on, -1 = glass off

static BOOL callWaveWanted(void) {
	if (callWaveForce) return callWaveForce > 0;
	if (access(CTLDIR "/keep-callwave-frame", F_OK) == 0) return NO;
	return islandGlassOn();
}

static void callWaveDumpLayerLine(FILE *f, CALayer *layer, int depth, BOOL recurse) {
	if (!layer || depth > 12) return;
	CGRect r = [layer frame];
	fprintf(f, "%*s%s (%s) %.1f,%.1f %.1fx%.1f op=%.2f", depth * 2, "", class_getName(object_getClass(layer)),
	        [layer delegate] ? class_getName(object_getClass([layer delegate])) : "-", r.origin.x, r.origin.y, r.size.width,
	        r.size.height, [layer opacity]);
	CGColorRef bg = [layer backgroundColor];
	if (bg) {
		const CGFloat *c = CGColorGetComponents(bg);
		size_t n = CGColorGetNumberOfComponents(bg);
		fprintf(f, " bg=");
		for (size_t i = 0; i < n; i++) fprintf(f, "%s%.2f", i ? "," : "", c[i]);
	}
	if ([layer borderWidth] > 0) {
		fprintf(f, " border=%.1f", [layer borderWidth]);
		CGColorRef bc = [layer borderColor];
		if (bc) {
			const CGFloat *c = CGColorGetComponents(bc);
			size_t n = CGColorGetNumberOfComponents(bc);
			fprintf(f, "/");
			for (size_t i = 0; i < n; i++) fprintf(f, "%s%.2f", i ? "," : "", c[i]);
		}
	}
	if ([layer masksToBounds]) fprintf(f, " clips");
	if ([layer cornerRadius] > 0) fprintf(f, " r=%.1f", [layer cornerRadius]);
	if ([layer compositingFilter]) fprintf(f, " comp=%s", [[[layer compositingFilter] description] UTF8String]);
	for (id filter in [layer filters]) {
		id type = [filter respondsToSelector:sel_registerName("type")] ? [filter valueForKey:[NSString stringWithUTF8String:"type"]] : filter;
		fprintf(f, " filter=%s", [[type description] UTF8String]);
	}
	if ([layer mask]) fprintf(f, " mask");
	if ([layer isHidden]) fprintf(f, " hidden");
	if ([layer contents]) fprintf(f, " contents");
	if ([layer shadowOpacity] > 0) fprintf(f, " shadow=%.2f/%.1f", [layer shadowOpacity], [layer shadowRadius]);
	fputc('\n', f);
	if (recurse)
		for (CALayer *sub in [layer sublayers]) callWaveDumpLayerLine(f, sub, depth + 1, YES);
}

static void callWaveDumpLayer(FILE *f, CALayer *layer, int depth) { callWaveDumpLayerLine(f, layer, depth, YES); }

// Written again on each of the first layouts that have a size (the very first one comes before the view has any)
static void callWaveDump(UIView *view) {
	if (callWaveDumped >= 3 || [view bounds].size.width < 1.0) return;
	char path[1024];
	const char *dir = getenv("TMPDIR");
	if (!dir || !dir[0]) dir = "/tmp";
	snprintf(path, sizeof(path), "%s/lgfix-callwave.txt", dir);
	FILE *f = fopen(path, callWaveDumped++ ? "a" : "w");
	if (!f) return;
	fprintf(f, "# [" BUILD_TAG "] %s[%d] call wave view, layout %d. Its superviews, nearest first (own layer only):\n", getprogname(),
	        getpid(), callWaveDumped);
	int depth = 0;
	UIView *top = view;
	for (UIView *v = [view superview]; v && depth < 8; v = [v superview], depth++) {
		callWaveDumpLayerLine(f, [v layer], 1, NO);
		if (depth < 2) top = v;
	}
	fprintf(f, "# tree of %s:\n", class_getName(object_getClass(top)));
	callWaveDumpLayer(f, [top layer], 0);
	fclose(f);
}

static BOOL layerTreeBlends(CALayer *layer, int depth) {
	if (!layer || depth > 8) return NO;
	if ([layer compositingFilter]) return YES;
	for (CALayer *sub in [layer sublayers])
		if (layerTreeBlends(sub, depth + 1)) return YES;
	return NO;
}

// Not a layer that has a mask already (that would be a shape shown through it) and not a black layer with
// shapes cut out of it (the waves themselves, as in the music wave)
static BOOL callWaveLeaveOut(CALayer *layer) {
	if ([layer mask]) return NO;
	const char *name = class_getName(object_getClass(layer));
	if (strstr(name, "Backdrop")) return YES;
	return layerOpaqueBlack(layer) && !layerTreeBlends(layer, 0);
}

static int callWaveSetClear(CALayer *layer, BOOL clear, int depth) {
	if (!layer || depth > 12) return 0;
	int changed = 0;
	CALayer *empty = objc_getAssociatedObject(layer, KEY("lgfix_callWaveMask"));
	if (clear && !empty && callWaveLeaveOut(layer)) {
		empty = [CALayer layer];
		[layer setMask:empty];
		objc_setAssociatedObject(layer, KEY("lgfix_callWaveMask"), empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		changed++;
	} else if (!clear && empty) {
		if ([layer mask] == empty) [layer setMask:nil];
		objc_setAssociatedObject(layer, KEY("lgfix_callWaveMask"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		changed++;
	}
	// a left-out layer hides its sublayers with it
	if (!(clear && empty))
		for (CALayer *sub in [layer sublayers]) changed += callWaveSetClear(sub, clear, depth + 1);
	return changed;
}

static void callWaveLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origCallWaveLayout)(self, _cmd);
	@try {
		if (!callWaveForce) callWaveDump(self);
		// the view's own layer is the island's content: only what lies inside it
		int changed = 0;
		BOOL clear = callWaveWanted();
		for (CALayer *sub in [[self layer] sublayers]) changed += callWaveSetClear(sub, clear, 1);
		// The view's own layer has a 1 pt border: unseen on the black island, a dark frame around the waves on
		// glass. Its colour is made clear (the width stays, in case the border is there to keep the layer drawn).
		CALayer *own = [self layer];
		id saved = objc_getAssociatedObject(own, KEY("lgfix_callWaveBorder"));
		if (clear && !saved && [own borderWidth] > 0 && [own borderColor] && CGColorGetAlpha([own borderColor]) > 0.01) {
			objc_setAssociatedObject(own, KEY("lgfix_callWaveBorder"), [UIColor colorWithCGColor:[own borderColor]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[own setBorderColor:[[UIColor clearColor] CGColor]];
			changed++;
			tlog("call wave: border of the wave view made clear (%.1f pt)", [own borderWidth]);
		} else if (clear && saved && [own borderColor] && CGColorGetAlpha([own borderColor]) > 0.01) {
			[own setBorderColor:[[UIColor clearColor] CGColor]];   // the view set it again
		} else if (!clear && saved) {
			[own setBorderColor:[(UIColor *)saved CGColor]];
			objc_setAssociatedObject(own, KEY("lgfix_callWaveBorder"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if (changed && clear && !callWaveLogged) {
			callWaveLogged = YES;
			tlog("call wave: %d layer(s) behind the waves left out (logged once)", changed);
		}
	} @catch (id e) {}
}

// ConversationKit is loaded by InCallService itself, maybe after this library: tried again for a while
static void installCallWave(void *force) {
	if (callWaveHookInstalled) return;
	if (!force && strcmp(getprogname(), CALLWAVE_PROCESS) != 0) return;
	Class cls = objc_getClass(CALLWAVE_CLASS);
	SEL sel = sel_registerName("layoutSubviews");
	Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!method) {
		if (++callWaveInstallTries <= 20)
			dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), force, installCallWave);
		return;
	}
	origCallWaveLayout = method_getImplementation(method);
	if (!class_addMethod(cls, sel, (IMP)callWaveLayout, method_getTypeEncoding(method)))
		origCallWaveLayout = method_setImplementation(method, (IMP)callWaveLayout);
	callWaveHookInstalled = YES;
	tlog("call wave: watching the call wave view");
}

__attribute__((constructor)) static void lgcallfix_init(void) {
	if (access(CTLDIR "/disabled", F_OK) == 0) return;
	installCallWave(NULL);
}

// Private self-test (host) for the call wave, with a stand-in class of the same name (the real view cannot be
// made outside a call): 1 hook in, 10 backdrop + plain black layer left out, 100 the black layer with cut-out
// shapes and the masked backdrop stay, 1000 everything back when the glass is off
int lgcallfix_selftest(const char *arg) {
	(void)arg;
	@autoreleasepool {
		int result = 0;
		Class cls = objc_getClass(CALLWAVE_CLASS);
		if (!cls) {
			cls = objc_allocateClassPair([UIView class], CALLWAVE_CLASS, 0);
			objc_registerClassPair(cls);
		}
		callWaveForce = -1;
		installCallWave((void *)1);
		if (callWaveHookInstalled) result += 1;
		UIView *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, 40, 24)];
		Class backdropClass = objc_getClass("CABackdropLayer");
		CALayer *backdrop = backdropClass ? [backdropClass layer] : [CALayer layer];
		CALayer *black = [CALayer layer], *cut = [CALayer layer], *bar = [CALayer layer], *shown = backdropClass ? [backdropClass layer] : [CALayer layer];
		[black setBackgroundColor:[[UIColor blackColor] CGColor]];
		[cut setBackgroundColor:[[UIColor blackColor] CGColor]];
		[bar setCompositingFilter:[NSString stringWithUTF8String:"destOut"]];
		[cut addSublayer:bar];
		[shown setMask:[CALayer layer]];
		[[view layer] addSublayer:backdrop]; [[view layer] addSublayer:black]; [[view layer] addSublayer:cut]; [[view layer] addSublayer:shown];
		[[view layer] setBorderWidth:1.0];
		[[view layer] setBorderColor:[[UIColor blackColor] CGColor]];
		callWaveForce = 1;
		[view setNeedsLayout]; [view layoutIfNeeded];
		if ([backdrop mask] && [black mask] && CGColorGetAlpha([[view layer] borderColor]) < 0.01) result += 10;
		if (![cut mask] && objc_getAssociatedObject(shown, KEY("lgfix_callWaveMask")) == nil) result += 100;
		callWaveForce = -1;
		[view setNeedsLayout]; [view layoutIfNeeded];
		if (![backdrop mask] && ![black mask] && [shown mask] && CGColorGetAlpha([[view layer] borderColor]) > 0.9) result += 1000;
		callWaveForce = 0;
		return result;
	}
}

