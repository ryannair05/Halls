#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNumber * _Nullable PSUShuttleNumber(id _Nullable value);
FOUNDATION_EXPORT NSString *PSUShuttleString(id _Nullable value);
FOUNDATION_EXPORT NSNumber * _Nullable PSUShuttleIdentifier(NSDictionary *value, NSString *upper, NSString *mixed);
FOUNDATION_EXPORT id _Nullable PSUShuttleDecodeJSON(NSData *data, NSError **error);
FOUNDATION_EXPORT MKPolyline * _Nullable PSUShuttleDecodePolyline(NSString *encoded);
FOUNDATION_EXPORT NSDate * _Nullable PSUShuttleDate(id _Nullable value);
FOUNDATION_EXPORT NSArray<NSDictionary *> *PSUShuttleArrivalRows(NSArray *values, NSDate *now, NSUInteger limit);
FOUNDATION_EXPORT NSTimeInterval PSUShuttleVehicleAge(NSDictionary *vehicle, NSDate *received, NSDate *now);

@interface PSUShuttleStop : NSObject
@property (nonatomic, readonly) NSNumber *identifier;
@property (nonatomic, readonly) NSNumber *routeID;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
- (nullable instancetype)initWithDictionary:(NSDictionary *)value routeID:(NSNumber *)routeID;
@end

@interface PSUShuttleRoute : NSObject
@property (nonatomic, readonly) NSNumber *identifier;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) UIColor *color;
@property (nonatomic, readonly) NSArray<PSUShuttleStop *> *stops;
@property (nonatomic, readonly, nullable) MKPolyline *polyline;
- (nullable instancetype)initWithDictionary:(NSDictionary *)value;
@end

/// A cancellable transport with an injectable session. Parsing runs on the session queue;
/// completion is always delivered on the main thread.
@interface PSUShuttleAPIClient : NSObject
- (instancetype)initWithSession:(NSURLSession *)session;
- (NSURLSessionDataTask *)fetch:(NSString *)method
                         query:(nullable NSDictionary<NSString *, NSString *> *)query
                    completion:(void (^)(NSArray * _Nullable values, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
