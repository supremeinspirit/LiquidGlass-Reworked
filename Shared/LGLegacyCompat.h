#pragma once
#import <UIKit/UIKit.h>

// iOS 13 stand-ins for UIKit API that arrived in iOS 14; newer systems
// still take the native path.

void LGSetButtonPrimaryMenu(UIButton *button, UIMenu *menu);
UIMenu *LGButtonPrimaryMenu(UIButton *button);
BOOL LGPresentButtonPrimaryMenu(UIButton *button);

void LGAddControlHandler(UIControl *control, UIControlEvents events,
                         void (^handler)(__kindof UIControl *sender));

UIView *LGMakeColorWell(UIColor *color, void (^changed)(UIColor *color));

UIDocumentPickerViewController *LGMakeJSONOpenPicker(void);
