#import "PSUShuttleCoordinator.h"
#import "../CATA/Annotations.h"
#import <math.h>

static NSString *const PSUShuttleSelectionKey = @"psuShuttleSelectedRoutes.v1";
static const NSTimeInterval PSUShuttlePollInterval = 3.5;
static const NSTimeInterval PSUShuttleRouteMaximumAge = 6 * 60 * 60;

@interface PSUShuttleAnnotation : BusAnnotation
@property (nonatomic, strong) NSNumber *identifier;
@property (nonatomic, strong) NSNumber *routeID;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic) BOOL vehicle;
@property (nonatomic, copy) NSDictionary *data;
@property (nonatomic, strong) NSDate *received;
@end
@implementation PSUShuttleAnnotation
- (NSNumber *)routeID { return self.routeId; }
- (void)setRouteID:(NSNumber *)routeID { self.routeId = routeID; }
- (UIColor *)color { return self.busColor; }
- (void)setColor:(UIColor *)color { self.busColor = color; }
@end

@class PSUShuttleDetailsController;
@interface PSUShuttleCoordinator ()
@property (nonatomic, weak) MKMapView *map;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) PSUShuttleAPIClient *client;
@property (nonatomic, copy, readwrite) NSArray<PSUShuttleRoute *> *routes;
@property (nonatomic, strong, readwrite) NSError *routeError;
@property (nonatomic, copy) NSArray<NSDictionary *> *routePayload;
@property (nonatomic, strong) NSDate *routesReceived;
@property (nonatomic) BOOL loadingRoutes;
@property (nonatomic) BOOL readCache;
@property (nonatomic) BOOL pollingVisible;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *routeCompletions;
@property (nonatomic, strong) NSMutableArray<NSURLSessionDataTask *> *routeTasks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PSUShuttleAnnotation *> *vehicles;
@property (nonatomic, strong) NSMutableArray<PSUShuttleAnnotation *> *stops;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *capacities;
@property (nonatomic, strong) NSDate *capacitiesReceived;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURLSessionDataTask *vehicleTask;
@property (nonatomic, strong) NSURLSessionDataTask *capacityTask;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger failures;
@property (nonatomic, strong) NSDate *nextVehicleRequest;
@property (nonatomic, strong) NSDate *nextCapacityRequest;
@property (nonatomic, weak) PSUShuttleDetailsController *details;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic) BOOL vehicleUnavailable;
- (void)tick;
- (void)applyRoutes:(NSArray *)payload received:(NSDate *)received persist:(BOOL)persist;
@end

@interface PSUShuttleDetailsController : UITableViewController
@property (nonatomic, strong) PSUShuttleAPIClient *client;
@property (nonatomic, strong) PSUShuttleAnnotation *annotation;
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSDate *received;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger failures;
@property (nonatomic, strong) NSDate *nextRequest;
@property (nonatomic, copy) NSString *message;
@property (nonatomic) BOOL appearing;
- (void)stop;
- (void)refresh;
@end

@implementation PSUShuttleCoordinator
- (instancetype)initWithMap:(MKMapView *)map presenter:(UIViewController *)presenter {
    return [self initWithMap:map presenter:presenter client:[[PSUShuttleAPIClient alloc] init]];
}
- (instancetype)initWithMap:(MKMapView *)map presenter:(UIViewController *)presenter client:(PSUShuttleAPIClient *)client {
    if ((self = [super init])) {
        _map = map; _presenter = presenter; _client = client; _routes = @[]; _routePayload = @[];
        _routeCompletions = [NSMutableArray array]; _routeTasks = [NSMutableArray array];
        _vehicles = [NSMutableDictionary dictionary]; _stops = [NSMutableArray array]; _capacities = [NSMutableDictionary dictionary];
        NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:PSUShuttleSelectionKey];
        NSMutableSet *ids = [NSMutableSet set];
        for (id value in saved) if (PSUShuttleNumber(value)) [ids addObject:value];
        _selectedRouteIDs = [ids copy];
        _statusLabel = [[UILabel alloc] init];
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.adjustsFontForContentSizeCategory = YES;
        _statusLabel.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.95];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.numberOfLines = 0;
        _statusLabel.layer.cornerRadius = 10; _statusLabel.clipsToBounds = YES; _statusLabel.hidden = YES;
        [map addSubview:_statusLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_statusLabel.centerXAnchor constraintEqualToAnchor:map.centerXAnchor],
            [_statusLabel.bottomAnchor constraintEqualToAnchor:map.safeAreaLayoutGuide.bottomAnchor constant:-16],
            [_statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:map.widthAnchor constant:-32],
            [_statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:32]
        ]];
    }
    return self;
}
- (void)dealloc {
    [_timer invalidate]; [_vehicleTask cancel]; [_capacityTask cancel];
    for (NSURLSessionDataTask *task in _routeTasks) [task cancel];
}
- (NSURL *)cacheURL {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [directory URLByAppendingPathComponent:@"psu-shuttle-routes-v1.json"];
}
- (void)loadRoutes:(void (^)(void))completion {
    if (self.routesReceived && -self.routesReceived.timeIntervalSinceNow < PSUShuttleRouteMaximumAge) { completion(); return; }
    [self.routeCompletions addObject:[completion copy]];
    if (self.loadingRoutes) return;
    self.loadingRoutes = YES;
    if (!self.readCache) {
        self.readCache = YES;
        NSURL *url = self.cacheURL;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:url];
            NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![cache isKindOfClass:NSDictionary.class]) cache = nil;
            NSArray *routes = [cache[@"routes"] isKindOfClass:NSArray.class] ? cache[@"routes"] : nil;
            NSNumber *timestamp = PSUShuttleNumber(cache[@"received"]);
            NSDate *received = timestamp ? [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                if (routes && received) {
                    [self applyRoutes:routes received:received persist:NO];
                } else [self fetchRoutes];
            });
        });
    } else [self fetchRoutes];
}
- (void)finishRoutes {
    self.loadingRoutes = NO;
    [self.routeTasks removeAllObjects];
    NSArray *callbacks = [self.routeCompletions copy];
    [self.routeCompletions removeAllObjects];
    for (void (^callback)(void) in callbacks) callback();
    if (self.routesDidChange) self.routesDidChange();
    [self updateStatus];
}
- (void)fetchRoutes {
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.client fetch:@"GetRoutesForMapWithScheduleWithEncodedLine" query:nil completion:^(NSArray *values, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!error) { self.routeError = nil; [self applyRoutes:values received:NSDate.date persist:YES]; }
        else [self fetchFallbackRoutes];
    }];
    [self.routeTasks addObject:task];
}
- (void)fetchFallbackRoutes {
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.client fetch:@"GetRoutes" query:nil completion:^(NSArray *values, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) { self.routeError = error; [self finishRoutes]; return; }
        NSMutableArray *fallback = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (id raw in values) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            PSUShuttleRoute *route = [[PSUShuttleRoute alloc] initWithDictionary:raw];
            if (!route) continue;
            NSMutableDictionary *value = [raw mutableCopy];
            for (NSDictionary *cached in self.routePayload) {
                if ([PSUShuttleIdentifier(cached, @"RouteID", @"RouteId") isEqual:route.identifier]) {
                    if (cached[@"EncodedPolyline"]) value[@"EncodedPolyline"] = cached[@"EncodedPolyline"];
                    if (cached[@"Stops"]) value[@"Stops"] = cached[@"Stops"];
                }
            }
            [fallback addObject:value];
            dispatch_group_enter(group);
            NSURLSessionDataTask *stops = [self.client fetch:@"GetStops" query:@{@"routeID": route.identifier.stringValue} completion:^(NSArray *stops, NSError *stopError) {
                if (!stopError) value[@"Stops"] = stops;
                dispatch_group_leave(group);
            }];
            [self.routeTasks addObject:stops];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.routeError = nil;
            [self applyRoutes:fallback received:NSDate.date persist:YES];
        });
    }];
    [self.routeTasks addObject:task];
}
- (void)applyRoutes:(NSArray *)payload received:(NSDate *)received persist:(BOOL)persist {
    NSURL *cacheURL = self.cacheURL;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *routes = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableArray *validPayload = [NSMutableArray array];
        for (id raw in payload) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            PSUShuttleRoute *route = [[PSUShuttleRoute alloc] initWithDictionary:raw];
            if (route && ![seen containsObject:route.identifier]) {
                [routes addObject:route]; [seen addObject:route.identifier]; [validPayload addObject:raw];
            }
        }
        if (persist) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"received": @(received.timeIntervalSince1970), @"routes": validPayload} options:0 error:nil];
            [data writeToURL:cacheURL options:NSDataWritingAtomic error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (self.active) [self removeMapContent];
            self.routes = routes; self.routePayload = validPayload; self.routesReceived = received;
            if (self.active) [self addMapContent];
            if (!persist && -received.timeIntervalSinceNow >= PSUShuttleRouteMaximumAge) {
                if (self.routesDidChange) self.routesDidChange();
                [self fetchRoutes];
            } else [self finishRoutes];
        });
    });
}
- (void)setSelectedRouteIDs:(NSSet<NSNumber *> *)selectedRouteIDs {
    if ([_selectedRouteIDs isEqualToSet:selectedRouteIDs]) return;
    [self stopPolling];
    if (self.active) [self removeMapContent];
    _selectedRouteIDs = [selectedRouteIDs copy];
    [NSUserDefaults.standardUserDefaults setObject:_selectedRouteIDs.allObjects forKey:PSUShuttleSelectionKey];
    for (NSNumber *identifier in self.vehicles.allKeys) {
        if (![_selectedRouteIDs containsObject:self.vehicles[identifier].routeID]) [self.vehicles removeObjectForKey:identifier];
    }
    if (self.active) { [self addMapContent]; [self startPolling]; }
}
- (void)setActive:(BOOL)active {
    if (_active == active) return;
    [self stopPolling];
    if (_active) [self removeMapContent];
    _active = active;
    if (active) { [self addMapContent]; [self startPolling]; }
    [self updateStatus];
}
- (void)setPollingVisible:(BOOL)visible {
    _pollingVisible = visible;
    if (visible) [self startPolling]; else [self stopPolling];
}
- (void)removeMapContent {
    for (PSUShuttleRoute *route in self.routes) if (route.polyline) [self.map removeOverlay:route.polyline];
    [self.map removeAnnotations:self.stops]; [self.map removeAnnotations:self.vehicles.allValues];
    [self.stops removeAllObjects];
}
- (void)addMapContent {
    for (PSUShuttleRoute *route in self.routes) {
        if (![self.selectedRouteIDs containsObject:route.identifier]) continue;
        if (route.polyline) [self.map addOverlay:route.polyline];
        for (PSUShuttleStop *stop in route.stops) {
            PSUShuttleAnnotation *annotation = [[PSUShuttleAnnotation alloc] init];
            annotation.identifier = stop.identifier; annotation.routeID = route.identifier;
            annotation.title = stop.name; annotation.subtitle = route.name; annotation.coordinate = stop.coordinate; annotation.color = route.color;
            [self.stops addObject:annotation];
        }
    }
    [self.map addAnnotations:self.stops];
    [self.map addAnnotations:self.vehicles.allValues];
}
- (void)centerMap {
    MKMapRect rect = MKMapRectNull;
    for (PSUShuttleRoute *route in self.routes) if ([self.selectedRouteIDs containsObject:route.identifier] && route.polyline) rect = MKMapRectUnion(rect, route.polyline.boundingMapRect);
    if (MKMapRectIsNull(rect)) for (PSUShuttleAnnotation *stop in self.stops) {
        MKMapPoint point = MKMapPointForCoordinate(stop.coordinate);
        rect = MKMapRectUnion(rect, MKMapRectMake(point.x, point.y, 1, 1));
    }
    if (!MKMapRectIsNull(rect)) [self.map setVisibleMapRect:rect edgePadding:UIEdgeInsetsMake(60, 35, 70, 35) animated:YES];
}
- (void)startPolling {
    if (!self.active || !self.pollingVisible || !self.selectedRouteIDs.count || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:PSUShuttlePollInterval repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
        self.timer.tolerance = 1;
        [self tick];
    }
}
- (void)stopPolling {
    self.generation++;
    [self.timer invalidate]; self.timer = nil;
    [self.vehicleTask cancel]; self.vehicleTask = nil;
    [self.capacityTask cancel]; self.capacityTask = nil;
    [self.details stop];
}
- (void)tick {
    if (!self.active || !self.pollingVisible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    [self updateVehicleAppearance];
    [self.details refresh];
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    if (!self.vehicleTask && (!self.nextVehicleRequest || self.nextVehicleRequest.timeIntervalSinceNow <= 0)) {
        self.vehicleTask = [self.client fetch:@"GetMapVehiclePoints" query:nil completion:^(NSArray *values, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.generation != generation) return;
            self.vehicleTask = nil;
            if (error) {
                self.vehicleUnavailable = YES;
                self.failures = MIN(5, self.failures + 1);
                self.nextVehicleRequest = [NSDate dateWithTimeIntervalSinceNow:MIN(60, PSUShuttlePollInterval * pow(2, self.failures))];
            } else {
                self.vehicleUnavailable = NO; self.failures = 0; self.nextVehicleRequest = nil;
                [self applyVehicles:values];
            }
            [self updateVehicleAppearance]; [self updateStatus];
        }];
    }
    if (!self.capacityTask && (!self.nextCapacityRequest || self.nextCapacityRequest.timeIntervalSinceNow <= 0)) {
        self.capacityTask = [self.client fetch:@"GetVehicleCapacities" query:nil completion:^(NSArray *values, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.generation != generation) return;
            self.capacityTask = nil;
            self.nextCapacityRequest = [NSDate dateWithTimeIntervalSinceNow:error ? 60 : 30];
            if (!error) {
                [self.capacities removeAllObjects]; self.capacitiesReceived = NSDate.date;
                for (id value in values) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSNumber *identifier = PSUShuttleIdentifier(value, @"VehicleID", @"VehicleId");
                    if (identifier) self.capacities[identifier] = value;
                }
                [self updateVehicleAppearance];
            }
        }];
    }
}
- (void)applyVehicles:(NSArray *)values {
    NSMutableSet *missing = [NSMutableSet setWithArray:self.vehicles.allKeys];
    NSDate *now = NSDate.date;
    for (id raw in values) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *value = raw;
        NSNumber *identifier = PSUShuttleIdentifier(value, @"VehicleID", @"VehicleId");
        NSNumber *routeID = PSUShuttleIdentifier(value, @"RouteID", @"RouteId");
        NSNumber *latitude = PSUShuttleNumber(value[@"Latitude"]), *longitude = PSUShuttleNumber(value[@"Longitude"]);
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
        if (!identifier || ![self.selectedRouteIDs containsObject:routeID] || !latitude || !longitude || !CLLocationCoordinate2DIsValid(coordinate)) continue;
        if (PSUShuttleNumber(value[@"IsOnRoute"]) && ![value[@"IsOnRoute"] boolValue]) continue;
        [missing removeObject:identifier];
        PSUShuttleAnnotation *annotation = self.vehicles[identifier];
        BOOL added = annotation == nil;
        if (added) { annotation = [[PSUShuttleAnnotation alloc] init]; annotation.vehicle = YES; annotation.identifier = identifier; self.vehicles[identifier] = annotation; }
        annotation.routeID = routeID; annotation.data = value; annotation.received = now;
        NSString *name = PSUShuttleString(value[@"Name"]);
        NSString *title = name.length ? [NSString localizedStringWithFormat:NSLocalizedString(@"Shuttle %@", nil), name] : NSLocalizedString(@"Campus Shuttle", nil);
        if (![annotation.title isEqualToString:title]) annotation.title = title;
        CLLocationDirection heading = [PSUShuttleNumber(value[@"Heading"]) doubleValue];
        UIColor *previousColor = annotation.color;
        for (PSUShuttleRoute *route in self.routes) if ([route.identifier isEqual:routeID]) { annotation.color = route.color; break; }
        BOOL positionChanged = annotation.coordinate.latitude != coordinate.latitude || annotation.coordinate.longitude != coordinate.longitude;
        BOOL headingChanged = annotation.heading != heading;
        BusAnnotationView *view = (id)[self.map viewForAnnotation:annotation];
        if ([view isKindOfClass:BusAnnotationView.class]) {
            if (positionChanged || headingChanged || ![previousColor isEqual:annotation.color]) [view animateToCoordinate:coordinate withHeading:heading];
        } else {
            if (positionChanged) annotation.coordinate = coordinate;
            annotation.heading = heading;
        }
        if (added && self.active) [self.map addAnnotation:annotation];
    }
    for (NSNumber *identifier in missing) { [self.map removeAnnotation:self.vehicles[identifier]]; [self.vehicles removeObjectForKey:identifier]; }
}
- (void)updateVehicleAppearance {
    NSDate *now = NSDate.date;
    for (PSUShuttleAnnotation *annotation in self.vehicles.allValues) {
        NSDictionary *capacity = self.capacities[annotation.identifier];
        NSNumber *occupied = PSUShuttleNumber(capacity[@"CurrentOccupation"]), *total = PSUShuttleNumber(capacity[@"Capacity"]);
        BOOL freshCapacity = self.capacitiesReceived && -self.capacitiesReceived.timeIntervalSinceNow <= 90;
        NSString *occupancy = freshCapacity && occupied && occupied.doubleValue >= 0 && total.doubleValue > 0 ?
            [NSString localizedStringWithFormat:NSLocalizedString(@"%@ of %@ aboard", nil), occupied, total] : NSLocalizedString(@"Occupancy unavailable", nil);
        BOOL stale = self.vehicleUnavailable || PSUShuttleVehicleAge(annotation.data, annotation.received, now) > 60;
        NSString *status = stale ? NSLocalizedString(@"Last known location", nil) : ([PSUShuttleNumber(annotation.data[@"IsDelayed"]) boolValue] ? NSLocalizedString(@"Delayed", nil) : NSLocalizedString(@"Live", nil));
        NSString *subtitle = [NSString stringWithFormat:@"%@ · %@", status, occupancy];
        BOOL changed = ![annotation.subtitle isEqualToString:subtitle];
        if (changed) annotation.subtitle = subtitle;
        annotation.onBoard = freshCapacity ? occupied : nil;
        annotation.seatingCapacity = freshCapacity ? total : nil;
        BusAnnotationView *view = (id)[self.map viewForAnnotation:annotation];
        if ([view isKindOfClass:BusAnnotationView.class]) {
            view.alpha = stale ? 0.55 : 1;
            view.accessibilityLabel = annotation.title;
            view.accessibilityValue = subtitle;
            if (changed) [view animateToCoordinate:annotation.coordinate withHeading:annotation.heading];
        }
    }
}
- (void)updateStatus {
    NSString *message = nil;
    if (self.active) {
        if (self.routeError && !self.routes.count) message = NSLocalizedString(@"Shuttle routes unavailable", nil);
        else if (!self.routes.count && self.loadingRoutes) message = NSLocalizedString(@"Loading campus shuttles…", nil);
        else if (self.vehicleUnavailable) message = NSLocalizedString(@"Live shuttle data unavailable", nil);
        else if (!self.vehicles.count) message = NSLocalizedString(@"No live shuttles for selected routes", nil);
    }
    self.statusLabel.text = message ? [NSString stringWithFormat:@"  %@  ", message] : nil;
    self.statusLabel.hidden = message == nil;
}
- (MKOverlayRenderer *)rendererForOverlay:(id<MKOverlay>)overlay {
    for (PSUShuttleRoute *route in self.routes) if (overlay == route.polyline) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:route.polyline];
        renderer.strokeColor = route.color; renderer.lineWidth = 4;
        return renderer;
    }
    return nil;
}
- (MKAnnotationView *)viewForAnnotation:(id<MKAnnotation>)annotation {
    if (![annotation isKindOfClass:PSUShuttleAnnotation.class]) return nil;
    PSUShuttleAnnotation *shuttle = (id)annotation;
    if (shuttle.vehicle) {
        BusAnnotationView *view = (id)[self.map dequeueReusableAnnotationViewWithIdentifier:@"PSUShuttleVehicle"];
        if (!view) view = [[BusAnnotationView alloc] initWithAnnotation:shuttle reuseIdentifier:@"PSUShuttleVehicle"];
        view.annotation = shuttle;
        view.canShowCallout = NO; // Shuttle taps present the existing shuttle detail sheet.
        view.displayPriority = MKFeatureDisplayPriorityRequired;
        view.zPriority = MKAnnotationViewZPriorityMax;
        view.enabled = YES;
        view.isAccessibilityElement = YES;
        view.accessibilityTraits = UIAccessibilityTraitButton;
        view.accessibilityLabel = shuttle.title;
        view.accessibilityValue = shuttle.subtitle;
        view.alpha = self.vehicleUnavailable || PSUShuttleVehicleAge(shuttle.data, shuttle.received, NSDate.date) > 60 ? 0.55 : 1;
        return view;
    }
    NSString *identifier = @"PSUShuttleStop";
    StopAnnotationView *view = (id)[self.map dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!view) view = [[StopAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
    view.annotation = annotation;
    view.displayPriority = MKFeatureDisplayPriorityDefaultLow;
    view.zPriority = MKAnnotationViewZPriorityMin;
    view.isAccessibilityElement = YES;
    view.accessibilityTraits = UIAccessibilityTraitButton;
    view.accessibilityLabel = [NSString localizedStringWithFormat:NSLocalizedString(@"Shuttle stop: %@", nil), shuttle.title];
    view.accessibilityValue = shuttle.subtitle;
    view.canShowCallout = NO;
    return view;
}
- (BOOL)selectAnnotation:(id<MKAnnotation>)annotation {
    if (![annotation isKindOfClass:PSUShuttleAnnotation.class]) return NO;
    // Never leave a consumed tap selected: otherwise the same marker cannot be tapped again.
    [self.map deselectAnnotation:annotation animated:NO];
    if (!self.active || self.presenter.presentedViewController) return YES;
    PSUShuttleDetailsController *details = [[PSUShuttleDetailsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    details.client = self.client; details.annotation = (id)annotation;
    details.title = annotation.title;
    self.details = details;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:details];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible = YES;
    __weak typeof(self) weakSelf = self;
    [self.presenter presentViewController:navigation animated:YES completion:^{
        [weakSelf.map deselectAnnotation:annotation animated:NO];
        [weakSelf setPollingVisible:YES];
    }];
    return YES;
}
@end

@implementation PSUShuttleDetailsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.rows = @[];
    self.message = NSLocalizedString(@"Loading arrivals…", nil);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_timer invalidate]; [_task cancel]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.appearing = YES; [self start]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.appearing = NO; [self stop]; }
- (void)background:(NSNotification *)note { [self stop]; }
- (void)foreground:(NSNotification *)note { if (self.view.window) [self start]; }
- (void)start {
    if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
        self.timer.tolerance = 1;
    }
    [self refresh];
}
- (void)stop { self.generation++; [self.timer invalidate]; self.timer = nil; [self.task cancel]; self.task = nil; }
- (void)refresh {
    if (!self.appearing || self.task || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.nextRequest.timeIntervalSinceNow > 0) return;
    BOOL vehicle = self.annotation.vehicle;
    NSDictionary *query = vehicle ? @{@"quantity": @"3", @"vehicleIdStrings": self.annotation.identifier.stringValue} :
        @{@"timesPerStop": @"2", @"routeIDs": self.annotation.routeID.stringValue, @"routeStopIDs": self.annotation.identifier.stringValue};
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    if (!self.received) { self.message = NSLocalizedString(@"Loading arrivals…", nil); [self.tableView reloadData]; }
    self.task = [self.client fetch:vehicle ? @"GetVehicleRouteStopEstimates" : @"GetStopArrivalTimes" query:query completion:^(NSArray *values, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.generation != generation) return;
        self.task = nil;
        self.nextRequest = [NSDate dateWithTimeIntervalSinceNow:error ? MIN(60, 20 * pow(2, MIN(2, ++self.failures))) : 20];
        if (error) self.message = self.rows.count ? NSLocalizedString(@"Showing last arrivals · Live data unavailable", nil) : NSLocalizedString(@"Live arrivals unavailable", nil);
        else {
            self.failures = 0;
            NSMutableArray *times = [NSMutableArray array];
            for (id raw in values) {
                if (![raw isKindOfClass:NSDictionary.class]) continue;
                if (vehicle) {
                    if (![PSUShuttleIdentifier(raw, @"VehicleID", @"VehicleId") isEqual:self.annotation.identifier]) continue;
                } else if (![PSUShuttleIdentifier(raw, @"RouteStopID", @"RouteStopId") isEqual:self.annotation.identifier] || ![PSUShuttleIdentifier(raw, @"RouteID", @"RouteId") isEqual:self.annotation.routeID]) continue;
                id items = raw[vehicle ? @"Estimates" : @"Times"];
                if ([items isKindOfClass:NSArray.class]) [times addObjectsFromArray:items];
            }
            self.received = NSDate.date;
            self.rows = PSUShuttleArrivalRows(times, self.received, vehicle ? 3 : 2);
            self.message = self.rows.count ? nil : (times.count ? NSLocalizedString(@"Current arrivals unavailable", nil) : NSLocalizedString(@"No upcoming arrivals", nil));
        }
        [self.tableView reloadData];
    }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MAX(1, self.rows.count); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.annotation.subtitle;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return self.rows.count ? self.message : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Arrival"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Arrival"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (!self.rows.count) { cell.textLabel.text = self.message; cell.detailTextLabel.text = nil; return cell; }
    NSDictionary *row = self.rows[indexPath.row];
    NSDate *arrival = row[@"arrival"];
    BOOL live = [row[@"live"] boolValue];
    NSInteger minutes = MAX(0, (NSInteger)ceil(arrival.timeIntervalSinceNow / 60));
    NSString *time = live ? (minutes ? [NSString localizedStringWithFormat:NSLocalizedString(@"Live · %ld min", nil), (long)minutes] : NSLocalizedString(@"Live · Arriving", nil)) :
        [NSString localizedStringWithFormat:NSLocalizedString(@"Scheduled · %@", nil), [NSDateFormatter localizedStringFromDate:arrival dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
    if (self.message || -self.received.timeIntervalSinceNow > 60) time = [NSString localizedStringWithFormat:NSLocalizedString(@"Last estimate · %@", nil), [NSDateFormatter localizedStringFromDate:arrival dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
    cell.textLabel.text = self.annotation.vehicle ? PSUShuttleString(row[@"Description"]) : time;
    NSNumber *vehicle = PSUShuttleIdentifier(row, @"VehicleID", @"VehicleId");
    cell.detailTextLabel.text = self.annotation.vehicle ? time : (vehicle ? [NSString localizedStringWithFormat:NSLocalizedString(@"Shuttle %@", nil), vehicle] : nil);
    return cell;
}
@end
