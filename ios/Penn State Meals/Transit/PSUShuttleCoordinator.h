#import "PSUShuttleData.h"

NS_ASSUME_NONNULL_BEGIN
NS_SWIFT_UI_ACTOR
@interface PSUShuttleCoordinator : NSObject
@property (nonatomic, readonly) NSArray<PSUShuttleRoute *> *routes;
@property (nonatomic, readonly, nullable) NSError *routeError;
@property (nonatomic, copy) NSSet<NSNumber *> *selectedRouteIDs;
@property (nonatomic, copy, nullable) void (^routesDidChange)(void);
@property (nonatomic, readonly, getter=isActive) BOOL active;
- (instancetype)initWithMap:(MKMapView *)map presenter:(UIViewController *)presenter;
- (instancetype)initWithMap:(MKMapView *)map presenter:(UIViewController *)presenter client:(PSUShuttleAPIClient *)client;
- (void)loadRoutes:(void (^)(void))completion;
- (void)setActive:(BOOL)active;
- (void)setPollingVisible:(BOOL)visible;
- (void)centerMap;
- (nullable MKOverlayRenderer *)rendererForOverlay:(id<MKOverlay>)overlay;
- (nullable MKAnnotationView *)viewForAnnotation:(id<MKAnnotation>)annotation;
- (BOOL)selectAnnotation:(id<MKAnnotation>)annotation;
@end
NS_ASSUME_NONNULL_END
