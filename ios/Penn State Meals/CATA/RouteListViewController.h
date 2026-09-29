//
//  RouteListViewController.h
//  Penn State Meals
//
//  Created by Ryan Nair on 5/16/25.
//

#ifndef RouteListViewController_h
#define RouteListViewController_h

#import <UIKit/UIKit.h>
#import "RouteModel.h"

NS_ASSUME_NONNULL_BEGIN
@class PSUShuttleCoordinator;

@interface RouteListViewController : UITableViewController {
    NSArray<RouteModel *> *routes;
}

// Independent mutable selection; replacing or mutating it remains supported.
@property (nonatomic, strong, nullable) NSMutableSet<NSNumber *> *selectedRouteIDs;
@property (nonatomic, weak, nullable) id viewController;
@property (nonatomic, assign, readonly) BOOL isLoading;
@property (nonatomic, strong, readonly, nullable) NSError *error;
@property (nonatomic, strong, readonly, nullable) UIActivityIndicatorView *loadingIndicator;

@property (nonatomic, strong, nullable) PSUShuttleCoordinator *shuttles;
@property (nonatomic) BOOL shuttleProUnlocked;
@property (nonatomic, copy, nullable) void (^requestShuttlePro)(void (^completion)(BOOL unlocked));
@property (nonatomic, copy, nullable) void (^shuttleSelectionChanged)(void);
- (instancetype)initWithSavedData:(NSArray<NSNumber *> *)savedData;

@end
NS_ASSUME_NONNULL_END

#endif /* RouteListViewController_h */
