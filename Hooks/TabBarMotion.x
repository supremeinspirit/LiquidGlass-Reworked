// Tab bar selection motion for the rootful build: the same code as the rootless add-on's (rootless-addon/lgtabfix.m,
// section "tab bar selection motion", state of Reworked v3 test38), compiled into the tweak itself. It changes the
// drop that Hooks/TabBar.x draws (LGTabBarMotionState) at run time, exactly as the add-on does to the original.
// Kept as its own file so that both builds share one text; change it there first and copy the section over.
// The switch files below are looked for in /usr/lib/LiquidAssFix on a rootful phone.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

#define CTLDIR "/usr/lib/LiquidAssFix"
#define BUILD_TAG "rootful"
#define KEY(name) ((const void *)sel_registerName(name))

// status lines (a few per process) in the process's own temporary directory
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
// Kill switch: create /usr/lib/LiquidAssFix/no-tabbar-motion (the original's motion)
// Without the swing of the resting pill after a release only: /usr/lib/LiquidAssFix/no-tabbar-settle-bounce
//
// Since t35 the whole bar swings as well when it goes back from its pressed size: the original enlarges the bar
// by 3.5 % while a tab is held and lets it glide back in 0.26 s; now it runs a little below its size and comes
// back. Without that only: /usr/lib/LiquidAssFix/no-tabbar-release-bounce
// The drop's sizes as before t31: /usr/lib/LiquidAssFix/tabbar-drop-old-size
// Without the size change from the finger's height only: /usr/lib/LiquidAssFix/no-tabbar-pull
// Without the lean towards the finger's height only: /usr/lib/LiquidAssFix/no-tabbar-lean
// Without the longer way past the first and last tab only: /usr/lib/LiquidAssFix/no-tabbar-reach
// Trial: /usr/lib/LiquidAssFix/tabbar-120hz lets an app's own animations run at the screen's full
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
#define MOTION_PRESS_W 0.0
#define MOTION_PRESS_H 13.0
#define MOTION_FAST_W 38.0
#define MOTION_FAST_H 32.0
#define MOTION_SLOW_SPEED 45.0      // pt per second up to which the drop keeps its pressed size
#define MOTION_FULL_SPEED 800.0
static int motionOldSize = -1;

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
			// on its way to a tapped tab the drop ends in the original's own lifted size: the original waits for
			// exactly that size before it lets the drop settle on the tab
			double press = flying ? fmin(fabs(targetX - m->x) / 40.0, 1.0) : 1.0;
			wantW = m->baseW + MOTION_PRESS_W * press + MOTION_FAST_W * speed - 0.35 * pull;
			wantH = m->baseH + MOTION_PRESS_H * press - MOTION_FAST_H * speed + pull;
			if (flying || !dragged) { responseX = 0.28; dampingX = 0.72; }      // on its way to a tapped tab
			else                    { responseX = 0.15; dampingX = 0.78; }      // under the finger
			responseSize = 0.28;
			dampingSize = 0.40;
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
			if (@available(iOS 15.0, *)) {
				CAFrameRateRange range = CAFrameRateRangeMake(80.0f, 120.0f, 120.0f);
				((void (*)(id, SEL, CAFrameRateRange))objc_msgSend)(link, rangeSel, range);
			}
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

// The touch hooks go on when the tweak is loaded into a process with UIKit's tab bar; they do nothing until the
// drop of Hooks/TabBar.x moves.
__attribute__((constructor)) static void LGTabBarMotionLoad(void) {
	@autoreleasepool {
		@try { installMotionTouches(); } @catch (id e) {}
	}
}
