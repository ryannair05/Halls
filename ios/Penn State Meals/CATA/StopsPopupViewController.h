//
//  StopsPopupViewController.h
//  Penn State Meals
//
//  Created by Ryan Nair on 3/11/25.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "KMLParser.h"

NS_ASSUME_NONNULL_BEGIN

@interface DepartureInfo : NSObject

@property (nonatomic, strong) NSNumber *routeId;
@property (nonatomic, copy, nullable) NSString *destination;
@property (nonatomic, strong) NSDate *departureTime;
@property (nonatomic, copy, nullable) NSString *status;
@property (nonatomic, assign) NSTimeInterval deviation;

- (instancetype)initWithRouteId:(NSNumber *)routeId
                    destination:(nullable NSString *)destination
                  departureTime:(NSDate *)departureTime
                         status:(nullable NSString *)status
                      deviation:(NSTimeInterval)deviation NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NSString *)timeRemainingWith:(NSDateFormatter *)formatter;

@end


// UI properties are main-thread confined; views are nil before header setup.
@interface StopsPopupViewController : UITableViewController
@property (nonatomic, copy, nullable) NSString *stopName;
@property (nonatomic, strong, nullable) NSNumber *stopId;
// Snapshots membership on assignment; DepartureInfo objects remain shared.
@property (nonatomic, copy, nullable) NSArray<DepartureInfo *> *departures;
@property (nonatomic, assign) CLLocationDistance userLocation;
@property (nonatomic, strong, readonly, nullable) UILabel *headerLabel;
@property (nonatomic, strong, readonly, nullable) UILabel *stopIdLabel;
@property (nonatomic, strong, readonly, nullable) UIView *headerView;
@property (nonatomic, strong, readonly, nullable) UIView *emptyStateView;
// Live map-owned parsers; this reference may disappear when the map is released.
@property (nonatomic, weak, nullable) NSMutableDictionary<NSString *, KMLParser *> *busAnnotations;

- (instancetype)initWithTitle:(nullable NSString *)title stopId:(NSNumber *)stopId location:(CLLocationDistance)userLocation annotations:(nullable NSMutableDictionary<NSString *, KMLParser *> *)busAnnotations;
// Called on the main thread by the map's existing polling loop.
- (void)refreshDeparturesIfVisible;
- (void)cancelDepartureLoading;
@end

NS_ASSUME_NONNULL_END
