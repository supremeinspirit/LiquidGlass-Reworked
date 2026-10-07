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

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define BUILD_TAG "t1"
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

__attribute__((constructor)) static void lgtabfix_init(void) {
	install();
}

// Private self-test (host): 100 + hook installed
int lgtabfix_selftest(const char *arg) {
	(void)arg;
	return 100 + (hookInstalled ? 1 : 0);
}
