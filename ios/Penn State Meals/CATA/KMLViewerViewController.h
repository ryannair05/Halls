//
//  KMLViewerViewController.h
//  Penn State Meals
//
//  Created by Ryan Nair on 3/11/25.
//

#import <UIKit/UIViewController.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@interface KMLViewerViewController : UIViewController
@property (nonatomic, copy, nullable) BOOL (^proAccessProvider)(void);
@property (nonatomic, copy, nullable) void (^presentPro)(UIViewController *presenter, void (^completion)(BOOL unlocked));
- (void)openLinkedRoute:(nullable NSNumber *)routeID stop:(nullable NSNumber *)stopID;
@end

NS_ASSUME_NONNULL_END
