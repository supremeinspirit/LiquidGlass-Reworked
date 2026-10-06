#import "LGLegacyCompat.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kLGLegacyMenuKey = &kLGLegacyMenuKey;
static const void *kLGLegacyMenuTargetKey = &kLGLegacyMenuTargetKey;

static UIViewController *LGLegacyPresenterForView(UIView *view) {
    UIResponder *responder = view;
    UIViewController *controller = nil;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller = (UIViewController *)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    if (!controller) controller = view.window.rootViewController;
    while (controller.presentedViewController &&
           !controller.presentedViewController.isBeingDismissed)
        controller = controller.presentedViewController;
    return controller;
}

static void LGLegacyPresentMenu(UIMenu *menu, UIView *source) {
    UIViewController *presenter = LGLegacyPresenterForView(source);
    if (!menu || !presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:menu.title.length ? menu.title : nil
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIView *weakSource = source;
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *submenu = (UIMenu *)element;
            if (submenu.options & UIMenuOptionsDisplayInline) {
                // inline groups flatten into the parent sheet
                for (UIMenuElement *child in submenu.children) {
                    if (![child isKindOfClass:UIAction.class]) continue;
                    UIAction *action = (UIAction *)child;
                    if (action.attributes & UIMenuElementAttributesHidden) continue;
                    NSString *title = action.state == UIMenuElementStateOn
                        ? [@"✓ " stringByAppendingString:action.title] : action.title;
                    UIAlertAction *item = [UIAlertAction actionWithTitle:title
                        style:(action.attributes & UIMenuElementAttributesDestructive)
                            ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                        handler:^(__unused UIAlertAction *alertAction) {
                        UIActionHandler handler = nil;
                        @try { handler = [action valueForKey:@"handler"]; }
                        @catch (__unused NSException *exception) {}
                        if (handler) handler(action);
                    }];
                    item.enabled = !(action.attributes & UIMenuElementAttributesDisabled);
                    [sheet addAction:item];
                }
                continue;
            }
            NSString *title = [submenu.title stringByAppendingString:@" ›"];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *alertAction) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    LGLegacyPresentMenu(submenu, weakSource);
                });
            }]];
            continue;
        }
        if (![element isKindOfClass:UIAction.class]) continue;
        UIAction *action = (UIAction *)element;
        if (action.attributes & UIMenuElementAttributesHidden) continue;
        NSString *title = action.state == UIMenuElementStateOn
            ? [@"✓ " stringByAppendingString:action.title] : action.title;
        UIAlertAction *item = [UIAlertAction actionWithTitle:title
            style:(action.attributes & UIMenuElementAttributesDestructive)
                ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *alertAction) {
            UIActionHandler handler = nil;
            @try { handler = [action valueForKey:@"handler"]; }
            @catch (__unused NSException *exception) {}
            if (handler) handler(action);
        }];
        item.enabled = !(action.attributes & UIMenuElementAttributesDisabled);
        [sheet addAction:item];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:
        [[NSBundle bundleForClass:UIApplication.class] localizedStringForKey:@"Cancel"
                                                                       value:@"Cancel"
                                                                       table:nil]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@interface LGLegacyMenuTarget : NSObject
- (void)lg_showMenu:(UIButton *)sender;
@end

@implementation LGLegacyMenuTarget
- (void)lg_showMenu:(UIButton *)sender {
    LGLegacyPresentMenu(objc_getAssociatedObject(sender, kLGLegacyMenuKey), sender);
}
@end

void LGSetButtonPrimaryMenu(UIButton *button, UIMenu *menu) {
    if (!button) return;
    if (@available(iOS 14.0, *)) {
        button.menu = menu;
        button.showsMenuAsPrimaryAction = menu != nil;
        return;
    }
    objc_setAssociatedObject(button, kLGLegacyMenuKey, menu,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGLegacyMenuTarget *target = objc_getAssociatedObject(button, kLGLegacyMenuTargetKey);
    if (menu && !target) {
        target = [LGLegacyMenuTarget new];
        objc_setAssociatedObject(button, kLGLegacyMenuTargetKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addTarget:target action:@selector(lg_showMenu:)
         forControlEvents:UIControlEventTouchUpInside];
    } else if (!menu && target) {
        [button removeTarget:target action:@selector(lg_showMenu:)
            forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, kLGLegacyMenuTargetKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

UIMenu *LGButtonPrimaryMenu(UIButton *button) {
    if (@available(iOS 14.0, *)) return button.menu;
    return objc_getAssociatedObject(button, kLGLegacyMenuKey);
}

BOOL LGPresentButtonPrimaryMenu(UIButton *button) {
    if (!button) return NO;
    if (@available(iOS 14.0, *)) {
        UIContextMenuInteraction *interaction = button.contextMenuInteraction;
        SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
        if (!interaction || ![interaction respondsToSelector:present]) return NO;
        CGPoint center = CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, present, center);
        return YES;
    }
    UIMenu *menu = objc_getAssociatedObject(button, kLGLegacyMenuKey);
    if (!menu) return NO;
    LGLegacyPresentMenu(menu, button);
    return YES;
}

#pragma mark - block control actions

static const void *kLGLegacyControlTargetsKey = &kLGLegacyControlTargetsKey;

@interface LGLegacyControlTarget : NSObject
@property (nonatomic, copy) void (^handler)(__kindof UIControl *sender);
- (void)lg_fire:(UIControl *)sender;
@end

@implementation LGLegacyControlTarget
- (void)lg_fire:(UIControl *)sender {
    if (self.handler) self.handler(sender);
}
@end

void LGAddControlHandler(UIControl *control, UIControlEvents events,
                         void (^handler)(__kindof UIControl *sender)) {
    if (!control || !handler) return;
    if (@available(iOS 14.0, *)) {
        [control addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            handler((UIControl *)action.sender);
        }] forControlEvents:events];
        return;
    }
    LGLegacyControlTarget *target = [LGLegacyControlTarget new];
    target.handler = handler;
    NSMutableArray *targets = objc_getAssociatedObject(control, kLGLegacyControlTargetsKey);
    if (!targets) {
        targets = [NSMutableArray array];
        objc_setAssociatedObject(control, kLGLegacyControlTargetsKey, targets,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [targets addObject:target];
    [control addTarget:target action:@selector(lg_fire:) forControlEvents:events];
}

#pragma mark - color well

@interface LGLegacyColorPicker : UIViewController
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, copy) void (^changed)(UIColor *color);
@end

@implementation LGLegacyColorPicker {
    UISlider *_sliders[4];
    UILabel *_values[4];
    UIView *_preview;
    UILabel *_hex;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(lg_done)];

    CGFloat components[4] = { 1.0, 1.0, 1.0, 1.0 };
    [self.color getRed:&components[0] green:&components[1] blue:&components[2] alpha:&components[3]];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    _preview = [[UIView alloc] initWithFrame:CGRectZero];
    _preview.layer.cornerRadius = 16.0;
    _preview.layer.cornerCurve = kCACornerCurveContinuous;
    _preview.layer.borderWidth = 1.0;
    _preview.layer.borderColor = UIColor.separatorColor.CGColor;
    [_preview.heightAnchor constraintEqualToConstant:72.0].active = YES;
    [stack addArrangedSubview:_preview];

    _hex = [[UILabel alloc] initWithFrame:CGRectZero];
    _hex.textAlignment = NSTextAlignmentCenter;
    _hex.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightMedium];
    _hex.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:_hex];

    NSArray<NSString *> *names = @[ @"R", @"G", @"B", @"A" ];
    NSArray<UIColor *> *tints = @[ UIColor.systemRedColor, UIColor.systemGreenColor,
                                   UIColor.systemBlueColor, UIColor.systemGrayColor ];
    for (NSInteger index = 0; index < 4; index++) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
        name.text = names[index];
        name.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        [name.widthAnchor constraintEqualToConstant:18.0].active = YES;

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.minimumValue = 0.0;
        slider.maximumValue = 1.0;
        slider.value = (float)components[index];
        slider.minimumTrackTintColor = tints[index];
        [slider addTarget:self action:@selector(lg_sliderChanged)
         forControlEvents:UIControlEventValueChanged];
        _sliders[index] = slider;

        UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
        value.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightRegular];
        value.textColor = UIColor.secondaryLabelColor;
        value.textAlignment = NSTextAlignmentRight;
        [value.widthAnchor constraintEqualToConstant:36.0].active = YES;
        _values[index] = value;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ name, slider, value ]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 12.0;
        row.alignment = UIStackViewAlignmentCenter;
        [stack addArrangedSubview:row];
    }

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24.0],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24.0],
    ]];
    [self lg_refresh];
}

- (UIColor *)lg_currentColor {
    return [UIColor colorWithRed:_sliders[0].value green:_sliders[1].value
                            blue:_sliders[2].value alpha:_sliders[3].value];
}

- (void)lg_refresh {
    _preview.backgroundColor = [self lg_currentColor];
    for (NSInteger index = 0; index < 4; index++)
        _values[index].text = [NSString stringWithFormat:@"%ld",
                               (long)lround(_sliders[index].value * 255.0)];
    _hex.text = [NSString stringWithFormat:@"#%02lX%02lX%02lX%02lX",
                 (long)lround(_sliders[0].value * 255.0), (long)lround(_sliders[1].value * 255.0),
                 (long)lround(_sliders[2].value * 255.0), (long)lround(_sliders[3].value * 255.0)];
}

- (void)lg_sliderChanged {
    [self lg_refresh];
    self.color = [self lg_currentColor];
    if (self.changed) self.changed(self.color);
}

- (void)lg_done {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface LGLegacyColorWell : UIControl
@property (nonatomic, strong) UIColor *selectedColor;
@property (nonatomic, copy) void (^changed)(UIColor *color);
@end

@implementation LGLegacyColorWell {
    UIView *_swatch;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _swatch = [[UIView alloc] initWithFrame:self.bounds];
    _swatch.userInteractionEnabled = NO;
    _swatch.layer.borderWidth = 2.0;
    _swatch.layer.borderColor = UIColor.separatorColor.CGColor;
    [self addSubview:_swatch];
    [self addTarget:self action:@selector(lg_open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _swatch.frame = self.bounds;
    _swatch.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
}

- (void)setSelectedColor:(UIColor *)color {
    _selectedColor = color;
    _swatch.backgroundColor = color;
}

- (void)lg_open {
    UIViewController *presenter = LGLegacyPresenterForView(self);
    if (!presenter) return;
    LGLegacyColorPicker *picker = [LGLegacyColorPicker new];
    picker.color = self.selectedColor ?: UIColor.whiteColor;
    __weak typeof(self) weakSelf = self;
    picker.changed = ^(UIColor *color) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.selectedColor = color;
        if (strongSelf.changed) strongSelf.changed(color);
    };
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:picker];
    [presenter presentViewController:navigation animated:YES completion:nil];
}
@end

UIView *LGMakeColorWell(UIColor *color, void (^changed)(UIColor *color)) {
    if (@available(iOS 14.0, *)) {
        UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectZero];
        well.selectedColor = color;
        well.supportsAlpha = YES;
        LGAddControlHandler(well, UIControlEventValueChanged, ^(UIColorWell *sender) {
            if (changed) changed(sender.selectedColor);
        });
        return well;
    }
    LGLegacyColorWell *well = [[LGLegacyColorWell alloc] initWithFrame:CGRectZero];
    well.selectedColor = color;
    well.changed = changed;
    return well;
}

UIDocumentPickerViewController *LGMakeJSONOpenPicker(void) {
    if (@available(iOS 14.0, *)) {
        Class typeClass = NSClassFromString(@"UTType");
        id jsonType = [typeClass respondsToSelector:@selector(typeWithIdentifier:)]
            ? [typeClass performSelector:@selector(typeWithIdentifier:) withObject:@"public.json"]
            : nil;
        if (jsonType)
            return [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:@[ jsonType ]];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[ @"public.json" ] inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
}

#pragma mark - SF Symbols missing before iOS 14

static NSString *LGLegacySymbolFallback(NSString *name) {
    static NSDictionary<NSString *, NSString *> *fallbacks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fallbacks = @{
            @"apps.iphone": @"square.grid.2x2.fill",
            @"iphone": @"rectangle.fill",
            @"rectangle.bottomthird.inset.filled": @"rectangle.dock",
            @"rectangle.topthird.inset.filled": @"rectangle.fill.badge.checkmark",
            @"switch.2": @"slider.horizontal.3",
            @"rectangle.3.group.fill": @"rectangle.3.offgrid.fill",
            @"keyboard.fill": @"keyboard",
            @"hand.tap.fill": @"hand.point.right.fill",
            @"speaker.wave.3.fill": @"speaker.3.fill",
            @"bell.badge.fill": @"bell.fill",
            @"line.3.horizontal": @"line.horizontal.3",
        };
    });
    return [name isKindOfClass:NSString.class] ? fallbacks[name] : nil;
}

__attribute__((constructor))
static void LGLegacySymbolsInit(void) {
    if (@available(iOS 14.0, *)) return;
    Class meta = object_getClass(UIImage.class);

    SEL plain = @selector(systemImageNamed:);
    Method plainMethod = class_getClassMethod(UIImage.class, plain);
    if (plainMethod) {
        UIImage *(*original)(id, SEL, NSString *) = (void *)method_getImplementation(plainMethod);
        class_replaceMethod(meta, plain, imp_implementationWithBlock(^UIImage *(id self, NSString *name) {
            UIImage *image = original(self, plain, name);
            NSString *fallback = image ? nil : LGLegacySymbolFallback(name);
            return fallback ? original(self, plain, fallback) : image;
        }), method_getTypeEncoding(plainMethod));
    }

    SEL configured = @selector(systemImageNamed:withConfiguration:);
    Method configuredMethod = class_getClassMethod(UIImage.class, configured);
    if (configuredMethod) {
        UIImage *(*original)(id, SEL, NSString *, id) =
            (void *)method_getImplementation(configuredMethod);
        class_replaceMethod(meta, configured, imp_implementationWithBlock(^UIImage *(id self, NSString *name, id configuration) {
            UIImage *image = original(self, configured, name, configuration);
            NSString *fallback = image ? nil : LGLegacySymbolFallback(name);
            return fallback ? original(self, configured, fallback, configuration) : image;
        }), method_getTypeEncoding(configuredMethod));
    }
}
