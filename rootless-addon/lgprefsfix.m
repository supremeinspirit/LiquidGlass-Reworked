// LiquidAssFixPrefs: adds a "Dynamic Island" and a "Text Loupe" page to the stock LiquidAss settings (loaded
// into Preferences).
// Runtime style on purpose: no @"" literals and no @implementation (see lgfix.m).
//
// The stock UI is LGPSurfaceController fed with item dictionaries. This adds one nav item to the "Surfaces"
// list and a method the item calls, which pushes another LGPSurfaceController with the island's items.
// Keys written (domain dylv.liquidassprefs, read by lgfix in SpringBoard):
//   DynamicIsland.Enabled (bool, default on), DynamicIsland.TintColor ("#RRGGBBAA", default transparent),
//   DynamicIsland.SpecularEnabled (bool, default off), DynamicIsland.ClearCutout (bool, default off)
// Text Loupe: TextLoupe.Enabled (bool, default on; read by LiquidAssFixApps in every app). The lens is drawn with
// the renderer's "PrefsSlider" glass, so the page shows that host's stock parameter items (PrefsSlider.*).
// Search Fields: SearchField.Enabled (bool, default on; read by LiquidAssFixApps in every app). Drawn with the
// "SearchPill" glass, the page links to that surface.
//
// Kill switch: create /var/jb/usr/lib/LiquidAssFix/no-prefs-page

#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

#define CTLDIR "/var/jb/usr/lib/LiquidAssFix"
#define S(cstr) [NSString stringWithUTF8String:(cstr)]
#define ACTION "lgfixOpenDynamicIsland:"
#define LOUPE_ACTION "lgfixOpenTextLoupe:"
#define LOUPE_HOST "PrefsSlider"
#define FIELD_ACTION "lgfixOpenSearchFields:"

// Declaration only (no class is emitted): gives the compiler the designated initializer's types
@interface LGFixSurfaceControllerShape : UIViewController
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray *)items;
@end

static NSDictionary *item(const char *type, const char *title, const char *subtitle) {
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	[d setObject:S(type) forKey:S("type")];
	[d setObject:S(title) forKey:S("title")];
	[d setObject:S(subtitle) forKey:S("subtitle")];
	return d;
}

static NSArray *dynamicIslandItems(void) {
	NSMutableDictionary *enabled = [item("switch", "Enabled",
	                                     "Liquid glass in the Dynamic Island while it is expanded.") mutableCopy];
	[enabled setObject:S("DynamicIsland.Enabled") forKey:S("key")];
	[enabled setObject:[NSNumber numberWithBool:YES] forKey:S("default")];
	[enabled setObject:[NSNumber numberWithBool:YES] forKey:S("controls_following_panel")];

	NSMutableDictionary *tint = [item("color", "Tint Color",
	                                  "Color laid over the island glass. Raise its alpha for better legibility.") mutableCopy];
	[tint setObject:S("DynamicIsland.TintColor") forKey:S("key")];
	[tint setObject:S("#00000000") forKey:S("default")];
	[tint setObject:S("DynamicIsland.Enabled") forKey:S("enabled_key")];
	[tint setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];

	NSMutableDictionary *specular = [item("switch", "Specular Highlight",
	                                      "Bright rim line on the glass, strongest at the top left.") mutableCopy];
	[specular setObject:S("DynamicIsland.SpecularEnabled") forKey:S("key")];
	[specular setObject:[NSNumber numberWithBool:NO] forKey:S("default")];
	[specular setObject:S("DynamicIsland.Enabled") forKey:S("enabled_key")];
	[specular setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];

	NSMutableDictionary *cutout = [item("switch", "Clear Camera Pill",
	                                    "Leaves out the black pill over the camera while the island is glass. It only shows in screenshots and recordings. Off keeps the standard black pill.") mutableCopy];
	[cutout setObject:S("DynamicIsland.ClearCutout") forKey:S("key")];
	[cutout setObject:[NSNumber numberWithBool:NO] forKey:S("default")];
	[cutout setObject:S("DynamicIsland.Enabled") forKey:S("enabled_key")];
	[cutout setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];

	NSDictionary *section = item("section", "Glass",
	                             "The island uses the Pill HUD glass. Pill HUD has to stay enabled, and its parameters apply to the island.");
	NSMutableDictionary *pill = [item("nav", "Pill HUD", "") mutableCopy];
	[pill setObject:S("PillHUD") forKey:S("surface_identifier")];

	return [NSArray arrayWithObjects:enabled, tint, specular, cutout, section, pill, nil];
}

// The switch, then the stock parameter items of the glass the lens is drawn with (without that host's own switch)
static NSArray *textLoupeItems(void) {
	NSMutableDictionary *enabled = [item("switch", "Enabled",
	                                     "Liquid glass on the lens that appears while the insertion point is dragged through text. A lens hanging over a screen edge stays without glass.") mutableCopy];
	[enabled setObject:S("TextLoupe.Enabled") forKey:S("key")];
	[enabled setObject:[NSNumber numberWithBool:YES] forKey:S("default")];
	[enabled setObject:[NSNumber numberWithBool:YES] forKey:S("controls_following_panel")];
	NSMutableArray *items = [NSMutableArray arrayWithObjects:enabled, nil];
	[items addObject:item("section", "Glass",
	                      "The lens shares its glass with the slider knobs of these settings: the values below apply to both. Apps pick up a changed blur or highlight when they are opened again.")];
	NSArray *(*rendererItems)(NSString *) = dlsym(RTLD_DEFAULT, "LGRendererItemsForHostPrefix");
	NSArray *stock = rendererItems ? rendererItems(S(LOUPE_HOST)) : nil;
	if (![stock isKindOfClass:[NSArray class]]) return items;
	for (id entry in stock) {
		if (![entry isKindOfClass:[NSDictionary class]]) continue;
		id key = [entry objectForKey:S("key")];
		if ([key isKindOfClass:[NSString class]] && [key isEqualToString:S(LOUPE_HOST ".Enabled")]) continue;
		NSMutableDictionary *copy = [entry mutableCopy];
		[copy setObject:S("TextLoupe.Enabled") forKey:S("enabled_key")];
		[copy setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];
		[items addObject:copy];
	}
	return items;
}

static NSArray *searchFieldItems(void) {
	NSMutableDictionary *enabled = [item("switch", "Enabled",
	                                     "Liquid glass in place of the grey backing of text bars: search fields in all apps and Safari's address bar. Blur and tint apply within a few seconds, switching on or off when the app is opened again.") mutableCopy];
	[enabled setObject:S("SearchField.Enabled") forKey:S("key")];
	[enabled setObject:[NSNumber numberWithBool:YES] forKey:S("default")];
	NSMutableDictionary *blur = [item("slider", "Blur", "Softness of what shows through the bar. 0 is clear glass.") mutableCopy];
	[blur setObject:S("SearchField.Blur") forKey:S("key")];
	[blur setObject:[NSNumber numberWithDouble:5.0] forKey:S("default")];
	[blur setObject:[NSNumber numberWithDouble:0.0] forKey:S("min")];
	[blur setObject:[NSNumber numberWithDouble:30.0] forKey:S("max")];
	[blur setObject:[NSNumber numberWithInteger:1] forKey:S("decimals")];
	[blur setObject:S("SearchField.Enabled") forKey:S("enabled_key")];
	[blur setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];
	NSMutableDictionary *tint = [item("color", "Tint Color", "Color laid over the bar's glass, also used for the bar inside the text lens. Raise its alpha for better legibility.") mutableCopy];
	[tint setObject:S("SearchField.TintColor") forKey:S("key")];
	[tint setObject:S("#00000000") forKey:S("default")];
	[tint setObject:S("SearchField.Enabled") forKey:S("enabled_key")];
	[tint setObject:[NSNumber numberWithBool:YES] forKey:S("enabled_default")];
	NSDictionary *section = item("section", "Rim", "Rim width and refraction are those of the Search Pill glass.");
	NSMutableDictionary *pill = [item("nav", "Search Pill", "") mutableCopy];
	[pill setObject:S("SearchPill") forKey:S("surface_identifier")];
	return [NSArray arrayWithObjects:enabled, blur, tint, section, pill, nil];
}

// Adds the nav items to the "Surfaces" list, after Pill HUD. Returns 1 when added.
static int patchSurfaceItems(id controller) {
	Class cls = object_getClass(controller);
	Ivar identifierIvar = class_getInstanceVariable(cls, "_screenIdentifier");
	Ivar itemsIvar = class_getInstanceVariable(cls, "_items");
	if (!identifierIvar || !itemsIvar) return 0;
	id identifier = object_getIvar(controller, identifierIvar);
	NSArray *items = object_getIvar(controller, itemsIvar);
	if (![identifier isKindOfClass:[NSString class]] || ![identifier isEqualToString:S("Surfaces")]) return 0;
	if (![items isKindOfClass:[NSArray class]]) return 0;

	NSUInteger insertAt = [items count];
	for (NSUInteger i = 0; i < [items count]; i++) {
		id entry = [items objectAtIndex:i];
		if (![entry isKindOfClass:[NSDictionary class]]) return 0;
		id action = [entry objectForKey:S("action")];
		if ([action isKindOfClass:[NSString class]] && [action isEqualToString:S(ACTION)]) return 0;
		id surface = [entry objectForKey:S("surface_identifier")];
		if ([surface isKindOfClass:[NSString class]] && [surface isEqualToString:S("PillHUD")]) insertAt = i + 1;
	}
	NSMutableDictionary *nav = [item("nav", "Dynamic Island", "") mutableCopy];
	[nav setObject:S(ACTION) forKey:S("action")];
	NSMutableDictionary *loupe = [item("nav", "Text Loupe", "") mutableCopy];
	[loupe setObject:S(LOUPE_ACTION) forKey:S("action")];
	NSMutableArray *patched = [items mutableCopy];
	[patched insertObject:nav atIndex:insertAt];
	[patched insertObject:loupe atIndex:insertAt + 1];
	NSMutableDictionary *fields = [item("nav", "Text Bars", "") mutableCopy];
	[fields setObject:S(FIELD_ACTION) forKey:S("action")];
	[patched insertObject:fields atIndex:insertAt + 2];
	object_setIvarWithStrongDefault(controller, itemsIvar, [patched copy]);
	return 1;
}

static IMP sOrigViewDidLoad;

static void surfaceViewDidLoad(id self, SEL _cmd) {
	@try {
		patchSurfaceItems(self);
	} @catch (id e) {}
	((void (*)(id, SEL))sOrigViewDidLoad)(self, _cmd);
}

static void openDynamicIsland(id self, SEL _cmd, id sender) {
	@try {
		Class cls = objc_getClass("LGPSurfaceController");
		if (!cls) return;
		UIViewController *page = [(LGFixSurfaceControllerShape *)[cls alloc]
		    initWithTitle:S("Dynamic Island")
		         subtitle:S("Liquid glass for the expanded island")
		        tintColor:[UIColor systemPinkColor]
		       identifier:S("DynamicIsland")
		            items:dynamicIslandItems()];
		[[(UIViewController *)self navigationController] pushViewController:page animated:YES];
	} @catch (id e) {}
}

static void openTextLoupe(id self, SEL _cmd, id sender) {
	@try {
		Class cls = objc_getClass("LGPSurfaceController");
		if (!cls) return;
		UIViewController *page = [(LGFixSurfaceControllerShape *)[cls alloc]
		    initWithTitle:S("Text Loupe")
		         subtitle:S("Liquid glass for the text cursor lens")
		        tintColor:[UIColor systemBlueColor]
		       identifier:S("TextLoupe")
		            items:textLoupeItems()];
		[[(UIViewController *)self navigationController] pushViewController:page animated:YES];
	} @catch (id e) {}
}

static void openSearchFields(id self, SEL _cmd, id sender) {
	@try {
		Class cls = objc_getClass("LGPSurfaceController");
		if (!cls) return;
		UIViewController *page = [(LGFixSurfaceControllerShape *)[cls alloc]
		    initWithTitle:S("Text Bars")
		         subtitle:S("Liquid glass for search fields and Safari's address bar")
		        tintColor:[UIColor systemTealColor]
		       identifier:S("SearchField")
		            items:searchFieldItems()];
		[[(UIViewController *)self navigationController] pushViewController:page animated:YES];
	} @catch (id e) {}
}

static BOOL sInstalled;

// The settings bundle is loaded when its pane is first opened; returns 1 once the class is there and hooked
static int install(void) {
	if (sInstalled) return 1;
	Class cls = objc_getClass("LGPSurfaceController");
	if (!cls) return 0;
	SEL viewDidLoad = @selector(viewDidLoad);
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	Method own = NULL;
	for (unsigned int i = 0; i < count; i++)
		if (method_getName(methods[i]) == viewDidLoad) own = methods[i];
	free(methods);
	if (!own || !class_getInstanceVariable(cls, "_items") || !class_getInstanceVariable(cls, "_screenIdentifier")) return 0;
	if (![cls instancesRespondToSelector:sel_registerName("initWithTitle:subtitle:tintColor:identifier:items:")]) return 0;
	sInstalled = YES;
	class_addMethod(cls, sel_registerName(ACTION), (IMP)openDynamicIsland, "v@:@");
	class_addMethod(cls, sel_registerName(LOUPE_ACTION), (IMP)openTextLoupe, "v@:@");
	class_addMethod(cls, sel_registerName(FIELD_ACTION), (IMP)openSearchFields, "v@:@");
	sOrigViewDidLoad = method_setImplementation(own, (IMP)surfaceViewDidLoad);
	return 1;
}

// For the private test host: loads the real settings bundle binary and checks the patch on a real controller
int lgprefsfix_selftest(const char *outPath) {
	@autoreleasepool {
		FILE *f = fopen(outPath, "w");
		if (!f) return -1;
		void *bundle = dlopen("/var/jb/Library/PreferenceBundles/LiquidAssPrefs.bundle/LiquidAssPrefs", RTLD_NOW);
		fprintf(f, "# bundle=%p %s\n", bundle, bundle ? "" : dlerror());
		int installed = install();
		fprintf(f, "# install=%d\n", installed); fflush(f);
		Class cls = objc_getClass("LGPSurfaceController");
		if (!cls || !installed) { fclose(f); return -2; }
		NSMutableDictionary *pill = [item("nav", "Pill HUD", "") mutableCopy];
		[pill setObject:S("PillHUD") forKey:S("surface_identifier")];
		NSArray *base = [NSArray arrayWithObjects:item("section", "A", ""), pill, item("section", "B", ""), nil];
		id surfaces = [(LGFixSurfaceControllerShape *)[cls alloc] initWithTitle:S("t") subtitle:S("s") tintColor:nil
		                                                           identifier:S("Surfaces") items:base];
		int first = patchSurfaceItems(surfaces), second = patchSurfaceItems(surfaces);
		NSArray *items = object_getIvar(surfaces, class_getInstanceVariable(cls, "_items"));
		fprintf(f, "# patch first=%d second=%d count=%d (want 1 0 6)\n", first, second, (int)[items count]);
		fprintf(f, "# items=%s\n", [[items description] UTF8String]);
		id other = [(LGFixSurfaceControllerShape *)[cls alloc] initWithTitle:S("t") subtitle:S("s") tintColor:nil
		                                                        identifier:S("Dock") items:base];
		fprintf(f, "# other=%d (want 0) responds=%d\n", patchSurfaceItems(other),
		        [surfaces respondsToSelector:sel_registerName(ACTION)]);
		fprintf(f, "# island items=%s\n", [[dynamicIslandItems() description] UTF8String]);
		NSArray *loupeItems = textLoupeItems();
		fprintf(f, "# search field items=%s\n", [[searchFieldItems() description] UTF8String]);
		fprintf(f, "# loupe responds=%d items=%d %s\n", [surfaces respondsToSelector:sel_registerName(LOUPE_ACTION)],
		        (int)[loupeItems count], [[loupeItems description] UTF8String]);
		fclose(f);
		return first * 100 + second * 10 + (int)[items count];
	}
}

static BOOL sInstallPending;

static void deferredInstall(void *unused) {
	sInstallPending = NO;
	int result = 0;
	@try { result = install(); } @catch (id e) {}
	if (getenv("LGFIX_TRACE")) fprintf(stderr, "deferred install=%d\n", result);
}

// Runs inside dyld while an image is being added: only schedule the look-up (no block: a block that captures
// nothing is a static initializer, which the on-device toolchain signs wrongly -> SIGBUS in Settings)
static void imageAdded(const struct mach_header *header, intptr_t slide) {
	if (sInstalled || sInstallPending) return;
	sInstallPending = YES;
	dispatch_async_f(dispatch_get_main_queue(), NULL, deferredInstall);
}

__attribute__((constructor)) static void lgprefsfixInit(void) {
	if (getenv("LGFIX_SELFTEST")) return;
	if (access(CTLDIR "/disabled", F_OK) == 0 || access(CTLDIR "/no-prefs-page", F_OK) == 0) return;
	if (install()) return;
	// The settings bundle is loaded later, when its pane is opened: look again whenever an image is added
	_dyld_register_func_for_add_image(imageAdded);
}
