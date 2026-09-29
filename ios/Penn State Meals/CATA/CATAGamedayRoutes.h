#import <Foundation/Foundation.h>
#import "RouteModel.h"

NS_ASSUME_NONNULL_BEGIN
/// Main-thread, session-only routing policy. It never reads or writes preferences.
@interface CATAGamedayRoutes : NSObject
- (void)updateRouteCatalog:(NSArray<RouteModel *> *)routes;
/// Recomputes the Penn State weekday only at a day boundary. Returns YES if an
/// expired in-memory override was removed and effective routes must be reapplied.
- (BOOL)refreshDay:(NSDate *)date;
- (NSDictionary<NSString *, NSNumber *> *)effectiveSelection:(NSDictionary<NSString *, NSNumber *> *)selection;
- (void)retainOverridesForSelection:(NSDictionary<NSString *, NSNumber *> *)selection;
/// Nil on weekdays, during cooldown, or when every selected base route has buses.
- (nullable NSDictionary<NSNumber *, RouteModel *> *)candidatesForSelection:(NSDictionary<NSString *, NSNumber *> *)selection
                                                        visibleRouteIDs:(NSSet<NSNumber *> *)visibleRouteIDs
                                                                   date:(NSDate *)date;
- (BOOL)shouldCheckAtDate:(NSDate *)date;
/// Only live, valid locations establish a detour. A successful empty response
/// leaves base routes unchanged; another probe is allowed after five minutes.
- (BOOL)acceptVehicles:(NSArray *)vehicles candidates:(NSDictionary<NSNumber *, RouteModel *> *)candidates;
@end
NS_ASSUME_NONNULL_END
