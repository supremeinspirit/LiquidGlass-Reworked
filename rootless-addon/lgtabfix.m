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
#define BUILD_TAG "t38"
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

static void tabSpecularSeen(UIView *bar);

static void tabBarLayout(UIView *self, SEL _cmd) {
	((void (*)(id, SEL))origLayout)(self, _cmd);
	if (![self window]) return;
	@try { tabSpecularSeen(self); } @catch (id e) {}
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

#pragma mark - tab bar selection motion

// The glass drop that follows the finger over the original's floating tab bar is moved by the original's
// LGTabBarMotionState, once per screen refresh (-tick:). There the drop runs a fixed fraction of the way to its
// target per frame, and its stretch comes from the finger's speed at the last touch report: the motion has kinks
// whenever the target jumps, and a drop that was stretched keeps that shape for as long as the finger rests.
//
// Here the same drop is moved like a soft body instead. Position, width and height each follow their target as
// a spring, stepped in small time slices, so the motion has no kinks and is the same at every refresh rate. The
// size follows the drop's own motion: wider and flatter the faster it travels, back with a small swing past its
// size when it stops (also when it first lifts off the bar), and taller when the finger pulls up or down away
// from the bar. It also leans towards the finger's height (at most 30 pt, so it never leaves the bar), and past
// the first and the last tab it follows the finger further out than the original lets it (at most 44 pt).
// The original still draws everything: before each of its ticks its numbers are set so that its
// own step lands exactly on the values computed here, and its targets, its arrival checks and its hand-over to
// the resting highlight stay as they are.
//
// Since t31 the drop's sizes follow reference pictures of the system's own glass tab bar: pressed and not
// travelling it is big and nearly round (narrower and taller than the original's lifted drop, standing out of
// the bar), a slow drag keeps that size, and the faster it travels the flatter and longer it gets; position,
// size and lean all swing a little past their goal when they change.
//
// Since t33 the release ends with a small swing: on its way into the resting pill behind the selected tab the
// shape runs a little past the pill's size and comes back, and the pill itself carries that swing on from the
// moment the original has put it in the drop's place.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-tabbar-motion (the original's motion)
// Without the swing of the resting pill after a release only: /var/jb/usr/lib/LiquidAssFix/no-tabbar-settle-bounce
//
// Since t35 the whole bar swings as well when it goes back from its pressed size: the original enlarges the bar
// by 3.5 % while a tab is held and lets it glide back in 0.26 s; now it runs a little below its size and comes
// back. Without that only: /var/jb/usr/lib/LiquidAssFix/no-tabbar-release-bounce
// The drop's sizes as before t31: /var/jb/usr/lib/LiquidAssFix/tabbar-drop-old-size
//
// Since t36 the drop keeps its size while it slides under the finger: the size goes by the speed evened out over
// about a twentieth of a second and only follows once that speed has really changed, and its spring swings less, so
// it swings when the size changes and stands still otherwise. As before (the size follows every change of the
// speed at once): /var/jb/usr/lib/LiquidAssFix/tabbar-drop-live-size
// Without the size change from the finger's height only: /var/jb/usr/lib/LiquidAssFix/no-tabbar-pull
// Without the lean towards the finger's height only: /var/jb/usr/lib/LiquidAssFix/no-tabbar-lean
// Without the longer way past the first and last tab only: /var/jb/usr/lib/LiquidAssFix/no-tabbar-reach
// Trial: /var/jb/usr/lib/LiquidAssFix/tabbar-120hz lets an app's own animations run at the screen's full
// refresh rate (the system holds them at 60 per second on the phone unless the app asks for more in its
// Info.plist); for the whole app, so off unless the file exists.

typedef struct {
	double x, vx, w, vw, h, vh;       // the drop as drawn, with its speeds
	double baseW, baseH;              // its size while lifted, from the original
	double shift, vshift;             // how far it leans up or down towards the finger
	double restY;                     // its centre's height in the bar without that
	double outX, outW, outH;          // what the original held after its last tick
	double lastTime;
	unsigned long generation;
	int valid, pending;
	int settling;                     // the drop was on its way into the resting pill at the last tick
	int frames;
	double framesFrom;
	double pace, paceHeld;            // the speed the size goes by under the finger: evened out, and as last taken
} TabMotion;

static IMP origMotionTick, origMotionStart;
static BOOL motionInstalled, motionRateLogged, motionLogged;
static __weak UIView *motionTouchBar;
static double motionTouchY, motionTouchX;
static BOOL motionTouching;
static IMP origButtonBegin, origButtonContinue, origButtonEnd, origButtonCancel;

static double motionGet(id object, const char *name) {
	return ((double (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static void motionSet(id object, const char *name, double value) {
	((void (*)(id, SEL, double))objc_msgSend)(object, sel_registerName(name), value);
}
static BOOL motionFlag(id object, const char *name) {
	return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}

// one spring, stepped in slices of at most 1/240 s
static void motionSpring(double *value, double *speed, double target, double response, double damping, double dt) {
	double omega = 2.0 * M_PI / response;
	while (dt > 1e-6) {
		double step = fmin(dt, 1.0 / 240.0);
		double acceleration = (target - *value) * omega * omega - 2.0 * damping * omega * (*speed);
		*speed += acceleration * step;
		*value += *speed * step;
		dt -= step;
	}
}

// The original's own size step (LGTabBarSpringStep, damping 1) from rest: the part of the distance to the target
// that is left after dt
static double motionOriginalSizeFactor(double response, double dt) {
	double current = 1.0, velocity = 0.0;
	double remaining = fmin(fmax(dt, 0.0), 1.0 / 30.0);
	while (remaining > 0.0) {
		double step = fmin(remaining, 1.0 / 120.0);
		double omega = 2.0 * M_PI / response;
		double acceleration = (0.0 - current) * omega * omega - 2.0 * omega * velocity;
		velocity += acceleration * step;
		current += velocity * step;
		remaining -= step;
	}
	return current;
}

static TabMotion *motionFor(id state) {
	NSMutableData *data = objc_getAssociatedObject(state, KEY("lgtabfix_motion"));
	if (!data) {
		data = [NSMutableData dataWithLength:sizeof(TabMotion)];
		objc_setAssociatedObject(state, KEY("lgtabfix_motion"), data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return (TabMotion *)[data mutableBytes];
}

// The lifted drop against the original's (94x72 in a five-tab bar): standing still MOTION_PRESS_W wider and
// MOTION_PRESS_H taller; at full speed another MOTION_FAST_W wider and MOTION_FAST_H flatter. From the reference
// pictures: fast about 132x53. The pressed size was set again in t32 from a screenshot of this drop beside the
// reference, both measured against their bar's height: the reference drop is 1.44 bar heights wide and 1.28
// high, ours was 1.33 and 1.18 (88x78), so it is now 94x85.
// Since t38 the held and slowly dragged drop is taller only (94x92, was 94x85), and the fast one flatter (about
// 132x46, was 132x53).
#define MOTION_PRESS_W 0.0
#define MOTION_PRESS_H 20.0
#define MOTION_FAST_W 38.0
#define MOTION_FAST_H 46.0
#define MOTION_SLOW_SPEED 45.0      // pt per second up to which the drop keeps its pressed size
#define MOTION_FULL_SPEED 800.0
#define MOTION_PACE_TIME 0.05       // seconds over which the speed is evened out before the size goes by it
#define MOTION_PACE_HOLD 0.18       // part of the speed range the evened speed may wander without a new size
#define MOTION_STEADY_DAMPING 0.50  // the size spring under the finger (0.40 before t36)
static int motionOldSize = -1, motionLiveSize = -1;

// The speed (0 to 1) the drop's size goes by while it slides under the finger: evened out, and held until it has
// moved away from the last one taken by more than the hold, which gets smaller towards standing still and full
// speed so that both ends are still reached.
static double motionPace(TabMotion *m, double speed, double dt) {
	m->pace += (speed - m->pace) * (1.0 - exp(-dt / MOTION_PACE_TIME));
	double hold = MOTION_PACE_HOLD * fmin(fmin(m->pace, 1.0 - m->pace) / 0.25, 1.0);
	if (hold < 0.0) hold = 0.0;
	m->paceHeld = fmin(fmax(m->paceHeld, m->pace - hold), m->pace + hold);
	return m->paceHeld;
}

static double motionRestY;         // the drop's centre height in the bar, as the original last placed it

// height added by a finger that left the bar upwards or downwards
static double motionPull(UIView *bar, UIView *lens) {
	if (!motionTouching || motionTouchBar != bar || access(CTLDIR "/no-tabbar-pull", F_OK) == 0) return 0.0;
	double away = fabs(motionTouchY - motionRestY) - 26.0;
	if (away <= 0.0) return 0.0;
	return 14.0 * (1.0 - exp(-away / 60.0));
}

// Where the drop is to go while it is under the finger: between the first and the last tab the original's target;
// a finger further out pulls it past them, by 3.4 times the square root of the finger's distance, at most
// MOTION_REACH_MAX (the original: 1.24 times the root).
#define MOTION_REACH_MAX 44.0
static double motionReach(UIView *bar, double targetX) {
	if (!motionTouching || motionTouchBar != bar || access(CTLDIR "/no-tabbar-reach", F_OK) == 0) return targetX;
	Class buttonClass = objc_getClass("UITabBarButton");
	if (!buttonClass) return targetX;
	double first = 0.0, last = 0.0;
	int count = 0;
	for (UIView *view in [bar subviews]) {
		if (![view isKindOfClass:buttonClass]) continue;
		double middle = CGRectGetMidX([view frame]);
		if (count == 0 || middle < first) first = middle;
		if (count == 0 || middle > last) last = middle;
		count++;
	}
	if (count < 1) return targetX;
	if (motionTouchX > last) return last + fmin(3.4 * sqrt(motionTouchX - last), MOTION_REACH_MAX);
	if (motionTouchX < first) return first - fmin(3.4 * sqrt(first - motionTouchX), MOTION_REACH_MAX);
	return targetX;
}

// The resting pill behind the selected tab, as the original leaves it when the drop is gone: a plain rounded view
// of the bar with the given size at the given place.
static UIView *motionRestingPill(UIView *bar, UIView *lens, double x, double w, double h) {
	for (UIView *view in [bar subviews]) {
		if (view == lens || [view class] != [UIView class] || [view isHidden] || [view maskView]) continue;
		CALayer *layer = [view layer];
		CGRect bounds = [view bounds];
		if (![layer masksToBounds] || ![view backgroundColor]) continue;
		if (fabs(bounds.size.width - w) > 1.0 || fabs(bounds.size.height - h) > 1.0 || fabs([view center].x - x) > 2.0) continue;
		if (fabs([layer cornerRadius] - h * 0.5) > 1.0) continue;
		return view;
	}
	return nil;
}

// The drop's way into the resting pill: a spring that runs past the pill's size and comes back
#define MOTION_SETTLE_RESPONSE 0.32
#define MOTION_SETTLE_DAMPING 0.34
static int motionNoSettleBounce = -1;
static BOOL motionSettleLogged;

// The original has just replaced the drop by the resting pill, at the pill's exact size. The drop was still
// swinging: the pill goes on from the drop's size and speed and comes to rest (drawn by Core Animation on top of
// the pill's own size, which stays untouched).
static void motionSettleBounce(id state, TabMotion *m) {
	if (motionNoSettleBounce) return;
	UIView *lens = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("lens"));
	UIView *bar = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("bar"));
	if (!bar) return;
	double restX = motionGet(state, "targetCenterX"), restW = motionGet(state, "targetWidth"), restH = motionGet(state, "targetHeight");
	if (!isfinite(restX) || !isfinite(restW) || !isfinite(restH) || restW < 20.0 || restH < 20.0) return;
	double offW = fmin(fmax(m->w - restW, -24.0), 24.0), offH = fmin(fmax(m->h - restH, -24.0), 24.0);
	double speedW = fmin(fmax(m->vw, -900.0), 900.0), speedH = fmin(fmax(m->vh, -900.0), 900.0);
	if (fabs(offW) < 0.3 && fabs(offH) < 0.3 && fabs(speedW) < 8.0 && fabs(speedH) < 8.0) return;
	UIView *pill = motionRestingPill(bar, lens, restX, restW, restH);
	if (!pill) return;
	const int count = 48;
	NSMutableArray *widths = [NSMutableArray arrayWithCapacity:count + 1], *heights = [NSMutableArray arrayWithCapacity:count + 1];
	NSMutableArray *radii = [NSMutableArray arrayWithCapacity:count + 1];
	double firstW = offW, firstH = offH;
	for (int i = 0; i <= count; i++) {
		double w = i == count ? 0.0 : offW, h = i == count ? 0.0 : offH;
		[widths addObject:[NSNumber numberWithDouble:w]];
		[heights addObject:[NSNumber numberWithDouble:h]];
		[radii addObject:[NSNumber numberWithDouble:h * 0.5]];
		motionSpring(&offW, &speedW, 0.0, MOTION_SETTLE_RESPONSE, MOTION_SETTLE_DAMPING, 1.0 / 60.0);
		motionSpring(&offH, &speedH, 0.0, MOTION_SETTLE_RESPONSE, MOTION_SETTLE_DAMPING, 1.0 / 60.0);
	}
	static const char *paths[] = { "bounds.size.width", "bounds.size.height", "cornerRadius" };
	static const char *keys[] = { "lgtabfixSettleWidth", "lgtabfixSettleHeight", "lgtabfixSettleRadius" };
	NSArray *values[3];
	values[0] = widths; values[1] = heights; values[2] = radii;
	for (int i = 0; i < 3; i++) {
		CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:[NSString stringWithUTF8String:paths[i]]];
		[animation setValues:values[i]];
		[animation setDuration:count / 60.0];
		[animation setAdditive:YES];
		[[pill layer] addAnimation:animation forKey:[NSString stringWithUTF8String:keys[i]]];
	}
	if (!motionSettleLogged) {
		motionSettleLogged = YES;
		tlog("tab bar: the resting pill swings on after the release (from %+.1f x %+.1f pt off its size; logged once)", firstW, firstH);
	}
}

// Sets the original's numbers so that its step ends on the drop computed here. Returns NO to leave the tick alone.
static BOOL motionPrepare(id state, id link) {
	UIView *lens = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("lens"));
	UIView *bar = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("bar"));
	if (!lens || !bar || [lens isHidden]) return NO;
	double renderedX = motionGet(state, "renderedCenterX"), renderedW = motionGet(state, "renderedWidth"), renderedH = motionGet(state, "renderedHeight");
	double targetX = motionGet(state, "targetCenterX"), targetW = motionGet(state, "targetWidth"), targetH = motionGet(state, "targetHeight");
	BOOL active = motionFlag(state, "active"), flying = motionFlag(state, "awaitingTapDestination");
	BOOL settling = motionFlag(state, "awaitingRestingShape"), dragged = motionFlag(state, "dragged");
	unsigned long generation = ((unsigned long (*)(id, SEL))objc_msgSend)(state, sel_registerName("generation"));
	double last = motionGet(state, "lastDisplayTime");
	double now = ((double (*)(id, SEL))objc_msgSend)(link, sel_registerName("timestamp"));
	if (!isfinite(renderedX) || !isfinite(renderedW) || !isfinite(renderedH) || !isfinite(targetX) || !isfinite(targetW) || !isfinite(targetH)) return NO;

	TabMotion *m = motionFor(state);
	BOOL fresh = !m->valid || m->generation != generation;
	BOOL moved = fabs(renderedX - m->outX) > 0.01 || fabs(renderedW - m->outW) > 0.01 || fabs(renderedH - m->outH) > 0.01;
	BOOL stale = now - m->lastTime > 0.25 || now < m->lastTime;
	double dt = 1.0 / 60.0;
	if (fresh || moved || stale) {
		// the original set the drop itself (a new touch, or a stop in between): taken over from there, at rest
		m->x = renderedX; m->w = renderedW; m->h = renderedH;
		m->vx = m->vw = m->vh = 0.0;
		if (fresh) m->shift = m->vshift = 0.0;
		if (fresh) m->pace = m->paceHeld = 0.0;
		if (fresh && !settling && targetW >= 40.0 && targetW <= 220.0 && targetH >= 30.0 && targetH <= 140.0) {
			m->baseW = targetW;
			m->baseH = targetH;
		}
		m->generation = generation;
		m->valid = 1;
		m->frames = 0;
	} else {
		dt = fmin(fmax(now - m->lastTime, 1.0 / 240.0), 1.0 / 20.0);
	}
	if (m->baseW <= 0.0 || m->baseH <= 0.0) return NO;

	double wantW = targetW, wantH = targetH;
	double responseX = 0.22, dampingX = 1.0, responseSize = 0.20, dampingSize = 1.0;
	if (motionNoSettleBounce < 0) motionNoSettleBounce = access(CTLDIR "/no-tabbar-settle-bounce", F_OK) == 0;
	m->settling = settling;
	if (settling && !motionNoSettleBounce) {
		responseSize = MOTION_SETTLE_RESPONSE;
		dampingSize = MOTION_SETTLE_DAMPING;
	}
	if (!settling) {
		// lifted: flatter and wider with its own speed, taller with the finger's distance from the bar
		if (motionOldSize < 0) motionOldSize = access(CTLDIR "/tabbar-drop-old-size", F_OK) == 0;
		double pull = motionPull(bar, lens);
		if (motionOldSize) {
			double speed = fmin(fabs(m->vx) / 1000.0, 1.0);
			speed = pow(speed, 0.8);
			wantW = m->baseW + 24.0 * speed - 0.35 * pull;
			wantH = m->baseH - 14.0 * speed + pull;
			if (flying || !dragged) { responseX = 0.26; dampingX = 0.85; }      // on its way to a tapped tab
			else                    { responseX = 0.13; dampingX = 0.92; }      // under the finger
			responseSize = 0.26;
			dampingSize = 0.45;
		} else {
			double speed = fmin(fmax((fabs(m->vx) - MOTION_SLOW_SPEED) / (MOTION_FULL_SPEED - MOTION_SLOW_SPEED), 0.0), 1.0);
			speed = pow(speed, 0.85);
			if (motionLiveSize < 0) motionLiveSize = access(CTLDIR "/tabbar-drop-live-size", F_OK) == 0;
			// under the finger the size keeps still while the speed only wavers; a flying drop goes by its speed
			// as it is (the original waits for its exact size at the end)
			BOOL steady = !motionLiveSize && !flying && dragged;
			if (steady) speed = motionPace(m, speed, dt);
			else m->pace = m->paceHeld = speed;
			// on its way to a tapped tab the drop ends in the original's own lifted size: the original waits for
			// exactly that size before it lets the drop settle on the tab
			double press = flying ? fmin(fabs(targetX - m->x) / 40.0, 1.0) : 1.0;
			wantW = m->baseW + MOTION_PRESS_W * press + MOTION_FAST_W * speed - 0.35 * pull;
			wantH = m->baseH + MOTION_PRESS_H * press - MOTION_FAST_H * speed + pull;
			if (flying || !dragged) { responseX = 0.28; dampingX = 0.72; }      // on its way to a tapped tab
			else                    { responseX = 0.15; dampingX = 0.78; }      // under the finger
			responseSize = 0.28;
			dampingSize = steady ? MOTION_STEADY_DAMPING : 0.40;
		}
	}
	double goalX = !settling && !flying && active && dragged ? motionReach(bar, targetX) : targetX;
	motionSpring(&m->x, &m->vx, goalX, responseX, dampingX, dt);
	motionSpring(&m->w, &m->vw, wantW, responseSize, dampingSize, dt);
	motionSpring(&m->h, &m->vh, wantH, responseSize, dampingSize, dt);
	if (!isfinite(m->x) || !isfinite(m->w) || !isfinite(m->h) || !isfinite(m->vx) || !isfinite(m->vw) || !isfinite(m->vh)) {
		m->valid = 0;
		return NO;
	}
	m->w = fmin(fmax(m->w, 20.0), 260.0);
	m->h = fmin(fmax(m->h, 20.0), 110.0);

	// the original's step, backwards: where its numbers have to stand so that it ends on m->x / m->w / m->h
	double originalDt = last > 0.0 ? now - last : 1.0 / 60.0;
	if (originalDt > 1.0 / 30.0) originalDt = 1.0 / 30.0;
	double frameFactor = fmin(fmax(originalDt * 60.0, 0.35), 1.4);
	double lerp = (active ? 0.21 : 0.14) * frameFactor;
	double sizeFactor = motionOriginalSizeFactor(active ? 0.155 : 0.135, originalDt);
	if (lerp >= 0.9 || sizeFactor < 0.05) return NO;
	motionSet(state, "setRenderedCenterX:", (m->x - targetX * lerp) / (1.0 - lerp));
	motionSet(state, "setRenderedWidth:", targetW + (m->w - targetW) / sizeFactor);
	motionSet(state, "setRenderedHeight:", targetH + (m->h - targetH) / sizeFactor);
	motionSet(state, "setWidthVelocity:", 0.0);
	motionSet(state, "setHeightVelocity:", 0.0);
	m->lastTime = now;
	m->pending = 1;

	// how often the drop is drawn: one line per process
	if (!motionRateLogged && active && dragged) {
		if (m->frames == 0) m->framesFrom = now;
		if (++m->frames == 41) {
			motionRateLogged = YES;
			double span = now - m->framesFrom;
			if (span > 0.0) tlog("tab bar: the selection drop is drawn %.0f times per second in this app (logged once)", 40.0 / span);
		}
	}
	return YES;
}

// After the original placed the drop on the bar's middle line: moved up or down a little, towards the finger.
// The coloured copy of the icons under the drop (a view of the bar with a mask view the original moves with the
// drop) is moved along.
#define MOTION_LEAN_MAX 30.0
static void motionLean(id state, TabMotion *m) {
	UIView *lens = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("lens"));
	UIView *bar = ((id (*)(id, SEL))objc_msgSend)(state, sel_registerName("bar"));
	if (!lens || !bar || [lens isHidden] || access(CTLDIR "/no-tabbar-lean", F_OK) == 0) { m->shift = m->vshift = 0.0; return; }
	CGPoint centre = [lens center];
	m->restY = centre.y;
	motionRestY = centre.y;
	BOOL settling = motionFlag(state, "awaitingRestingShape"), flying = motionFlag(state, "awaitingTapDestination");
	double want = 0.0;
	if (!settling && !flying && motionTouching && motionTouchBar == bar)
		want = MOTION_LEAN_MAX * tanh((motionTouchY - centre.y) / 85.0);
	if (motionOldSize > 0) motionSpring(&m->shift, &m->vshift, want, want == 0.0 ? 0.16 : 0.20, want == 0.0 ? 1.0 : 0.75, 1.0 / 60.0);
	else motionSpring(&m->shift, &m->vshift, want, want == 0.0 ? 0.22 : 0.22, want == 0.0 ? 0.55 : 0.60, 1.0 / 60.0);
	if (!isfinite(m->shift) || !isfinite(m->vshift)) { m->shift = m->vshift = 0.0; return; }
	m->shift = fmin(fmax(m->shift, -MOTION_LEAN_MAX - 4.0), MOTION_LEAN_MAX + 4.0);
	if (fabs(m->shift) < 0.05) return;
	[lens setCenter:CGPointMake(centre.x, centre.y + m->shift)];
	for (UIView *view in [bar subviews]) {
		UIView *mask = [view maskView];
		if (!mask || view == lens || ![view clipsToBounds]) continue;
		CGRect frame = [mask frame];
		frame.origin.y += m->shift;
		[mask setFrame:frame];
	}
}

static void motionTick(id self, SEL _cmd, id link) {
	BOOL mine = NO;
	@try { mine = motionPrepare(self, link); } @catch (id e) { mine = NO; }
	((void (*)(id, SEL, id))origMotionTick)(self, _cmd, link);
	if (!mine) return;
	@try {
		TabMotion *m = motionFor(self);
		m->pending = 0;
		m->outX = motionGet(self, "renderedCenterX");
		m->outW = motionGet(self, "renderedWidth");
		m->outH = motionGet(self, "renderedHeight");
		if (m->settling && !motionFlag(self, "awaitingRestingShape")) {
			m->settling = 0;
			motionSettleBounce(self, m);
		}
		motionLean(self, m);
		if (!motionLogged) {
			motionLogged = YES;
			tlog("tab bar: selection drop moved by the add-on (drop %.0fx%.0f; logged once)", m->baseW, m->baseH);
		}
	} @catch (id e) {}
}

// the drop's timer may run at the screen's full rate where the app is allowed to
static void motionStart(id self, SEL _cmd) {
	((void (*)(id, SEL))origMotionStart)(self, _cmd);
	@try {
		id link = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("displayLink"));
		SEL rangeSel = sel_registerName("setPreferredFrameRateRange:");
		if (link && [link respondsToSelector:rangeSel] && !objc_getAssociatedObject(link, KEY("lgtabfix_rate"))) {
			CAFrameRateRange range = CAFrameRateRangeMake(80.0f, 120.0f, 120.0f);
			((void (*)(id, SEL, CAFrameRateRange))objc_msgSend)(link, rangeSel, range);
			objc_setAssociatedObject(link, KEY("lgtabfix_rate"), [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
	} @catch (id e) {}
}

static Method motionOwnMethod(Class cls, SEL sel) {
	unsigned int count = 0;
	Method *own = class_copyMethodList(cls, &count);
	Method found = NULL;
	for (unsigned int i = 0; i < count; i++)
		if (method_getName(own[i]) == sel) found = own[i];
	free(own);
	return found;
}

// The original's class exists once the original is loaded (after this library): looked for at the first touch
static void installMotion(void) {
	if (motionInstalled) return;
	Class cls = objc_getClass("LGTabBarMotionState");
	if (!cls) return;
	motionInstalled = YES;
	if (access(CTLDIR "/no-tabbar-motion", F_OK) == 0) return;
	static const char *needed[] = { "lens", "bar", "displayLink", "active", "dragged", "generation", "awaitingTapDestination",
		"awaitingRestingShape", "lastDisplayTime", "targetCenterX", "targetWidth", "targetHeight", "renderedCenterX", "renderedWidth",
		"renderedHeight", "setRenderedCenterX:", "setRenderedWidth:", "setRenderedHeight:", "setWidthVelocity:", "setHeightVelocity:" };
	for (unsigned int i = 0; i < sizeof(needed) / sizeof(needed[0]); i++)
		if (!class_getInstanceMethod(cls, sel_registerName(needed[i]))) {
			tlog("tab bar: the original's motion has no '%s' here, left as it is", needed[i]);
			return;
		}
	Method tick = motionOwnMethod(cls, sel_registerName("tick:")), start = motionOwnMethod(cls, sel_registerName("start"));
	if (!tick || !start) return;
	origMotionStart = method_setImplementation(start, (IMP)motionStart);
	origMotionTick = method_setImplementation(tick, (IMP)motionTick);
}

static UIView *motionBarOf(UIView *button) {
	Class barClass = [UITabBar class];
	for (UIView *view = [button superview]; view; view = [view superview])
		if ([view isKindOfClass:barClass]) return view;
	return nil;
}

static void motionNoteTouch(UIView *button, UITouch *touch, BOOL down) {
	@try {
		UIView *bar = down && touch ? motionBarOf(button) : nil;
		if (!bar) { motionTouching = NO; return; }
		motionTouchBar = bar;
		CGPoint point = [touch locationInView:bar];
		motionTouchY = point.y;
		motionTouchX = point.x;
		motionTouching = YES;
	} @catch (id e) { motionTouching = NO; }
}

// How large the original draws the bar right now (1 at rest, up to 1.035 while a tab is held): read from the
// bar's glass as it stands on screen
static double motionBarScale(UIView *bar) {
	Class glassClass = objc_getClass("LGLiveBackdropView");
	if (!glassClass || !bar) return 1.0;
	double barWidth = [bar bounds].size.width;
	for (UIView *view in [bar subviews]) {
		if (![view isKindOfClass:glassClass] || [view isHidden] || [view bounds].size.width < barWidth * 0.5) continue;
		CALayer *shown = [[view layer] presentationLayer] ?: [view layer];
		double scale = [shown transform].m11;
		return isfinite(scale) ? scale : 1.0;
	}
	return 1.0;
}

// UIKit's ease-out curve (control points 0,0 / 0.58,1): the part of the way done after the part `u` of the time
static double motionEaseOut(double u) {
	if (u <= 0.0) return 0.0;
	if (u >= 1.0) return 1.0;
	double low = 0.0, high = 1.0, t = u;
	for (int i = 0; i < 40; i++) {
		t = (low + high) * 0.5;
		double x = 3.0 * (1.0 - t) * t * t * 0.58 + t * t * t;
		if (x < u) low = t; else high = t;
	}
	return 3.0 * (1.0 - t) * t * t + t * t * t;
}

// The bar on its way back from the size `scale` to 1: the original lets it glide there in 0.26 s. Laid on top of
// that (Core Animation adds it to what the original animates, nothing of the original's is changed) is the
// difference to a spring that starts at the same size, runs below 1 and comes back.
#define MOTION_BAR_RESPONSE 0.38
#define MOTION_BAR_DAMPING 0.35
static int motionNoBarBounce = -1;
static BOOL motionBarLogged;
static void motionBarBounce(UIView *bar, double scale) {
	if (motionNoBarBounce < 0) motionNoBarBounce = access(CTLDIR "/no-tabbar-release-bounce", F_OK) == 0;
	double extra = scale - 1.0;
	if (motionNoBarBounce || !bar || !isfinite(extra) || extra < 0.004 || extra > 0.2) return;
	const int count = 60;
	NSMutableArray *values = [NSMutableArray arrayWithCapacity:count + 1];
	double spring = 1.0, speed = 0.0;
	for (int i = 0; i <= count; i++) {
		double glide = 1.0 - motionEaseOut((i / 60.0) / 0.26);
		[values addObject:[NSNumber numberWithDouble:i == count ? 0.0 : extra * (spring - glide)]];
		motionSpring(&spring, &speed, 0.0, MOTION_BAR_RESPONSE, MOTION_BAR_DAMPING, 1.0 / 60.0);
	}
	static const char *paths[] = { "transform.scale.x", "transform.scale.y" };
	static const char *keys[] = { "lgtabfixBarBounceX", "lgtabfixBarBounceY" };
	for (int i = 0; i < 2; i++) {
		CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:[NSString stringWithUTF8String:paths[i]]];
		[animation setValues:values];
		[animation setDuration:count / 60.0];
		[animation setAdditive:YES];
		[[bar layer] addAnimation:animation forKey:[NSString stringWithUTF8String:keys[i]]];
	}
	if (!motionBarLogged) {
		motionBarLogged = YES;
		tlog("tab bar: the bar swings back from %.3f times its size after the release (logged once)", scale);
	}
}
static void motionBarBounceStop(UIView *bar) {
	if (!bar) return;
	[[bar layer] removeAnimationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceX"]];
	[[bar layer] removeAnimationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceY"]];
}

static BOOL buttonBegin(UIView *self, SEL _cmd, UITouch *touch, UIEvent *event) {
	installMotion();
	motionNoteTouch(self, touch, YES);
	@try { motionBarBounceStop(motionBarOf(self)); } @catch (id e) {}
	return ((BOOL (*)(id, SEL, id, id))origButtonBegin)(self, _cmd, touch, event);
}
static BOOL buttonContinue(UIView *self, SEL _cmd, UITouch *touch, UIEvent *event) {
	motionNoteTouch(self, touch, YES);
	return ((BOOL (*)(id, SEL, id, id))origButtonContinue)(self, _cmd, touch, event);
}
static void buttonEnd(UIView *self, SEL _cmd, UITouch *touch, UIEvent *event) {
	motionTouching = NO;
	UIView *bar = nil;
	double scale = 1.0;
	@try { bar = motionBarOf(self); scale = motionBarScale(bar); } @catch (id e) { bar = nil; }
	((void (*)(id, SEL, id, id))origButtonEnd)(self, _cmd, touch, event);
	@try { motionBarBounce(bar, scale); } @catch (id e) {}
}
static void buttonCancel(UIView *self, SEL _cmd, UIEvent *event) {
	motionTouching = NO;
	UIView *bar = nil;
	double scale = 1.0;
	@try { bar = motionBarOf(self); scale = motionBarScale(bar); } @catch (id e) { bar = nil; }
	((void (*)(id, SEL, id))origButtonCancel)(self, _cmd, event);
	@try { motionBarBounce(bar, scale); } @catch (id e) {}
}

// the class's own method is replaced; one it only inherits gets an own method that calls the inherited one
static IMP motionHook(Class cls, const char *name, IMP mine) {
	SEL sel = sel_registerName(name);
	Method method = class_getInstanceMethod(cls, sel);
	if (!method) return NULL;
	IMP before = method_getImplementation(method);
	if (!class_addMethod(cls, sel, mine, method_getTypeEncoding(method)))
		before = method_setImplementation(method, mine);
	return before;
}

static void installMotionTouches(void) {
	if (origButtonBegin || access(CTLDIR "/no-tabbar-motion", F_OK) == 0) return;
	Class cls = objc_getClass("UITabBarButton");
	if (!cls || ![cls isSubclassOfClass:[UIControl class]]) return;
	Class control = [UIControl class];
	static const char *tracking[] = { "beginTrackingWithTouch:withEvent:", "continueTrackingWithTouch:withEvent:",
		"endTrackingWithTouch:withEvent:", "cancelTrackingWithEvent:" };
	for (int i = 0; i < 4; i++)
		if (!class_getInstanceMethod(control, sel_registerName(tracking[i]))) return;
	origButtonBegin = motionHook(cls, "beginTrackingWithTouch:withEvent:", (IMP)buttonBegin);
	origButtonContinue = motionHook(cls, "continueTrackingWithTouch:withEvent:", (IMP)buttonContinue);
	origButtonEnd = motionHook(cls, "endTrackingWithTouch:withEvent:", (IMP)buttonEnd);
	origButtonCancel = motionHook(cls, "cancelTrackingWithEvent:", (IMP)buttonCancel);
	if (access(CTLDIR "/tabbar-120hz", F_OK) == 0) {
		@try {
			id info = [[NSBundle mainBundle] infoDictionary];
			if ([info respondsToSelector:@selector(setObject:forKey:)])
				[(NSMutableDictionary *)info setObject:[NSNumber numberWithBool:YES]
				                               forKey:[NSString stringWithUTF8String:"CADisableMinimumFrameDurationOnPhone"]];
		} @catch (id e) {}
	}
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
#define FIELD_HOST_BLUR_DEFAULT 0.0   // the Spotlight bar's blur when none was set
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
// a glass of the original lies in its place, under the field's text. It is the glass of the Spotlight search
// bar (host "Spotlight": its rim, refraction, blur and tints, as set on the "Spotlight Search Bar" page) in the
// Spotlight bar's shape, a full pill. On when the tweak is on; "SearchField.Enabled" = false in the settings
// switches it off. Own values, only when they were set: "SearchField.Blur" (in place of the Spotlight bar's
// blur) and "SearchField.TintColor" (a colour laid over the glass).
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-searchfield-glass
// The look before (Search Pill glass, the field's own corner radius, blur 5):
// create /var/jb/usr/lib/LiquidAssFix/searchfield-old-style

#define FIELD_HOST "Spotlight"
#define FIELD_HOST_OLD "SearchPill"
static BOOL fieldOldStyle;
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

// Moving highlight: the original turns the light edge of its glasses with the phone's tilt ("Specular Motion"),
// but only inside SpringBoard; in apps the edge stands still. For the text bars the same is done here: while
// that setting is on, a text bar glass is on screen and the app is in front, the tilt is read 30 times a second
// and the bars' light edge is turned by the original's own rule (-applySpecularAngle:). Stops by itself when no
// bar is visible or the app leaves the front.
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-searchfield-motion
static BOOL fieldMotionOn;
static double fieldMotionSensitivity = 2.0;
static id fieldMotionManager;
static dispatch_source_t fieldMotionTimer;
static double fieldMotionAngle = -M_PI_4, fieldMotionApplied = -100.0;
static int fieldMotionIdle, fieldMotionTicks;
static BOOL fieldMotionLogged, fieldMotionObserving;

// The same for the glass of the original's floating tab bar: its light edge stood still in every app as well.
// A bar that carries the glass is noted at its layout and its edge is turned together with the text bars',
// by the same timer and under the same conditions (setting on, bar on screen, app in front).
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-tabbar-specular-motion
static NSHashTable *tabGlassBars;               // weak: tab bars that carry the original's glass
static BOOL tabMotionOn, tabMotionLogged;
static int tabMotionForce;                      // self-test: 1 = on, -1 = off
static CFAbsoluteTime tabMotionAskedAt;

static void tabMotionRead(void) {
	if (tabMotionForce) { tabMotionOn = tabMotionForce > 0; return; }
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (tabMotionAskedAt != 0.0 && now - tabMotionAskedAt < 2.0) return;
	tabMotionAskedAt = now;
	BOOL on = NO;
	if (access(CTLDIR "/no-tabbar-specular-motion", F_OK) != 0 && access(CTLDIR "/disabled", F_OK) != 0) {
		NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:PREFS_FILE]];
		if ([file isKindOfClass:[NSDictionary class]]) {
			id motionValue = [file objectForKey:[NSString stringWithUTF8String:"Specular.Motion.Enabled"]];
			id sensitivityValue = [file objectForKey:[NSString stringWithUTF8String:"Specular.Motion.Sensitivity"]];
			on = [motionValue respondsToSelector:@selector(boolValue)] && [motionValue boolValue];
			double sensitivity = [sensitivityValue respondsToSelector:@selector(doubleValue)] ? [sensitivityValue doubleValue] : 2.0;
			if (on) fieldMotionSensitivity = isfinite(sensitivity) ? fmin(8.0, fmax(0.0, sensitivity)) : 2.0;
		}
	}
	tabMotionOn = on;
}

// YES when a noted bar shows its glass; apply: the glasses' light edge is turned to angle as well
static BOOL tabGlasses(double angle, BOOL apply) {
	Class glassClass = objc_getClass("LGLiveBackdropView");
	if (!glassClass || !tabGlassBars) return NO;
	SEL sel = sel_registerName("applySpecularAngle:");
	BOOL visible = NO;
	for (UIView *bar in [tabGlassBars allObjects]) {
		if (![bar window] || [bar isHidden]) continue;
		for (UIView *view in [bar subviews]) {
			if (![view isKindOfClass:glassClass] || [view isHidden]) continue;
			visible = YES;
			if (apply && [view respondsToSelector:sel]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, sel, angle);
		}
	}
	return visible;
}

static void fieldMotionStop(void) {
	if (fieldMotionTimer) { dispatch_source_cancel(fieldMotionTimer); fieldMotionTimer = NULL; }
	@try {
		if (fieldMotionManager) ((void (*)(id, SEL))objc_msgSend)(fieldMotionManager, sel_registerName("stopDeviceMotionUpdates"));
	} @catch (id e) {}
}

static void fieldMotionApply(double angle) {
	SEL sel = sel_registerName("applySpecularAngle:");
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (UIView *owner in [fieldOwners allObjects]) {
		UIView *glass = objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass"));
		if (glass && [glass window] && ![glass isHidden] && [glass respondsToSelector:sel])
			((void (*)(id, SEL, CGFloat))objc_msgSend)(glass, sel, angle);
	}
	// a bar noted earlier goes back to the resting edge when its part was switched off
	tabGlasses(tabMotionOn ? angle : -M_PI_4, YES);
	[CATransaction commit];
}

static void fieldMotionTick(void *unused) {
	@try {
		BOOL visible = NO;
		for (UIView *owner in [fieldOwners allObjects]) {
			UIView *glass = objc_getAssociatedObject(owner, KEY("lgfix_fieldGlass"));
			if (glass && [glass window] && ![glass isHidden]) { visible = YES; break; }
		}
		if (!fieldMotionOn) visible = NO;
		if (!visible && tabMotionOn) visible = tabGlasses(0.0, NO);
		BOOL on = fieldMotionOn || tabMotionOn;
		BOOL front = [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
		if (!on || !front || !visible) {
			if (!on || !front || ++fieldMotionIdle > 60) {
				if (!on) { fieldMotionAngle = -M_PI_4; fieldMotionApply(fieldMotionAngle); fieldMotionApplied = -100.0; }
				fieldMotionStop();
			}
			return;
		}
		fieldMotionIdle = 0;
		id motion = ((id (*)(id, SEL))objc_msgSend)(fieldMotionManager, sel_registerName("deviceMotion"));
		id attitude = motion ? ((id (*)(id, SEL))objc_msgSend)(motion, sel_registerName("attitude")) : nil;
		if (!attitude) return;
		double roll = ((double (*)(id, SEL))objc_msgSend)(attitude, sel_registerName("roll"));
		double pitch = ((double (*)(id, SEL))objc_msgSend)(attitude, sel_registerName("pitch"));
		double yaw = ((double (*)(id, SEL))objc_msgSend)(attitude, sel_registerName("yaw"));
		double target = (roll * 1.2 + pitch * 1.2 + yaw) * (fieldMotionSensitivity * 1.2);
		if (!isfinite(target)) return;
		double delta = atan2(sin(target - fieldMotionAngle), cos(target - fieldMotionAngle));
		fieldMotionAngle += delta * (1.0 - exp(-14.0 / 30.0));
		// a glass puts its edge back to the resting angle when it is laid out: set again twice a second anyway
		if (fabs(fieldMotionAngle - fieldMotionApplied) > 0.002 || ++fieldMotionTicks >= 15) {
			fieldMotionTicks = 0;
			fieldMotionApplied = fieldMotionAngle;
			fieldMotionApply(fieldMotionAngle);
			if (!fieldMotionLogged) {
				fieldMotionLogged = YES;
				tlog("search field: light edge follows the tilt (logged once)");
			}
			if (!tabMotionLogged && tabMotionOn && tabGlasses(0.0, NO)) {
				tabMotionLogged = YES;
				tlog("tab bar: light edge follows the tilt (logged once)");
			}
		}
	} @catch (id e) {}
}

static void fieldMotionEnsure(void);
static void fieldMotionAppActive(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
	// the setting may have been changed while the app was in the back
	if ([tabGlassBars count]) {
		tabMotionAskedAt = 0.0;
		tabMotionRead();
		if (!tabMotionOn && !fieldMotionTimer) {
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			tabGlasses(-M_PI_4, YES);
			[CATransaction commit];
		}
	}
	fieldMotionEnsure();
}

static void fieldMotionObserve(void) {
	if (fieldMotionObserving) return;
	fieldMotionObserving = YES;
	CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, fieldMotionAppActive,
	                                (__bridge CFStringRef)UIApplicationDidBecomeActiveNotification, NULL,
	                                CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void fieldMotionEnsure(void) {
	if (fieldMotionTimer || fieldTestCreate) return;
	if (access(CTLDIR "/no-searchfield-motion", F_OK) == 0) fieldMotionOn = NO;
	if (!fieldMotionOn && !tabMotionOn) return;
	@try {
		if (![UIApplication sharedApplication]) return;
		if (!fieldMotionManager) {
			dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW);
			Class cls = objc_getClass("CMMotionManager");
			if (!cls) return;
			fieldMotionManager = [[cls alloc] init];
		}
		if (!fieldMotionManager || ![fieldMotionManager respondsToSelector:sel_registerName("startDeviceMotionUpdatesUsingReferenceFrame:")]) return;
		fieldMotionObserve();
		((void (*)(id, SEL, double))objc_msgSend)(fieldMotionManager, sel_registerName("setDeviceMotionUpdateInterval:"), 1.0 / 30.0);
		// 1 = CMAttitudeReferenceFrameXArbitraryZVertical, the original's
		((void (*)(id, SEL, NSUInteger))objc_msgSend)(fieldMotionManager, sel_registerName("startDeviceMotionUpdatesUsingReferenceFrame:"), 1);
		fieldMotionIdle = 0;
		fieldMotionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
		dispatch_source_set_timer(fieldMotionTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 30), NSEC_PER_SEC / 30, NSEC_PER_SEC / 120);
		dispatch_source_set_event_handler_f(fieldMotionTimer, fieldMotionTick);
		dispatch_resume(fieldMotionTimer);
	} @catch (id e) {}
}

// called at every layout of a tab bar that is in a window
static void tabSpecularSeen(UIView *bar) {
	Class glassClass = objc_getClass("LGLiveBackdropView");
	if (!glassClass) return;
	BOOL glass = NO;
	for (UIView *view in [bar subviews])
		if ([view isKindOfClass:glassClass]) { glass = YES; break; }
	if (!glass) return;
	tabMotionRead();
	if (!tabMotionOn && ![tabGlassBars containsObject:bar]) return;
	if (!tabGlassBars) tabGlassBars = [NSHashTable weakObjectsHashTable];
	[tabGlassBars addObject:bar];
	if (!tabMotionOn) return;
	// a glass puts its edge back to the resting angle when it is laid out: the next tick sets it again
	fieldMotionTicks = 15;
	if ([UIApplication sharedApplication]) fieldMotionObserve();
	fieldMotionEnsure();
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
		id hostBlurValue = [file objectForKey:[NSString stringWithUTF8String:FIELD_HOST ".Blur"]];
		if (![file isKindOfClass:[NSDictionary class]]) {
			double (*prefFloat)(id, double) = dlsym(RTLD_DEFAULT, "LG_prefFloat");
			id (*prefString)(id, id) = dlsym(RTLD_DEFAULT, "LG_prefString");
			if (prefFloat) {
				double own = prefFloat([NSString stringWithUTF8String:"SearchField.Blur"], -1.0);
				if (own >= 0.0) blurValue = [NSNumber numberWithDouble:own];
				hostBlurValue = [NSNumber numberWithDouble:prefFloat([NSString stringWithUTF8String:FIELD_HOST ".Blur"], FIELD_HOST_BLUR_DEFAULT)];
			}
			if (prefString) tintValue = prefString([NSString stringWithUTF8String:"SearchField.TintColor"], nil);
		}
		id motionValue = [file objectForKey:[NSString stringWithUTF8String:"Specular.Motion.Enabled"]];
		id sensitivityValue = [file objectForKey:[NSString stringWithUTF8String:"Specular.Motion.Sensitivity"]];
		fieldMotionOn = answer && [motionValue respondsToSelector:@selector(boolValue)] && [motionValue boolValue];
		double sensitivity = [sensitivityValue respondsToSelector:@selector(doubleValue)] ? [sensitivityValue doubleValue] : 2.0;
		fieldMotionSensitivity = isfinite(sensitivity) ? fmin(8.0, fmax(0.0, sensitivity)) : 2.0;
		fieldOldStyle = access(CTLDIR "/searchfield-old-style", F_OK) == 0;
		// no own blur set: the Spotlight bar's (before: 5)
		double fallback = fieldOldStyle ? FIELD_BLUR_DEFAULT
		                : ([hostBlurValue isKindOfClass:[NSNumber class]] ? [hostBlurValue doubleValue] : FIELD_HOST_BLUR_DEFAULT);
		double blur = [blurValue isKindOfClass:[NSNumber class]] ? [blurValue doubleValue] : fallback;
		fieldBlur = isfinite(blur) ? fmin(50.0, fmax(0.0, blur)) : fallback;
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
	// the Spotlight bar's shape: a full pill
	if (!fieldOldStyle || radius <= 0.0 || radius > shortSide * 0.5) radius = shortSide * 0.5;
	if (!glass) {
		id (*create)(CGRect, id, id) = fieldTestCreate ? fieldTestCreate : loupeCreateGlass;
		if (!create) return;
		glass = create(frame, nil, [NSString stringWithUTF8String:fieldOldStyle ? FIELD_HOST_OLD : FIELD_HOST]);
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
	if (!hidden) fieldMotionEnsure();
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
	// Spotlight's own bar already is the original's glass (the look the text bars take over): left as it is
	if (strcmp(getprogname(), "Spotlight") == 0) return;
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
	installMotionTouches();
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

#pragma mark - private test of the tab bar selection motion

// A stand-in for the original's LGTabBarMotionState with the original's own step (Hooks/TabBar.x -tick:,
// LGLiquidRenderedStateStep, LGTabBarSpringStep), without any drawing.
typedef struct {
	__unsafe_unretained id lens, bar, displayLink;
	BOOL active, dragged, flying, settling, finished;
	unsigned long generation;
	double lastDisplayTime, targetX, targetW, targetH, x, w, h, widthVelocity, heightVelocity, restingW;
} FakeState;
static ptrdiff_t fakeOffset;
#define FAKE(self) ((FakeState *)((uint8_t *)(__bridge void *)(self) + fakeOffset))
static id fakeLens(id self, SEL _cmd) { return FAKE(self)->lens; }
static id fakeBar(id self, SEL _cmd) { return FAKE(self)->bar; }
static id fakeLink(id self, SEL _cmd) { return FAKE(self)->displayLink; }
static BOOL fakeActive(id self, SEL _cmd) { return FAKE(self)->active; }
static BOOL fakeDragged(id self, SEL _cmd) { return FAKE(self)->dragged; }
static BOOL fakeFlying(id self, SEL _cmd) { return FAKE(self)->flying; }
static BOOL fakeSettling(id self, SEL _cmd) { return FAKE(self)->settling; }
static unsigned long fakeGeneration(id self, SEL _cmd) { return FAKE(self)->generation; }
static double fakeLast(id self, SEL _cmd) { return FAKE(self)->lastDisplayTime; }
static double fakeTargetX(id self, SEL _cmd) { return FAKE(self)->targetX; }
static double fakeTargetW(id self, SEL _cmd) { return FAKE(self)->targetW; }
static double fakeTargetH(id self, SEL _cmd) { return FAKE(self)->targetH; }
static double fakeX(id self, SEL _cmd) { return FAKE(self)->x; }
static double fakeW(id self, SEL _cmd) { return FAKE(self)->w; }
static double fakeH(id self, SEL _cmd) { return FAKE(self)->h; }
static void fakeSetX(id self, SEL _cmd, double v) { FAKE(self)->x = v; }
static void fakeSetW(id self, SEL _cmd, double v) { FAKE(self)->w = v; }
static void fakeSetH(id self, SEL _cmd, double v) { FAKE(self)->h = v; }
static void fakeSetWV(id self, SEL _cmd, double v) { FAKE(self)->widthVelocity = v; }
static void fakeSetHV(id self, SEL _cmd, double v) { FAKE(self)->heightVelocity = v; }
static void fakeStart(id self, SEL _cmd) {}
static double fakeNow;
static double fakeTimestamp(id self, SEL _cmd) { return fakeNow; }

static double fakeSpringStep(double current, double target, double *velocity, double response, double dampingRatio, double dt) {
	double remaining = fmin(fmax(dt, 0.0), 1.0 / 30.0);
	while (remaining > 0.0) {
		double step = fmin(remaining, 1.0 / 120.0);
		double omega = 2.0 * M_PI / response;
		double acceleration = (target - current) * omega * omega - 2.0 * dampingRatio * omega * (*velocity);
		*velocity += acceleration * step;
		current += *velocity * step;
		remaining -= step;
	}
	return current;
}

static void fakeTick(id self, SEL _cmd, id link) {
	FakeState *f = FAKE(self);
	double dt = f->lastDisplayTime > 0.0 ? fakeNow - f->lastDisplayTime : 1.0 / 60.0;
	if (dt > 1.0 / 30.0) dt = 1.0 / 30.0;
	f->lastDisplayTime = fakeNow;
	[(UIView *)f->lens setCenter:CGPointMake(f->x, 30.0)];
	double frameFactor = fmin(fmax(dt * 60.0, 0.35), 1.4);
	double response = f->active ? 0.155 : 0.135;
	f->x += (f->targetX - f->x) * (f->active ? 0.21 : 0.14) * frameFactor;
	f->w = fakeSpringStep(f->w, f->targetW, &f->widthVelocity, response, 1.0, dt);
	f->h = fakeSpringStep(f->h, f->targetH, &f->heightVelocity, response, 1.0, dt);
	if (f->flying && fabs(f->x - f->targetX) < 1.0 && fabs(f->w - 94.0) < 1.0 && fabs(f->h - 72.0) < 1.0) {
		f->flying = NO;
		f->active = NO;
		f->targetW = f->restingW;
		f->targetH = 54.0;
		f->settling = YES;
	}
	if (f->settling && fabs(f->x - f->targetX) < 0.75 && fabs(f->w - f->targetW) < 0.75 && fabs(f->h - f->targetH) < 0.75) {
		f->settling = NO;
		f->finished = YES;
	}
}

// Private self-test (host, without the original): 1 the hooks went onto the stand-in, 2 after every tick the
// stand-in holds exactly the drop computed here, 4 lifting off swings past the lifted height, 8 a fast drag makes
// the drop flatter and wider, 16 after the stop it swings past its height and comes to rest at its size on the
// target, 32 a finger far above the bar makes it taller, 64 a release settles into the resting shape within half
// a second, 128 a tap flies to the tab, arrives and settles within 1.2 s, 256 the finger far above the bar leans
// the drop upwards by less than 30.5 pt and it is back on the middle line after the release, 512 a finger 100 pt
// past the last tab pulls the drop 34 pt past it, 1024 on a release the shape gets 3 to 13 pt flatter than the
// resting pill, and the pill then carries an additive swing that starts at the drop's last size and ends at 0,
// 2048 the bar's swing after a release starts at its pressed size, goes below its own size and ends on it, is
// taken off again by a new touch, and a bar that was not enlarged gets none, 4096 in a drag with a wavering speed
// the drop's height moves by less than 2.5 pt and by less than 0.4 of what it does with the size following the
// speed at once, and it is back at the pressed size after the stop.
#define PRESSED_W (94.0 + MOTION_PRESS_W)
#define PRESSED_H (72.0 + MOTION_PRESS_H)
int lgtabfix_motiontest(const char *arg) {
	(void)arg;
	@autoreleasepool {
		int result = 0;
		Class cls = objc_allocateClassPair([NSObject class], "LGTabBarMotionState", 0);
		Class linkClass = objc_allocateClassPair([NSObject class], "LGTabFixTestLink", 0);
		if (!cls || !linkClass) return -1;
		if (!class_addIvar(cls, "fake", sizeof(FakeState), 3, "{?=}")) return -2;
		class_addMethod(cls, sel_registerName("lens"), (IMP)fakeLens, "@@:");
		class_addMethod(cls, sel_registerName("bar"), (IMP)fakeBar, "@@:");
		class_addMethod(cls, sel_registerName("displayLink"), (IMP)fakeLink, "@@:");
		class_addMethod(cls, sel_registerName("active"), (IMP)fakeActive, "B@:");
		class_addMethod(cls, sel_registerName("dragged"), (IMP)fakeDragged, "B@:");
		class_addMethod(cls, sel_registerName("awaitingTapDestination"), (IMP)fakeFlying, "B@:");
		class_addMethod(cls, sel_registerName("awaitingRestingShape"), (IMP)fakeSettling, "B@:");
		class_addMethod(cls, sel_registerName("generation"), (IMP)fakeGeneration, "Q@:");
		class_addMethod(cls, sel_registerName("lastDisplayTime"), (IMP)fakeLast, "d@:");
		class_addMethod(cls, sel_registerName("targetCenterX"), (IMP)fakeTargetX, "d@:");
		class_addMethod(cls, sel_registerName("targetWidth"), (IMP)fakeTargetW, "d@:");
		class_addMethod(cls, sel_registerName("targetHeight"), (IMP)fakeTargetH, "d@:");
		class_addMethod(cls, sel_registerName("renderedCenterX"), (IMP)fakeX, "d@:");
		class_addMethod(cls, sel_registerName("renderedWidth"), (IMP)fakeW, "d@:");
		class_addMethod(cls, sel_registerName("renderedHeight"), (IMP)fakeH, "d@:");
		class_addMethod(cls, sel_registerName("setRenderedCenterX:"), (IMP)fakeSetX, "v@:d");
		class_addMethod(cls, sel_registerName("setRenderedWidth:"), (IMP)fakeSetW, "v@:d");
		class_addMethod(cls, sel_registerName("setRenderedHeight:"), (IMP)fakeSetH, "v@:d");
		class_addMethod(cls, sel_registerName("setWidthVelocity:"), (IMP)fakeSetWV, "v@:d");
		class_addMethod(cls, sel_registerName("setHeightVelocity:"), (IMP)fakeSetHV, "v@:d");
		class_addMethod(cls, sel_registerName("start"), (IMP)fakeStart, "v@:");
		class_addMethod(cls, sel_registerName("tick:"), (IMP)fakeTick, "v@:@");
		class_addMethod(linkClass, sel_registerName("timestamp"), (IMP)fakeTimestamp, "d@:");
		objc_registerClassPair(cls);
		objc_registerClassPair(linkClass);
		fakeOffset = ivar_getOffset(class_getInstanceVariable(cls, "fake"));
		installMotion();
		if (origMotionTick == (IMP)fakeTick && origMotionStart == (IMP)fakeStart) result += 1;
		else return result;

		UIView *bar = [[UITabBar alloc] initWithFrame:CGRectMake(0, 800, 430, 83)];
		UIView *lens = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 94, 72)];
		[lens setCenter:CGPointMake(100, 30)];
		[bar addSubview:lens];
		id link = [[linkClass alloc] init];
		id state = [[cls alloc] init];
		FakeState *f = FAKE(state);
		SEL tick = sel_registerName("tick:");
		void (*send)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
		BOOL exact = YES;
		fakeNow = 1000.0;
#define STEP(seconds) do { fakeNow += (seconds); send(state, tick, link); TabMotion *mm = motionFor(state); \
		if (!mm->valid || fabs(f->x - mm->x) > 1e-6 || fabs(f->w - mm->w) > 1e-6 || fabs(f->h - mm->h) > 1e-6) exact = NO; } while (0)

		// finger down on the selected tab: the drop lifts off
		f->lens = lens; f->bar = bar; f->generation = 1; f->active = YES;
		f->x = 100; f->w = 78; f->h = 54; f->targetX = 100; f->targetW = 94; f->targetH = 72; f->restingW = 78;
		double top = 0.0;
		for (int i = 0; i < 24; i++) { STEP(1.0 / 60.0); top = fmax(top, f->h); }
		fprintf(stderr, "motion test: lift-off top %.2f, now %.2fx%.2f\n", top, f->w, f->h);
		if (top > PRESSED_H + 0.5 && top < PRESSED_H + 14.0 && fabs(f->h - PRESSED_H) < 1.5 && fabs(f->w - PRESSED_W) < 1.5) result += 4;

		// a fast drag to the right, drawn at 120 per second
		f->dragged = YES;
		double flattest = 1000.0, widest = 0.0;
		for (int i = 0; i < 30; i++) {
			f->targetX = 100.0 + 200.0 * (i + 1) / 30.0;
			STEP(1.0 / 120.0);
			flattest = fmin(flattest, f->h); widest = fmax(widest, f->w);
		}
		fprintf(stderr, "motion test: drag flattest %.2f widest %.2f at x %.2f\n", flattest, widest, f->x);
		if (flattest < 52.0 && flattest > 40.0 && widest > 120.0 && widest < 142.0) result += 8;

		// the finger rests
		top = 0.0;
		for (int i = 0; i < 48; i++) { STEP(1.0 / 60.0); top = fmax(top, f->h); }
		fprintf(stderr, "motion test: after the stop top %.2f, rest %.2f,%.2fx%.2f\n", top, f->x, f->w, f->h);
		if (top > PRESSED_H + 0.3 && fabs(f->h - PRESSED_H) < 0.6 && fabs(f->w - PRESSED_W) < 0.6 && fabs(f->x - 300.0) < 0.5) result += 16;

		// the finger moves far above the bar
		motionTouchBar = bar; motionTouchY = [lens center].y - 150.0; motionTouchX = 300.0; motionTouching = YES;
		for (int i = 0; i < 40; i++) STEP(1.0 / 60.0);
		fprintf(stderr, "motion test: pulled %.2fx%.2f\n", f->w, f->h);
		if (f->h > PRESSED_H + 6.0 && f->h < PRESSED_H + 18.0 && f->w < PRESSED_W) result += 32;
		double leaned = [lens center].y;
		fprintf(stderr, "motion test: leaned to y %.2f (bar middle 30)\n", leaned);
		motionTouching = NO;

		// the finger moves 100 pt past the last tab (the bar's only button stands at 300)
		UIView *button = [[objc_getClass("UITabBarButton") alloc] initWithFrame:CGRectMake(260, 0, 80, 60)];
		[bar addSubview:button];
		motionTouchBar = bar; motionTouchY = 30.0; motionTouchX = 400.0; motionTouching = YES;
		f->targetX = 312.4;
		for (int i = 0; i < 40; i++) STEP(1.0 / 60.0);
		fprintf(stderr, "motion test: reached x %.2f (last tab 300)\n", f->x);
		if (button && fabs(f->x - 334.0) < 0.5) result += 512;
		motionTouching = NO;
		f->targetX = 300;
		for (int i = 0; i < 30; i++) STEP(1.0 / 60.0);

		// release after the drag: into the resting shape on the nearest tab
		UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 78, 54)];
		[pill setCenter:CGPointMake(310, 30)];
		[pill setBackgroundColor:[UIColor colorWithWhite:1.0 alpha:0.1]];
		[[pill layer] setMasksToBounds:YES];
		[[pill layer] setCornerRadius:27.0];
		[bar addSubview:pill];
		f->active = NO; f->settling = YES; f->targetX = 310; f->targetW = 78; f->targetH = 54;
		int ticks = 0;
		double smallest = 1000.0;
		while (!f->finished && ticks < 60) { STEP(1.0 / 60.0); ticks++; smallest = fmin(smallest, f->h); }
		{
			TabMotion *mm = motionFor(state);
			CAKeyframeAnimation *swing = (CAKeyframeAnimation *)[[pill layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixSettleHeight"]];
			NSArray *swingValues = swing ? [swing values] : nil;
			double first = [swingValues count] ? [[swingValues objectAtIndex:0] doubleValue] : 1000.0, deepest = 0.0, highest = 0.0;
			for (NSNumber *value in swingValues) { deepest = fmin(deepest, [value doubleValue]); highest = fmax(highest, [value doubleValue]); }
			fprintf(stderr, "motion test: release flattest %.2f (pill 54), pill swing starts at %+.2f, goes from %+.2f to %+.2f, ends at %+.2f over %lu steps\n",
				smallest, first, deepest, highest, [swingValues count] ? [[swingValues lastObject] doubleValue] : 1000.0, (unsigned long)[swingValues count]);
			if (swing && [swing isAdditive] && fabs(first - (mm->h - 54.0)) < 1e-6 && fmin(deepest, smallest - 54.0) < -3.0 && fmin(deepest, smallest - 54.0) > -13.0 && highest < 6.0
				&& [[swingValues lastObject] doubleValue] == 0.0 && [[pill layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixSettleWidth"]]) result += 1024;
		}
		fprintf(stderr, "motion test: settled after %d ticks at %.2f,%.2fx%.2f\n", ticks, f->x, f->w, f->h);
		if (f->finished && ticks <= 30) result += 64;
		fprintf(stderr, "motion test: after the release y %.2f\n", [lens center].y);
		if (leaned < 30.0 - 18.0 && leaned > 30.0 - 30.5 && fabs([lens center].y - 30.0) < 1.5) result += 256;

		// a tap on another tab: lift off, fly there, arrive, settle
		f->finished = NO; f->generation = 2; f->active = YES; f->dragged = NO; f->lastDisplayTime = 0.0;
		f->x = 310; f->w = 78; f->h = 54; f->targetX = 120; f->targetW = 94; f->targetH = 72;
		for (int i = 0; i < 4; i++) STEP(1.0 / 60.0);
		f->flying = YES;
		ticks = 4;
		while (!f->finished && ticks < 120) { STEP(1.0 / 60.0); ticks++; }
		fprintf(stderr, "motion test: tap finished after %d ticks at %.2f,%.2fx%.2f\n", ticks, f->x, f->w, f->h);
		if (f->finished && ticks <= 72 && fabs(f->x - 120.0) < 1.0) result += 128;
		// the whole bar after a release from 1.035 times its size: with the original's glide it must start at that
		// size, go below 1 and end at 1
		{
			motionBarBounce(bar, 1.035);
			CAKeyframeAnimation *swing = (CAKeyframeAnimation *)[[bar layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceX"]];
			NSArray *swingValues = swing ? [swing values] : nil;
			double start = 1000.0, lowest = 10.0, highest = 0.0, end = 1000.0;
			for (NSUInteger i = 0; i < [swingValues count]; i++) {
				double total = 1.0 + 0.035 * (1.0 - motionEaseOut((i / 60.0) / 0.26)) + [[swingValues objectAtIndex:i] doubleValue];
				if (i == 0) start = total;
				if (i > 0) { lowest = fmin(lowest, total); highest = fmax(highest, total); }
				end = total;
			}
			fprintf(stderr, "motion test: bar swing starts at %.4f, lowest %.4f, highest after the start %.4f, ends at %.4f\n", start, lowest, highest, end);
			if (swing && [swing isAdditive] && fabs(start - 1.035) < 1e-9 && lowest < 0.995 && lowest > 0.97 && highest < 1.035 && fabs(end - 1.0) < 1e-9
				&& [[bar layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceY"]]) result += 2048;
			motionBarBounceStop(bar);
			if ([[bar layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceX"]]) result -= 2048;
			motionBarBounce(bar, 1.001);
			if ([[bar layer] animationForKey:[NSString stringWithUTF8String:"lgtabfixBarBounceX"]]) result -= 2048;
		}
		// a drag whose speed wavers (420 pt/s, 130 up and down, six times a second): the drop's height keeps nearly
		// still, far stiller than with the size following the speed at once, and the stop brings the pressed size back
		{
			double range[2] = { 0.0, 0.0 };
			for (int live = 1; live >= 0; live--) {
				motionLiveSize = live;
				f->finished = NO; f->generation += 1; f->active = YES; f->dragged = YES; f->flying = NO; f->settling = NO;
				f->lastDisplayTime = 0.0; f->widthVelocity = f->heightVelocity = 0.0;
				f->x = 100; f->w = PRESSED_W; f->h = PRESSED_H; f->targetX = 100; f->targetW = 94; f->targetH = 72;
				double low = 1000.0, high = 0.0;
				for (int i = 0; i < 84; i++) {
					double t = i / 60.0;
					f->targetX += (420.0 + 130.0 * sin(2.0 * M_PI * 6.0 * t)) / 60.0;
					STEP(1.0 / 60.0);
					if (i >= 30) { low = fmin(low, f->h); high = fmax(high, f->h); }
				}
				range[live] = high - low;
				fprintf(stderr, "motion test: wavering drag (%s) height from %.2f to %.2f\n", live ? "size live" : "size held", low, high);
			}
			for (int i = 0; i < 60; i++) STEP(1.0 / 60.0);
			fprintf(stderr, "motion test: after the wavering drag rest %.2fx%.2f\n", f->w, f->h);
			if (range[0] < 2.5 && range[0] < 0.4 * range[1] && fabs(f->h - PRESSED_H) < 0.6 && fabs(f->w - PRESSED_W) < 0.6) result += 4096;
			motionLiveSize = -1;
		}
		if (exact) result += 2;
		return result;
	}
}

static double tabTestAngle = -100.0;
static void tabTestApply(id self, SEL _cmd, CGFloat angle) { tabTestAngle = angle; }

// Private self-test (host) of the tab bar's moving light edge, a plain view class standing in for the glass:
// 1 a bar without glass is not noted, 2 a bar with glass is noted at its layout, 4 the angle reaches its glass,
// 8 a hidden glass is left alone, 16 with the part switched off the glass gets the resting angle.
int lgtabfix_tabspeculartest(const char *arg) {
	(void)arg;
	@autoreleasepool {
		int result = 0;
		Class glassClass = objc_getClass("LGLiveBackdropView");
		if (!glassClass) {
			glassClass = objc_allocateClassPair([UIView class], "LGLiveBackdropView", 0);
			class_addMethod(glassClass, sel_registerName("applySpecularAngle:"), (IMP)tabTestApply, "v24@0:8d16");
			objc_registerClassPair(glassClass);
		}
		install();
		tabMotionForce = 1;
		UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 430, 932)];
		UITabBar *plain = [[UITabBar alloc] initWithFrame:CGRectMake(0, 800, 430, 83)];
		[window addSubview:plain];
		[plain setNeedsLayout]; [plain layoutIfNeeded];
		if (hookInstalled && ![tabGlassBars count]) result += 1;
		UITabBar *bar = [[UITabBar alloc] initWithFrame:CGRectMake(0, 700, 430, 83)];
		UIView *glass = [[glassClass alloc] initWithFrame:CGRectMake(20, 10, 390, 60)];
		[bar insertSubview:glass atIndex:0];
		[window addSubview:bar];
		[bar setNeedsLayout]; [bar layoutIfNeeded];
		if ([tabGlassBars count] == 1 && [tabGlassBars containsObject:bar]) result += 2;
		fieldMotionApply(0.5);
		if (fabs(tabTestAngle - 0.5) < 1e-9) result += 4;
		[glass setHidden:YES];
		fieldMotionApply(0.9);
		if (fabs(tabTestAngle - 0.5) < 1e-9 && !tabGlasses(0.0, NO)) result += 8;
		[glass setHidden:NO];
		tabMotionForce = -1;
		[bar setNeedsLayout]; [bar layoutIfNeeded];
		fieldMotionApply(0.9);
		if (fabs(tabTestAngle + M_PI_4) < 1e-9) result += 16;
		fprintf(stderr, "tab specular test: bars %lu, last angle %.3f, timer %d\n", (unsigned long)[tabGlassBars count], tabTestAngle, fieldMotionTimer != NULL);
		tabMotionForce = 0;
		return result;
	}
}
