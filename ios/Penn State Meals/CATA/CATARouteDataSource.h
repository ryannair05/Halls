#import <Foundation/Foundation.h>
#import "RouteModel.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSTimeInterval const CATARouteDisplayCacheMaximumAge;
FOUNDATION_EXPORT NSTimeInterval const CATARouteOperationalCacheMaximumAge;

typedef void (^CATARouteLoadCompletion)(NSArray<RouteModel *> *routes,
                                        NSError * _Nullable error);

@interface CATARouteDataSource : NSObject

@property (class, nonatomic, readonly) CATARouteDataSource *shared;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Returns cached routes immediately when available. If they are older than
/// `maximumAge`, one shared refresh is started. Callers that opt into
/// `notifyOnRefresh` receive a second completion after that refresh finishes.
/// Completions are always delivered on the main thread.
- (void)loadVisibleRoutesWithMaximumAge:(NSTimeInterval)maximumAge
                        notifyOnRefresh:(BOOL)notifyOnRefresh
                             completion:(CATARouteLoadCompletion)completion;

@end

NS_ASSUME_NONNULL_END
