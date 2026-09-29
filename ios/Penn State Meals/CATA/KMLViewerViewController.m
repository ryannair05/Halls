/*
 Adapted from KMLViewerViewController.m by Apple Inc.

  Abstract:
  Displays an MKMapView and demonstrates how to use the included KMLParser class to place annotations and
 overlays from a parsed KML file on top of the MKMapView.
 */

@import MapKit;

#import "KMLParser.h"
#import "StopsPopupViewController.h"
#import "Annotations.h"
#include <math.h>
#import <objc/runtime.h>
#import "CATARouteDataSource.h"
#import "CATAGamedayRoutes.h"
#import "KMLViewerViewController.h"
#import "RouteListViewController.h"
#import "../Transit/PSUShuttleCoordinator.h"
#import <FirebaseAnalytics/FirebaseAnalytics.h>

static BOOL CATAObjectsEqual(id first, id second) {
    return first == second || [first isEqual:second];
}

// Route catalog colors are RGB hex; KML colors remain authoritative once loaded.
static UIColor *CATARouteColor(NSString *hex) {
    if (!hex.length) return nil;
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6) return nil;
    unsigned rgb = 0;
    for (NSUInteger i = 0; i < 6; ++i) {
        unichar c = [hex characterAtIndex:i];
        unsigned digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return nil;
        rgb = (rgb << 4) | digit;
    }
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
                          green:((rgb >> 8) & 255) / 255.0
                           blue:(rgb & 255) / 255.0 alpha:1.0];
}

// Runtime-only class declarations: no private-framework link dependency.
@interface _MKPuckAnnotationView : MKAnnotationView
@property(nonatomic) BOOL shouldDisplayHeading;
@property(nonatomic) double heading;
@property(nonatomic) double headingAccuracy;
@end
@interface _MKUserLocationView : _MKPuckAnnotationView
@end
@interface MKVariableDelayTapRecognizer : UITapGestureRecognizer
@end
@interface MKMapGestureController : NSObject
- (void)setZoomEnabled:(BOOL)enabled;
- (BOOL)isZoomEnabled;
- (double)variableDelayTapRecognizer:(MKVariableDelayTapRecognizer *)recognizer
     shouldWaitForNextTapForDuration:(double)duration
                          afterTouch:(UITouch *)touch;
@end

typedef double (*CATATapDelayIMP)(id, SEL, MKVariableDelayTapRecognizer *, double, UITouch *);
static CATATapDelayIMP CATAOriginalTapDelay;
static double CATAHookedTapDelay(__unsafe_unretained MKMapGestureController *controller, SEL command,
                                 MKVariableDelayTapRecognizer *recognizer, double duration, UITouch *touch) {
    // Preserve the existing zoom state around the original recognizer.
    BOOL enabled = [controller isZoomEnabled];
    if (enabled) [controller setZoomEnabled:NO];
    double result = CATAOriginalTapDelay(controller, command, recognizer, duration, touch);
    if (enabled) [controller setZoomEnabled:YES];
    return result;
}
static NSOperationQueue *CATAGeometryCompletionQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"CATA geometry parsing";
        queue.maxConcurrentOperationCount = 1;
        queue.qualityOfService = NSQualityOfServiceUtility;
    });
    return queue;
}

@interface KMLViewerViewController () <MKMapViewDelegate, CLLocationManagerDelegate> {
    NSDictionary<NSString *, NSNumber *> *selectedRoutes;
    NSDictionary<NSString *, NSNumber *> *preferredRoutes;
    CATAGamedayRoutes *gamedayRoutes;
    NSURLSessionDataTask *gamedayProbeTask;
    NSMutableDictionary<NSNumber *, BusAnnotation *> *busAnnotations;
    NSTimer *busTimer;
    NSURLSessionDataTask *activeVehicleTask;
    NSUInteger vehicleRouteGeneration;
    BOOL vehiclePollingSuspended;
    BOOL vehiclesAreStale;
    NSDate *lastVehicleUpdate;
    NSURLSession *transitSession;
    NSURLSession *routeSession;
    NSSet<NSNumber *> *selectedRouteIDSet;
    NSURL *vehiclePollingURL;
    NSMutableDictionary<NSNumber *, UIColor *> *routeColorsByID;
    NSMutableSet<NSNumber *> *missingVehicleIDs;
    BOOL didApplyVehicleAppearance;
    BOOL appliedVehiclesAreStale;
    _MKUserLocationView *userLocationView;
    BOOL didApplyMapConfiguration;
    MKMapType appliedMapType;
    BOOL didApplyNavigation;
    BOOL appliedNavigationShowsLayers;
    BOOL appliedNavigationShuttleLayer;
    MKMapType appliedNavigationMapType;
    CLLocationManager *locationManager;
    MKUserTrackingMode suspendedUserTrackingMode;
    BOOL didConfigureLocationTracking;
    NSMutableDictionary<NSString *, NSURLSessionDataTask *> *routeTraceTasks;
    NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *stopDetailTasks;
    NSMutableSet<NSNumber *> *loadedStopRouteIDs;
    NSMutableDictionary<NSNumber *, StopAnnotation *> *stopAnnotationsByID;
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *stopRouteOwnersByID;
    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *stopIDsByRouteID;
    BOOL didStartInitialRouteLoading;
    BOOL needsRouteFit;
    BOOL mapPresentationActive;
}

@property(nonatomic, strong) PSUShuttleCoordinator *shuttles;
@property(nonatomic) BOOL shuttleLayer;
@property(nonatomic) BOOL needsInitialShuttleFit;
@property(nonatomic) BOOL transitProUnlocked;
@property(nonatomic) BOOL refreshTransitAccessOnAppearance;
@property(nonatomic, strong) UIBarButtonItem *routesButton;
@property(nonatomic, strong) UIBarButtonItem *centerButton;
@property(nonatomic, strong, nullable) MKMapView *map;
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, KMLParser *> *activeRouteParsers;
@property(nonatomic, strong, nullable) NSNumber *pendingLinkedRouteID;
@property(nonatomic, strong, nullable) NSNumber *pendingLinkedStopID;
@property(nonatomic, assign) BOOL hasPendingLink;
@property(nonatomic, strong, nullable) NSUUID *linkedRequestID;

- (void)ensureShuttleCoordinator;
- (void)rebuildVehicleRequest;
- (void)applyRouteColor:(UIColor *)color forRouteID:(NSNumber *)routeID;
- (void)refreshOperationalRouteMetadata;
- (void)fitRoutesIfVisible;
- (void)updateLocationActivity;
- (void)reconcileSelectedRoutesWithRouteModels:(NSArray<RouteModel *> *)routeModels;
- (void)requestVehiclePoll;
- (BOOL)hasVisibleVehiclePollingSurface;
- (nullable StopsPopupViewController *)presentedDeparturesPopup;
- (void)scheduleNextVehiclePoll;
- (void)suspendVehiclePolling;
- (void)resumeVehiclePollingIfVisible;
- (void)applyVehicles:(NSArray<NSDictionary *> *)vehicles;
- (nullable BusAnnotation *)updateVehicle:(NSDictionary *)vehicle
                               vehicleID:(NSNumber *)vehicleID
                                 routeID:(NSNumber *)routeID;
- (void)removeStopsForRouteID:(NSNumber *)routeID;
- (void)removeBusesForRouteID:(NSNumber *)routeID;
- (nullable KMLParser *)routeParserForRouteID:(NSNumber *)routeID;

@end

@implementation KMLViewerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // KML has a separate serial queue so a large parse cannot delay delivery
    // of an already-completed vehicle poll. No per-route concurrent parsing.
    NSOperationQueue *completionQueue = [[NSOperationQueue alloc] init];
    completionQueue.name = @"CATA JSON responses";
    completionQueue.maxConcurrentOperationCount = 1;
    completionQueue.qualityOfService = NSQualityOfServiceUtility;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = 45;
    transitSession = [NSURLSession sessionWithConfiguration:configuration
                                                   delegate:nil
                                              delegateQueue:completionQueue];
    routeSession = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:nil
                                            delegateQueue:CATAGeometryCompletionQueue()];

    UIBarButtonItem *centerMapButton =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"scope"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(centerMap:)];

    UIBarButtonItem *routesButton =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showRouteList:)];

    self.routesButton = routesButton;
    self.centerButton = centerMapButton;

    if (@available(iOS 26.0, *)) {
        self.navigationItem.leftBarButtonItem = centerMapButton;
        self.navigationItem.rightBarButtonItem = routesButton;
    } else {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
        self.navigationItem.title = @"CATA Bus";
        self.navigationItem.rightBarButtonItems = @[ routesButton, centerMapButton ];
    }

    MKMapView *map = [[MKMapView alloc] initWithFrame:self.view.bounds];
    // Set the useful initial viewport before attaching the map to a window, so
    // MapKit doesn't first load a world view while route traces are downloading.
    map.region =
        MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(40.7982, -77.8599), 5000, 5000);
    self.map = map;
    // Apply the initial style before window attachment, not after a first render.
    self.transitProUnlocked = self.proAccessProvider ? self.proAccessProvider() : NO;
    if (self.transitProUnlocked) [self ensureShuttleCoordinator];
    [self applyTransitMapStyle];
    self.map.delegate = self;
    self.map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    NSUserActivity *activity =
        [[NSUserActivity alloc] initWithActivityType:@"com.ryannair05.pennstatemeals.cata"];
    activity.title = @"CATA Bus";
    activity.eligibleForSearch = true;
    activity.eligibleForPrediction = true;
    activity.eligibleForHandoff = true;
    self.userActivity = activity;

    locationManager = [[CLLocationManager alloc] init];
    locationManager.delegate = self;
    if (locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [locationManager requestWhenInUseAuthorization];
    }

    [self.view addSubview:map];

    busAnnotations = [[NSMutableDictionary alloc] init];
    routeTraceTasks = [[NSMutableDictionary alloc] init];
    stopDetailTasks = [[NSMutableDictionary alloc] init];
    loadedStopRouteIDs = [[NSMutableSet alloc] init];
    stopAnnotationsByID = [[NSMutableDictionary alloc] init];
    stopRouteOwnersByID = [[NSMutableDictionary alloc] init];
    stopIDsByRouteID = [[NSMutableDictionary alloc] init];
    vehiclePollingSuspended = YES;
    self.activeRouteParsers = [[NSMutableDictionary alloc] init];
    selectedRoutes = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"selectedRoutes"];
    if (selectedRoutes == nil) {
        selectedRoutes = @{@"Route51.kml" : @51, @"Route55.kml" : @55, @"Route57.kml" : @57};
    }
    preferredRoutes = selectedRoutes;
    routeColorsByID = [[NSMutableDictionary alloc] init];
    missingVehicleIDs = [[NSMutableSet alloc] init];
    [self rebuildVehicleRequest];
    gamedayRoutes = [[CATAGamedayRoutes alloc] init];
    [gamedayRoutes refreshDay:NSDate.date];
    [self refreshOperationalRouteMetadata];

    [self.map registerClass:[BusAnnotationView class] forAnnotationViewWithReuseIdentifier:kBusAnnotation];
    [self.map registerClass:[StopAnnotationView class] forAnnotationViewWithReuseIdentifier:kStopAnnotation];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(cata_applicationDidEnterBackground:)
                                               name:UIApplicationDidEnterBackgroundNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(cata_applicationDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

    if (self.transitProUnlocked && self.shuttles.selectedRouteIDs.count) {
        BOOL restoreShuttles = [NSUserDefaults.standardUserDefaults boolForKey:@"psuTransitShuttleLayer"];
        self.needsInitialShuttleFit = restoreShuttles;
        [self setShuttleLayerVisible:restoreShuttles];
        [self.shuttles loadRoutes:^{
        }];
    }

    if (!CATAOriginalTapDelay) {
        Method method = class_getInstanceMethod(objc_getClass("MKMapGestureController"),
            @selector(variableDelayTapRecognizer:shouldWaitForNextTapForDuration:afterTouch:));
        CATAOriginalTapDelay = (CATATapDelayIMP)method_setImplementation(method, (IMP)CATAHookedTapDelay);
    }
}

- (void)ensureShuttleCoordinator {
    if (self.shuttles || !self.map) return;
    self.shuttles = [[PSUShuttleCoordinator alloc] initWithMap:self.map presenter:self];
    __weak typeof(self) weakSelf = self;
    self.shuttles.routesDidChange = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self.needsInitialShuttleFit && self.shuttleLayer && self.shuttles.routes.count) {
            self.needsInitialShuttleFit = NO;
            [self.shuttles centerMap];
        }
        if ([self.presentedViewController isKindOfClass:RouteListViewController.class]) {
            [[(RouteListViewController *)self.presentedViewController tableView] reloadData];
        }
    };
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [transitSession invalidateAndCancel];
    [routeSession invalidateAndCancel];
    [locationManager stopUpdatingHeading];
    locationManager.delegate = nil;
    self.map.delegate = nil;
    [self.shuttles setPollingVisible:NO];
    [busTimer invalidate];
    [activeVehicleTask cancel];
    [gamedayProbeTask cancel];
    for (NSURLSessionDataTask *task in routeTraceTasks.allValues)
        [task cancel];
    for (NSURLSessionDataTask *task in stopDetailTasks.allValues)
        [task cancel];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self updateLocationActivity];
}

- (void)updateLocationActivity {
    CLAuthorizationStatus status = locationManager.authorizationStatus;
    BOOL authorized = status == kCLAuthorizationStatusAuthorizedWhenInUse ||
                      status == kCLAuthorizationStatusAuthorizedAlways;
    BOOL visible = mapPresentationActive && self.isViewLoaded && self.view.window != nil &&
                   UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (authorized && visible) {
        if (!self.map.showsUserLocation) {
            self.map.showsUserLocation = YES;
            [self.map setUserTrackingMode:didConfigureLocationTracking ? suspendedUserTrackingMode
                                                                       : MKUserTrackingModeFollowWithHeading
                                 animated:NO];
            didConfigureLocationTracking = YES;
        }
        self.map.showsUserTrackingButton = YES;
    } else if (self.map.showsUserLocation) {
        suspendedUserTrackingMode = self.map.userTrackingMode;
        [self.map setUserTrackingMode:MKUserTrackingModeNone animated:NO];
        self.map.showsUserLocation = NO;
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    userLocationView.heading = newHeading.trueHeading;
    userLocationView.headingAccuracy = newHeading.headingAccuracy;
}

- (void)openLinkedRoute:(NSNumber *)routeID stop:(NSNumber *)stopID {
    [self loadViewIfNeeded];
    [self setShuttleLayerVisible:NO];
    self.linkedRequestID = [NSUUID UUID];
    if (!self.view.window) {
        self.pendingLinkedRouteID = routeID;
        self.pendingLinkedStopID = stopID;
        self.hasPendingLink = YES;
        return;
    }
    NSUUID *requestID = self.linkedRequestID;
    __weak typeof(self) weakSelf = self;
    void (^navigate)(void) = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (routeID) {
            [CATARouteDataSource.shared
                loadVisibleRoutesWithMaximumAge:CATARouteOperationalCacheMaximumAge
                                notifyOnRefresh:NO
                                     completion:^(NSArray<RouteModel *> *routes, NSError *error) {
                                         __strong typeof(weakSelf) self = weakSelf;
                                         if (!self || ![self.linkedRequestID isEqual:requestID]) return;
                                         RouteModel *match = nil;
                                         for (RouteModel *route in routes) {
                                             if (route.routeId == routeID.integerValue) {
                                                 match = route;
                                                 break;
                                             }
                                         }
                                         NSString *traceFilename = match.traceFilename;
                                         if (traceFilename.length > 0) {
                                             [self handleSelectedRoutesChanged:@{traceFilename : routeID}];
                                         } else {
                                             UIAlertController *alert = [UIAlertController
                                                 alertControllerWithTitle:@"Route unavailable"
                                                                  message:@"This route could not be loaded "
                                                                          @"from CATA. Try again or choose "
                                                                          @"another route."
                                                           preferredStyle:UIAlertControllerStyleAlert];
                                             [alert addAction:[UIAlertAction
                                                                  actionWithTitle:@"OK"
                                                                            style:UIAlertActionStyleDefault
                                                                          handler:nil]];
                                             [self presentViewController:alert animated:YES completion:nil];
                                         }
                                     }];
        } else if (stopID) {
            StopAnnotation *known = self->stopAnnotationsByID[stopID];
            NSString *title = known.title ?: [NSString stringWithFormat:@"Stop %@", stopID];
            StopsPopupViewController *popup =
                [[StopsPopupViewController alloc] initWithTitle:title
                                                         stopId:stopID
                                                       location:0
                                                    annotations:self.activeRouteParsers];
            popup.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:popup
                               animated:YES
                             completion:^{
                                 [self resumeVehiclePollingIfVisible];
                             }];
        }
    };
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:NO completion:navigate];
    } else {
        navigate();
    }
}

- (void)showRouteList:(id)sender {
    [self ensureShuttleCoordinator];
    RouteListViewController *routeListVC =
        [[RouteListViewController alloc] initWithSavedData:preferredRoutes.allValues];
    routeListVC.viewController = self;
    routeListVC.shuttles = self.shuttles;
    routeListVC.shuttleProUnlocked = self.transitProUnlocked;
    __weak typeof(self) weakSelf = self;
    __weak RouteListViewController *weakList = routeListVC;
    routeListVC.requestShuttlePro = ^(void (^completion)(BOOL)) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self.presentPro || !weakList) {
            completion(NO);
            return;
        }
        self.presentPro(weakList, ^(BOOL unlocked) {
            if (unlocked) weakSelf.transitProUnlocked = YES;
            completion(unlocked);
        });
    };
    routeListVC.shuttleSelectionChanged = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self setShuttleLayerVisible:self.transitProUnlocked && self.shuttles.selectedRouteIDs.count > 0];
        [self applyTransitMapStyle];
    };

    routeListVC.modalPresentationStyle = UIModalPresentationFormSheet;
    routeListVC.sheetPresentationController.prefersEdgeAttachedInCompactHeight = YES;

    if (@available(iOS 26.0, *)) {
        routeListVC.preferredTransition =
            [UIViewControllerTransition zoomWithOptions:nil
                            sourceBarButtonItemProvider:^UIBarButtonItem *(
                                UIZoomTransitionSourceViewProviderContext *context) {
                                (void)context;
                                return weakSelf.routesButton;
                            }];
    }

    [self presentViewController:routeListVC animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    mapPresentationActive = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Only sample cached access at a real screen entry, never subscribe to transactions.
    if (self.refreshTransitAccessOnAppearance) {
        self.refreshTransitAccessOnAppearance = NO;
        self.transitProUnlocked = self.proAccessProvider ? self.proAccessProvider() : NO;
        if (!self.transitProUnlocked) [self setShuttleLayerVisible:NO];
        [self applyTransitMapStyle];
    }
    if (self.transitProUnlocked) [self ensureShuttleCoordinator];
    [self.shuttles setPollingVisible:self.shuttleLayer && mapPresentationActive];
    if (self.hasPendingLink) {
        NSNumber *routeID = self.pendingLinkedRouteID;
        NSNumber *stopID = self.pendingLinkedStopID;
        self.hasPendingLink = NO;
        self.pendingLinkedRouteID = nil;
        self.pendingLinkedStopID = nil;
        [self openLinkedRoute:routeID stop:stopID];
    }

    [self resumeVehiclePollingIfVisible];

    [self updateLocationActivity];
    [self fitRoutesIfVisible];

    CLAuthorizationStatus status = locationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        [locationManager startUpdatingHeading];
    }

    [FIRAnalytics logEventWithName:kFIREventScreenView parameters:@{kFIRParameterScreenName : @"CATA Bus"}];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    mapPresentationActive = NO;
    if (!self.presentedViewController) self.refreshTransitAccessOnAppearance = YES;
    [self.shuttles setPollingVisible:NO];
    if (![self presentedDeparturesPopup]) [self suspendVehiclePolling];
    [self updateLocationActivity];
}

- (void)cata_applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [locationManager stopUpdatingHeading];
    [self suspendVehiclePolling];
    [self.shuttles setPollingVisible:NO];
    [self updateLocationActivity];
}

- (void)cata_applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self resumeVehiclePollingIfVisible];
    [self.shuttles setPollingVisible:self.shuttleLayer && mapPresentationActive && self.isViewLoaded &&
                                     self.view.window != nil];
    [self updateLocationActivity];
    [self fitRoutesIfVisible];
    CLAuthorizationStatus status = locationManager.authorizationStatus;
    if (mapPresentationActive && self.isViewLoaded && self.view.window != nil &&
        (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways)) {
        [locationManager startUpdatingHeading];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self updateLocationActivity];
    [locationManager stopUpdatingHeading];
}

- (nullable StopsPopupViewController *)presentedDeparturesPopup {
    UIViewController *presented = self.presentedViewController;
    return [presented isKindOfClass:StopsPopupViewController.class] ? (StopsPopupViewController *)presented
                                                                    : nil;
}

- (BOOL)hasVisibleVehiclePollingSurface {
    if (self.shuttleLayer) return NO;
    StopsPopupViewController *popup = [self presentedDeparturesPopup];
    return (mapPresentationActive && self.isViewLoaded && self.view.window != nil) ||
           (popup.isViewLoaded && popup.view.window != nil && !popup.isBeingDismissed);
}

- (void)resumeVehiclePollingIfVisible {
    if (![self hasVisibleVehiclePollingSurface] ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return;
    // Repeated appearance / sheet callbacks must not turn a scheduled poll into
    // an extra immediate request. A genuine suspension has no live task/timer.
    if (!vehiclePollingSuspended && (activeVehicleTask || busTimer.isValid)) return;
    vehiclePollingSuspended = NO;
    if (!lastVehicleUpdate || -lastVehicleUpdate.timeIntervalSinceNow > 15) {
        vehiclesAreStale = YES;
        [self updateVehicleAnnotationAppearance];
    }
    [self requestVehiclePoll];
}

- (void)suspendVehiclePolling {
    vehiclePollingSuspended = YES;
    [[self presentedDeparturesPopup] cancelDepartureLoading];
    vehicleRouteGeneration += 1;
    [busTimer invalidate];
    busTimer = nil;
    [activeVehicleTask cancel];
    activeVehicleTask = nil;
    [gamedayProbeTask cancel];
    gamedayProbeTask = nil;
}

- (void)refreshOperationalRouteMetadata {
    __weak typeof(self) weakSelf = self;
    [CATARouteDataSource.shared
        loadVisibleRoutesWithMaximumAge:CATARouteOperationalCacheMaximumAge
                        notifyOnRefresh:YES
                             completion:^(NSArray<RouteModel *> *routeModels, NSError *error) {
                                 __strong typeof(weakSelf) self = weakSelf;
                                 if (!self) return;
                                 if (error || routeModels.count == 0) {
                                     if (!self->didStartInitialRouteLoading) {
                                         self->didStartInitialRouteLoading = YES;
                                         [self handleSelectedRoutesChanged:self->preferredRoutes];
                                     }
                                     return;
                                 }
                                 [self reconcileSelectedRoutesWithRouteModels:routeModels];
                             }];
}

- (void)reconcileSelectedRoutesWithRouteModels:(NSArray<RouteModel *> *)routeModels {
    [gamedayRoutes updateRouteCatalog:routeModels];
    for (RouteModel *route in routeModels) {
        NSNumber *routeID = @(route.routeId);
        id style = [self routeParserForRouteID:routeID].styles[@"routestyle"];
        UIColor *kmlColor = [style isKindOfClass:KMLStyle.class] ? [(KMLStyle *)style strokeColor] : nil;
        if (!kmlColor) {
            UIColor *color = CATARouteColor(route.color);
            if (color) [self applyRouteColor:color forRouteID:routeID];
        }
    }
    if (preferredRoutes.count == 0) {
        didStartInitialRouteLoading = YES;
        return;
    }

    NSSet<NSNumber *> *selectedRouteIDs = [NSSet setWithArray:preferredRoutes.allValues];
    NSMutableDictionary<NSString *, NSNumber *> *reconciledRoutes = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *matchedRouteIDs = [NSMutableSet set];
    for (RouteModel *route in routeModels) {
        NSNumber *routeID = @(route.routeId);
        NSString *traceFilename = route.traceFilename;
        if (![selectedRouteIDs containsObject:routeID] || traceFilename.length == 0) continue;
        reconciledRoutes[traceFilename] = routeID;
        [matchedRouteIDs addObject:routeID];
    }
    [preferredRoutes enumerateKeysAndObjectsUsingBlock:^(NSString *filename, NSNumber *routeID, BOOL *stop) {
        (void)stop;
        if (![matchedRouteIDs containsObject:routeID]) reconciledRoutes[filename] = routeID;
    }];

    BOOL changed = ![reconciledRoutes isEqualToDictionary:preferredRoutes];
    // The receiving method establishes the stored membership snapshot.
    NSDictionary<NSString *, NSNumber *> *nextRoutes = changed ? reconciledRoutes : preferredRoutes;
    if (changed) {
        [NSUserDefaults.standardUserDefaults setObject:nextRoutes forKey:@"selectedRoutes"];
    }
    BOOL effectiveChanged =
        ![[gamedayRoutes effectiveSelection:nextRoutes] isEqualToDictionary:selectedRoutes];
    if (!didStartInitialRouteLoading || changed || effectiveChanged) {
        didStartInitialRouteLoading = YES;
        [self handleSelectedRoutesChanged:nextRoutes];
    }
}

- (void)handleSelectedRoutesChanged:(NSDictionary<NSString *, NSNumber *> *)notification {
    NSDictionary *next =
        notification ?: [NSUserDefaults.standardUserDefaults dictionaryForKey:@"selectedRoutes"];
    if (!next) next = @{@"Route51.kml" : @51, @"Route55.kml" : @55, @"Route57.kml" : @57};
    if (![preferredRoutes isEqualToDictionary:next]) {
        [gamedayProbeTask cancel];
        gamedayProbeTask = nil;
        [activeVehicleTask cancel];
        activeVehicleTask = nil;
        [busTimer invalidate];
        busTimer = nil;
        vehicleRouteGeneration++;
    }
    preferredRoutes = [next copy];
    [gamedayRoutes retainOverridesForSelection:preferredRoutes];
    [self applySelectedRoutes:[gamedayRoutes effectiveSelection:preferredRoutes]];
    if (!vehiclePollingSuspended && !activeVehicleTask) [self requestVehiclePoll];
}

/// Applies effective routes without writing the user's saved selection. Gameday
/// substitutions only enter here, never the preference/picker membership path.
- (void)applySelectedRoutes:(NSDictionary<NSString *, NSNumber *> *)nextRoutes {
    NSDictionary<NSString *, NSNumber *> *previousRoutes = selectedRoutes ?: @{};
    selectedRoutes = [nextRoutes copy];

    BOOL selectionChanged = ![previousRoutes isEqualToDictionary:selectedRoutes];
    if (selectionChanged || !selectedRouteIDSet) [self rebuildVehicleRequest];
    if (selectionChanged) {
        vehicleRouteGeneration += 1;
        lastVehicleUpdate = nil;
        vehiclesAreStale = YES;
        [self updateVehicleAnnotationAppearance];
        [busTimer invalidate];
        busTimer = nil;
        [activeVehicleTask cancel];
        activeVehicleTask = nil;
    }

    NSSet<NSNumber *> *previousRouteIDs = [NSSet setWithArray:previousRoutes.allValues];
    NSSet<NSNumber *> *nextRouteIDs = [NSSet setWithArray:selectedRoutes.allValues];
    NSMutableSet<NSNumber *> *removedRouteIDs = [previousRouteIDs mutableCopy];
    [removedRouteIDs minusSet:nextRouteIDs];
    for (NSNumber *routeID in removedRouteIDs) {
        [self removeStopsForRouteID:routeID];
        [self removeBusesForRouteID:routeID];
    }

    NSMutableSet<NSString *> *knownRouteKeys =
        [NSMutableSet setWithArray:self.activeRouteParsers.allKeys ?: @[]];
    [knownRouteKeys addObjectsFromArray:routeTraceTasks.allKeys];
    NSSet<NSString *> *desiredRouteKeys = [NSSet setWithArray:selectedRoutes.allKeys];

    NSMutableSet<NSString *> *removedRouteKeys = [knownRouteKeys mutableCopy];
    [removedRouteKeys minusSet:desiredRouteKeys];
    NSMutableSet<NSString *> *addedRouteKeys = [desiredRouteKeys mutableCopy];
    [addedRouteKeys minusSet:knownRouteKeys];

    // Fit once when all currently selected traces are ready. An older download
    // group cannot move the camera after a newer selection or a tab switch.
    BOOL geometryChanged = selectionChanged || addedRouteKeys.count || removedRouteKeys.count;
    if (geometryChanged) needsRouteFit = YES;

    for (NSString *routeKey in removedRouteKeys) {
        [routeTraceTasks[routeKey] cancel];
        [routeTraceTasks removeObjectForKey:routeKey];
        KMLParser *parser = self.activeRouteParsers[routeKey];
        if (parser) {
            [self.map removeOverlays:parser.overlays];
            [self.activeRouteParsers removeObjectForKey:routeKey];
        }
    }

    for (NSString *routeKey in [addedRouteKeys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        NSNumber *expectedRouteID = selectedRoutes[routeKey];
        NSURL *routeURL = [NSURL URLWithString:[@"https://realtime.catabus.com/InfoPoint/Resources/Traces/"
                                                   stringByAppendingString:routeKey]];
        if (!routeURL) continue;
        __weak typeof(self) weakSelf = self;
        __block __weak NSURLSessionDataTask *weakTask;
        NSURLSessionDataTask *downloadTask = [routeSession
            dataTaskWithURL:routeURL
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                  NSURLSessionDataTask *finishedTask = weakTask;
                  if (!finishedTask || !weakSelf) return;
                  NSHTTPURLResponse *http =
                      [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
                  KMLParser *parser = nil;
                  if (!error && data.length && http.statusCode == 200 &&
                      finishedTask.state != NSURLSessionTaskStateCanceling) {
                      parser = [[KMLParser alloc] initWithData:data];
                      parser.includesPointAnnotations = NO;
                      [parser parseKML]; // Includes geometry construction, on this serial worker queue.
                      if (parser.parseError) {
                          NSLog(@"KML rejected: %@", parser.parseError);
                          parser = nil;
                      }
                  }
                  dispatch_async(dispatch_get_main_queue(), ^{
                      __strong typeof(weakSelf) self = weakSelf;
                      if (!self) return;
                      BOOL current = self->routeTraceTasks[routeKey] == finishedTask;
                      if (!current) return;
                      [self->routeTraceTasks removeObjectForKey:routeKey];
                      if ([self->selectedRoutes[routeKey] isEqual:expectedRouteID]) {
                          if (parser) {
                              KMLParser *old = self.activeRouteParsers[routeKey];
                              if (old) [self.map removeOverlays:old.overlays];
                              self.activeRouteParsers[routeKey] = parser;
                              id style = parser.styles[@"routestyle"];
                              UIColor *color = [style isKindOfClass:KMLStyle.class]
                                                   ? [(KMLStyle *)style strokeColor]
                                                   : nil;
                              if (color) [self applyRouteColor:color forRouteID:expectedRouteID];
                              if (!self.shuttleLayer) [self.map addOverlays:parser.overlays];
                          }
                          [self loadStopsFor:expectedRouteID.stringValue];
                      }
                      [self fitRoutesIfVisible];
                  });
              }];
        weakTask = downloadTask;
        routeTraceTasks[routeKey] = downloadTask;
        [downloadTask resume];
    }

    [self fitRoutesIfVisible];

    if (selectionChanged && !vehiclePollingSuspended) [self requestVehiclePoll];
}

- (void)applyRouteColor:(UIColor *)color forRouteID:(NSNumber *)routeID {
    if ([routeColorsByID[routeID] isEqual:color]) return;
    routeColorsByID[routeID] = color;
    // Geometry and vehicle responses arrive independently. Reveal/recolor the
    // current buses now instead of waiting for the next polling response.
    for (NSNumber *vehicleID in busAnnotations) {
        BusAnnotation *bus = busAnnotations[vehicleID];
        if (![bus.routeId isEqual:routeID]) continue;
        bus.busColor = color;
        BusAnnotationView *view = (BusAnnotationView *)[self.map viewForAnnotation:bus];
        if ([view isKindOfClass:BusAnnotationView.class]) {
            [view animateToCoordinate:bus.coordinate withHeading:bus.heading];
        }
    }
}

- (KMLParser *)routeParserForRouteID:(NSNumber *)routeID {
    if (!routeID) return nil;
    for (NSString *routeKey in selectedRoutes) {
        if ([selectedRoutes[routeKey] isEqual:routeID]) {
            KMLParser *parser = self.activeRouteParsers[routeKey];
            if (parser) return parser;
        }
    }
    return nil;
}

- (void)removeStopsForRouteID:(NSNumber *)routeID {
    [stopDetailTasks[routeID] cancel];
    [stopDetailTasks removeObjectForKey:routeID];
    [loadedStopRouteIDs removeObject:routeID];

    NSSet<NSNumber *> *stopIDs = stopIDsByRouteID[routeID];
    [stopIDsByRouteID removeObjectForKey:routeID];
    for (NSNumber *stopID in stopIDs) {
        NSMutableSet<NSNumber *> *owners = stopRouteOwnersByID[stopID];
        [owners removeObject:routeID];
        if (owners.count > 0) continue;

        StopAnnotation *annotation = stopAnnotationsByID[stopID];
        if (annotation) [self.map removeAnnotation:annotation];
        [stopAnnotationsByID removeObjectForKey:stopID];
        [stopRouteOwnersByID removeObjectForKey:stopID];
    }
}

- (void)removeBusesForRouteID:(NSNumber *)routeID {
    NSMutableArray<NSNumber *> *vehicleIDs = [NSMutableArray array];
    [busAnnotations
        enumerateKeysAndObjectsUsingBlock:^(NSNumber *vehicleID, BusAnnotation *annotation, BOOL *stop) {
            (void)stop;
            if ([annotation.routeId isEqual:routeID]) [vehicleIDs addObject:vehicleID];
        }];
    for (NSNumber *vehicleID in vehicleIDs) {
        BusAnnotation *annotation = busAnnotations[vehicleID];
        if (annotation) [self.map removeAnnotation:annotation];
        [busAnnotations removeObjectForKey:vehicleID];
    }
}

- (void)fitRoutesIfVisible {
    if (!needsRouteFit || routeTraceTasks.count > 0 || self.shuttleLayer || !mapPresentationActive ||
        !self.isViewLoaded || !self.view.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return;
    needsRouteFit = NO;
    // Startup and background route changes need one final viewport, not an
    // animated flight that loads and renders intermediate map tiles.
    [self centerMap:nil];
}

- (void)centerMap:(id)sender {
    if (self.shuttleLayer) {
        [self.shuttles centerMap];
        return;
    }
    MKMapRect flyTo = MKMapRectNull;
    for (KMLParser *parser in self.activeRouteParsers.allValues) {
        for (id<MKOverlay> overlay in parser.overlays) {
            flyTo = MKMapRectUnion(flyTo, overlay.boundingMapRect);
        }
    }

    // All routes can be deselected, or their traces can fail to load.
    if (MKMapRectIsNull(flyTo) || MKMapRectIsEmpty(flyTo)) return;
    [self.map setVisibleMapRect:flyTo animated:sender != nil];
}

- (void)loadStopsFor:(NSString *)stop {
    NSNumber *requestedRouteID = @(stop.integerValue);
    if ([loadedStopRouteIDs containsObject:requestedRouteID] ||
        stopDetailTasks[requestedRouteID] != nil)
        return;

    NSURL *routeURL = [NSURL URLWithString:[@"https://realtime.catabus.com/InfoPoint/rest/RouteDetails/Get/"
                                               stringByAppendingString:stop]];
    if (!routeURL) return;
    __weak typeof(self) weakSelf = self;
    __block __weak NSURLSessionDataTask *weakTask;
    NSURLSessionDataTask *downloadTask = [transitSession
          dataTaskWithURL:routeURL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSURLSessionDataTask *finishedTask = weakTask;
            if (!finishedTask || !weakSelf) return;
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id payload = nil;
            if (!error && data.length > 0 && httpResponse.statusCode == 200) {
                payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            }

            NSDictionary *jsonResponse =
                [payload isKindOfClass:NSDictionary.class] ? (NSDictionary *)payload : nil;
            NSArray *stops =
                [jsonResponse[@"Stops"] isKindOfClass:NSArray.class] ? jsonResponse[@"Stops"] : nil;
            BOOL validResponse = !error && httpResponse.statusCode == 200 && !jsonError &&
                                 jsonResponse != nil && stops != nil;

            NSMutableDictionary<NSNumber *, StopAnnotation *> *parsedStops =
                [NSMutableDictionary dictionary];
            if (validResponse) {
                for (id value in stops) {
                    if (![value isKindOfClass:NSDictionary.class]) {
                        validResponse = NO;
                        break;
                    }
                    NSDictionary *stopJSON = value;
                    NSString *name =
                        [stopJSON[@"Name"] isKindOfClass:NSString.class] ? stopJSON[@"Name"] : nil;
                    NSNumber *latitude = [stopJSON[@"Latitude"] isKindOfClass:NSNumber.class]
                                             ? stopJSON[@"Latitude"]
                                             : nil;
                    NSNumber *longitude = [stopJSON[@"Longitude"] isKindOfClass:NSNumber.class]
                                              ? stopJSON[@"Longitude"]
                                              : nil;
                    NSNumber *stopID =
                        [stopJSON[@"StopId"] isKindOfClass:NSNumber.class] ? stopJSON[@"StopId"] : nil;
                    CLLocationCoordinate2D coordinate =
                        CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
                    if (!name || !stopID || !latitude || !longitude ||
                        !CLLocationCoordinate2DIsValid(coordinate))
                        continue;
                    StopAnnotation *stopAnnotation = [[StopAnnotation alloc] init];
                    stopAnnotation.stopId = stopID;
                    stopAnnotation.title = name;
                    stopAnnotation.coordinate = coordinate;
                    parsedStops[stopID] = stopAnnotation;
                    // This plain NSObject is unpublished on the worker. All
                    // mutation/observation after handoff remains on the main thread.
                }
            }

            NSMutableDictionary<NSNumber *, NSDictionary *> *vehicleJSONByID =
                [NSMutableDictionary dictionary];
            NSArray *vehicles =
                [jsonResponse[@"Vehicles"] isKindOfClass:NSArray.class] ? jsonResponse[@"Vehicles"] : @[];
            for (id value in vehicles) {
                if (![value isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *vehicle = value;
                NSNumber *vehicleID =
                    [vehicle[@"VehicleId"] isKindOfClass:NSNumber.class] ? vehicle[@"VehicleId"] : nil;
                if (vehicleID) vehicleJSONByID[vehicleID] = vehicle;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self->stopDetailTasks[requestedRouteID] != finishedTask) return;
                [self->stopDetailTasks removeObjectForKey:requestedRouteID];
                if (!validResponse) {
                    if (error.code != NSURLErrorCancelled) {
                        NSLog(@"Error loading route %@ details: %@", requestedRouteID,
                    error.localizedDescription ?: jsonError.localizedDescription ?: @"Invalid response");
                    }
                    return;
                }
                if (![self->selectedRoutes.allValues containsObject:requestedRouteID]) return;

                [self->loadedStopRouteIDs addObject:requestedRouteID];

                NSMutableSet<NSNumber *> *routeStopIDs =
                    [NSMutableSet setWithCapacity:parsedStops.count];
                NSMutableArray<StopAnnotation *> *newStops = [NSMutableArray array];
                [parsedStops enumerateKeysAndObjectsUsingBlock:^(
                                 NSNumber *stopID, StopAnnotation *stopData, BOOL *stopEnumeration) {
                    (void)stopEnumeration;
                    [routeStopIDs addObject:stopID];
                    NSMutableSet<NSNumber *> *owners = self->stopRouteOwnersByID[stopID];
                    if (!owners) {
                        owners = [NSMutableSet set];
                        self->stopRouteOwnersByID[stopID] = owners;
                    }
                    [owners addObject:requestedRouteID];

                    StopAnnotation *annotation = self->stopAnnotationsByID[stopID];
                    if (!annotation) {
                        annotation = stopData;
                        self->stopAnnotationsByID[stopID] = annotation;
                        [newStops addObject:annotation];
                    }
                    if (!CATAObjectsEqual(annotation.title, stopData.title))
                        annotation.title = stopData.title;
                    CLLocationCoordinate2D coordinate = stopData.coordinate;
                    if (annotation.coordinate.latitude != coordinate.latitude ||
                        annotation.coordinate.longitude != coordinate.longitude)
                        annotation.coordinate = coordinate;
                }];
                self->stopIDsByRouteID[requestedRouteID] = [routeStopIDs copy];
                if (!self.shuttleLayer) [self.map addAnnotations:newStops];

                NSMutableArray<BusAnnotation *> *newBuses = [NSMutableArray array];
                [vehicleJSONByID enumerateKeysAndObjectsUsingBlock:^(NSNumber *vehicleID,
                                                                     NSDictionary *vehicle,
                                                                     BOOL *stopEnumeration) {
                    (void)stopEnumeration;
                    if (self->busAnnotations[vehicleID]) return;

                    BusAnnotation *annotation = [self updateVehicle:vehicle
                                                          vehicleID:vehicleID
                                                            routeID:requestedRouteID];
                    if (annotation) [newBuses addObject:annotation];
                }];
                if (!self.shuttleLayer) [self.map addAnnotations:newBuses];
                [self updateVehicleAnnotationAppearance];
            });
        }];
    weakTask = downloadTask;
    stopDetailTasks[requestedRouteID] = downloadTask;
    [downloadTask resume];
}

- (void)rebuildVehicleRequest {
    selectedRouteIDSet = [NSSet setWithArray:selectedRoutes.allValues ?: @[]];
    NSArray<NSNumber *> *routeIDs =
        [selectedRouteIDSet.allObjects sortedArrayUsingSelector:@selector(compare:)];
    vehiclePollingURL =
        routeIDs.count
            ? [NSURL URLWithString:[@"https://realtime.catabus.com/InfoPoint/rest/Vehicles/"
                                    @"GetAllVehiclesForRoutes?routeIDs="
                                       stringByAppendingString:[routeIDs componentsJoinedByString:@","]]]
            : nil;
}

- (void)requestVehiclePoll {
    [busTimer invalidate];
    busTimer = nil;

    if (vehiclePollingSuspended || activeVehicleTask || ![self hasVisibleVehiclePollingSurface] ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return;

    if ([gamedayRoutes refreshDay:NSDate.date]) {
        [self applySelectedRoutes:[gamedayRoutes effectiveSelection:preferredRoutes]];
        return;
    }
    [[self presentedDeparturesPopup] refreshDeparturesIfVisible];

    if (selectedRouteIDSet.count == 0) {
        [self.map removeAnnotations:busAnnotations.allValues];
        [busAnnotations removeAllObjects];
        if ([self presentedDeparturesPopup]) [self scheduleNextVehiclePoll];
        return;
    }
    NSUInteger generation = vehicleRouteGeneration;
    NSURL *url = vehiclePollingURL;
    if (!url) {
        [self scheduleNextVehiclePoll];
        return;
    }

    __weak typeof(self) weakSelf = self;
    activeVehicleTask = [transitSession
          dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id payload = nil;
            if (!error && data.length > 0 && httpResponse.statusCode == 200) {
                payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            }

            BOOL validResponse = !error && httpResponse.statusCode == 200 && !jsonError &&
                                 [payload isKindOfClass:NSArray.class];
            NSArray<NSDictionary *> *vehicles = validResponse ? payload : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self->vehicleRouteGeneration != generation) return;

                self->activeVehicleTask = nil;
                if (self->vehiclePollingSuspended || ![self hasVisibleVehiclePollingSurface]) return;

                if (validResponse) {
                    self->lastVehicleUpdate = NSDate.date;
                    self->vehiclesAreStale = NO;
                    [self applyVehicles:vehicles];
                    [self updateVehicleAnnotationAppearance];
                    [self checkGamedayRoutesAfterSuccessfulPoll];
                } else if (error.code != NSURLErrorCancelled) {
                    self->vehiclesAreStale = YES;
                    [self updateVehicleAnnotationAppearance];
                    NSLog(@"Error loading CATA vehicles: %@",
                error.localizedDescription ?: jsonError.localizedDescription ?: @"Invalid response");
                }
                [self scheduleNextVehiclePoll];
            });
        }];
    [activeVehicleTask resume];
}

- (void)checkGamedayRoutesAfterSuccessfulPoll {
    // The weekday/calendar is cached until local midnight. No extra work or
    // requests on ordinary days, and failed vehicle responses never trigger it.
    if (gamedayProbeTask || ![gamedayRoutes shouldCheckAtDate:lastVehicleUpdate]) return;
    NSMutableSet *visibleRouteIDs = [NSMutableSet set];
    for (BusAnnotation *bus in busAnnotations.allValues)
        if (bus.routeId) [visibleRouteIDs addObject:bus.routeId];
    NSDictionary<NSNumber *, RouteModel *> *candidates =
        [gamedayRoutes candidatesForSelection:preferredRoutes
                              visibleRouteIDs:visibleRouteIDs
                                         date:lastVehicleUpdate];
    if (!candidates.count) return;
    NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:candidates.count];
    for (RouteModel *route in candidates.allValues)
        [identifiers addObject:@(route.routeId)];
    NSString *url = [@"https://realtime.catabus.com/InfoPoint/rest/Vehicles/GetAllVehiclesForRoutes?routeIDs="
        stringByAppendingString:[identifiers componentsJoinedByString:@","]];
    NSUInteger generation = vehicleRouteGeneration;
    __weak typeof(self) weakSelf = self;
    __block __weak NSURLSessionDataTask *weakProbe;
    NSURLSessionDataTask *probe = [transitSession
          dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSURLSessionDataTask *finishedProbe = weakProbe;
            if (!finishedProbe || !weakSelf) return;
            NSHTTPURLResponse *http =
                [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
            id values = !error && http.statusCode == 200 && data.length
                            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                            : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self->gamedayProbeTask != finishedProbe) return;
                self->gamedayProbeTask = nil;
                if (self->vehicleRouteGeneration != generation || self->vehiclePollingSuspended ||
                    ![values isKindOfClass:NSArray.class])
                    return;
                if ([self->gamedayRoutes refreshDay:NSDate.date]) {
                    [self applySelectedRoutes:[self->gamedayRoutes
                                                  effectiveSelection:self->preferredRoutes]];
                    return;
                }
                // A regular bus may have appeared while this independent probe ran.
                NSMutableDictionary *stillEmpty = [candidates mutableCopy];
                for (BusAnnotation *bus in self->busAnnotations.allValues)
                    if (bus.routeId) [stillEmpty removeObjectForKey:bus.routeId];
                if ([self->gamedayRoutes acceptVehicles:values candidates:stillEmpty]) {
                    [self applySelectedRoutes:[self->gamedayRoutes
                                                  effectiveSelection:self->preferredRoutes]];
                }
            });
        }];
    weakProbe = probe;
    gamedayProbeTask = probe;
    [probe resume];
}

- (void)updateVehicleAnnotationAppearance {
    if (didApplyVehicleAppearance && appliedVehiclesAreStale == vehiclesAreStale) return;
    didApplyVehicleAppearance = YES;
    appliedVehiclesAreStale = vehiclesAreStale;
    // Newly dequeued views receive the current alpha in viewForAnnotation:.
    for (NSNumber *vehicleID in busAnnotations) {
        BusAnnotation *bus = busAnnotations[vehicleID];
        MKAnnotationView *view = [self.map viewForAnnotation:bus];
        CGFloat alpha = vehiclesAreStale ? 0.55 : 1.0;
        if (view && view.alpha != alpha) view.alpha = alpha;
    }
}

- (void)scheduleNextVehiclePoll {
    [busTimer invalidate];
    busTimer = nil;
    if (vehiclePollingSuspended || activeVehicleTask || ![self hasVisibleVehiclePollingSurface] ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return;

    // Preserve the original completion-relative cadence and tolerance exactly.
    NSTimeInterval interval = NSProcessInfo.processInfo.lowPowerModeEnabled ? 4.5 : 3.5;
    __weak typeof(self) weakSelf = self;
    busTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                               repeats:NO
                                                 block:^(NSTimer *timer) {
                                                     (void)timer;
                                                     [weakSelf requestVehiclePoll];
                                                 }];
    busTimer.tolerance = 0.5;
}

- (void)applyVehicles:(NSArray<NSDictionary *> *)vehicles {
    [missingVehicleIDs removeAllObjects];
    for (NSNumber *vehicleID in busAnnotations)
        [missingVehicleIDs addObject:vehicleID];

    for (id value in vehicles) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *vehicle = value;
        NSNumber *vehicleID =
            [vehicle[@"VehicleId"] isKindOfClass:NSNumber.class] ? vehicle[@"VehicleId"] : nil;
        __unsafe_unretained NSNumber *routeID =
            [vehicle[@"RouteId"] isKindOfClass:NSNumber.class] ? vehicle[@"RouteId"] : nil;
        if (!vehicleID || !routeID || ![selectedRouteIDSet containsObject:routeID]) continue;
        [missingVehicleIDs removeObject:vehicleID];

        BOOL isNew = busAnnotations[vehicleID] == nil;
        BusAnnotation *bus = [self updateVehicle:vehicle vehicleID:vehicleID routeID:routeID];
        if (isNew && bus) [self.map addAnnotation:bus];
    }

    for (NSNumber *vehicleID in missingVehicleIDs) {
        BusAnnotation *annotation = busAnnotations[vehicleID];
        if (annotation) [self.map removeAnnotation:annotation];
        [busAnnotations removeObjectForKey:vehicleID];
    }
    [missingVehicleIDs removeAllObjects]; // Do not retain removed identifiers until the next tick.
}

// Both route details and live polls use the same field parsing and annotation updates.
- (BusAnnotation *)updateVehicle:(NSDictionary *)vehicle
                      vehicleID:(NSNumber *)vehicleID
                        routeID:(NSNumber *)routeID {
    __unsafe_unretained NSNumber *latitude =
        [vehicle[@"Latitude"] isKindOfClass:NSNumber.class] ? vehicle[@"Latitude"] : nil;
    __unsafe_unretained NSNumber *longitude =
        [vehicle[@"Longitude"] isKindOfClass:NSNumber.class] ? vehicle[@"Longitude"] : nil;
    CLLocationCoordinate2D coordinate =
        CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!latitude || !longitude || !CLLocationCoordinate2DIsValid(coordinate)) return nil;

    __unsafe_unretained NSNumber *headingValue =
        [vehicle[@"Heading"] isKindOfClass:NSNumber.class] ? vehicle[@"Heading"] : nil;
    CLLocationDegrees heading = headingValue ? headingValue.doubleValue : 0;
    heading = isfinite(heading) ? fmod(fmod(heading, 360.0) + 360.0, 360.0) : 0;
    __unsafe_unretained NSNumber *onBoard =
        [vehicle[@"OnBoard"] isKindOfClass:NSNumber.class] ? vehicle[@"OnBoard"] : nil;
    __unsafe_unretained NSNumber *seatingCapacity =
        [vehicle[@"SeatingCapacity"] isKindOfClass:NSNumber.class] ? vehicle[@"SeatingCapacity"]
                                                                   : nil;
    __unsafe_unretained NSString *destination =
        [vehicle[@"Destination"] isKindOfClass:NSString.class] ? vehicle[@"Destination"] : @"Unknown";
    __unsafe_unretained NSString *direction =
        [vehicle[@"Direction"] isKindOfClass:NSString.class] ? vehicle[@"Direction"] : @"N/A";
    __unsafe_unretained NSString *lastUpdated =
        [vehicle[@"LastUpdated"] isKindOfClass:NSString.class] ? vehicle[@"LastUpdated"] : nil;
    BusAnnotation *bus = busAnnotations[vehicleID];
    UIColor *busColor = routeColorsByID[routeID];
    if (!bus) {
        bus = [[BusAnnotation alloc] initWithCoordinate:coordinate
                                                  title:destination
                                               subtitle:direction];
        bus.busColor = busColor;
        bus.routeId = routeID;
        bus.heading = heading;
        bus.onBoard = onBoard;
        bus.seatingCapacity = seatingCapacity;
        bus.lastUpdated = lastUpdated;
        busAnnotations[vehicleID] = bus;
        return bus;
    }

    BOOL coordinateChanged = bus.coordinate.latitude != coordinate.latitude ||
                             bus.coordinate.longitude != coordinate.longitude;
    BOOL headingChanged = bus.heading != heading;
    BOOL contentChanged =
        !CATAObjectsEqual(bus.onBoard, onBoard) ||
        !CATAObjectsEqual(bus.seatingCapacity, seatingCapacity) ||
        !CATAObjectsEqual(bus.title, destination) || !CATAObjectsEqual(bus.subtitle, direction) ||
        !CATAObjectsEqual(bus.routeId, routeID) || !CATAObjectsEqual(bus.busColor, busColor);

    // The public VehicleLocation schema only types LastUpdated as a date-time; it does
    // not define it as a revision token. It also cannot cover locally loaded route color.
    // Compare every field that affects the map UI before doing more expensive view work.
    bus.lastUpdated = lastUpdated;
    if (!coordinateChanged && !headingChanged && !contentChanged) return bus;

    if (!CATAObjectsEqual(bus.title, destination)) bus.title = destination;
    if (!CATAObjectsEqual(bus.subtitle, direction)) bus.subtitle = direction;
    bus.busColor = busColor;
    bus.routeId = routeID;
    bus.onBoard = onBoard;
    bus.seatingCapacity = seatingCapacity;

    BusAnnotationView *annotationView = (BusAnnotationView *)[self.map viewForAnnotation:bus];
    if ([annotationView isKindOfClass:BusAnnotationView.class]) {
        [annotationView animateToCoordinate:coordinate withHeading:heading];
    } else {
        if (coordinateChanged) bus.coordinate = coordinate;
        if (headingChanged) bus.heading = heading;
    }
    return bus;
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    id<MKAnnotation> annotation = view.annotation;
    if ([self.shuttles selectAnnotation:annotation]) return;

    if ([annotation isMemberOfClass:[StopAnnotation class]]) {
        StopAnnotation *annotation = view.annotation;
        CLLocationCoordinate2D stopCoordinate = annotation.coordinate;

        CLLocation *stopLocation = [[CLLocation alloc] initWithLatitude:stopCoordinate.latitude
                                                              longitude:stopCoordinate.longitude];
        CLLocationDistance locationDistance =
            [mapView.userLocation.location distanceFromLocation:stopLocation];

        NSNumber *stopID = annotation.stopId;
        if (!stopID) return;
        StopsPopupViewController *popupVC =
            [[StopsPopupViewController alloc] initWithTitle:annotation.title
                                                     stopId:stopID
                                                   location:locationDistance
                                                annotations:_activeRouteParsers];
        popupVC.modalPresentationStyle = UIModalPresentationPageSheet;
        popupVC.sheetPresentationController.detents = @[
            [UISheetPresentationControllerDetent mediumDetent],
            [UISheetPresentationControllerDetent largeDetent]
        ];
        popupVC.sheetPresentationController.prefersGrabberVisible = YES;

        if (@available(iOS 17.5, *)) {
            [[UIImpactFeedbackGenerator feedbackGeneratorForView:self.view]
                impactOccurredAtLocation:view.frame.origin];
        } else {
            [[[UIImpactFeedbackGenerator alloc] init] impactOccurred];
        }
        [self presentViewController:popupVC
                           animated:YES
                         completion:^{
                             [mapView deselectAnnotation:view.annotation animated:NO];
                             [self resumeVehiclePollingIfVisible];
                         }];
    }
}

#pragma mark - Transit layers

- (void)setShuttleLayerVisible:(BOOL)visible {
    if (visible && self.transitProUnlocked) [self ensureShuttleCoordinator];
    visible = visible && self.transitProUnlocked && self.shuttles.selectedRouteIDs.count > 0;
    if (!visible) self.needsInitialShuttleFit = NO;
    if (self.shuttleLayer != visible) {
        [self suspendVehiclePolling];
        self.shuttleLayer = visible;
        if (visible) {
            for (KMLParser *parser in self.activeRouteParsers.allValues)
                [self.map removeOverlays:parser.overlays];
            [self.map removeAnnotations:stopAnnotationsByID.allValues];
            [self.map removeAnnotations:busAnnotations.allValues];
            [self.shuttles setActive:YES];
            [self.shuttles setPollingVisible:mapPresentationActive && self.view.window != nil &&
                                             UIApplication.sharedApplication.applicationState ==
                                                 UIApplicationStateActive];
        } else {
            [self.shuttles setActive:NO];
            for (KMLParser *parser in self.activeRouteParsers.allValues)
                [self.map addOverlays:parser.overlays];
            [self.map addAnnotations:stopAnnotationsByID.allValues];
            [self.map addAnnotations:busAnnotations.allValues];
            [self resumeVehiclePollingIfVisible];
        }
    }
    [NSUserDefaults.standardUserDefaults setBool:visible forKey:@"psuTransitShuttleLayer"];
    [self updateTransitNavigation];
}

- (void)applyTransitMapStyle {
    NSInteger style = [NSUserDefaults.standardUserDefaults integerForKey:@"psuTransitMapStyle"];
    if (style == MKMapTypeHybrid) {
        style = MKMapTypeSatellite;
        [NSUserDefaults.standardUserDefaults setInteger:style forKey:@"psuTransitMapStyle"];
    }
    BOOL allowed = self.transitProUnlocked && self.shuttles.selectedRouteIDs.count > 0;
    MKMapType desiredType = allowed && style == MKMapTypeSatellite ? style : MKMapTypeStandard;
    // Install only when the effective style changes. Reapplying a configuration
    // on every appearance/poll can invalidate work already held by MapKit.
    if (!didApplyMapConfiguration || appliedMapType != desiredType) {
        if (desiredType == MKMapTypeSatellite) {
            self.map.preferredConfiguration =
                [[MKImageryMapConfiguration alloc] initWithElevationStyle:MKMapElevationStyleFlat];
        } else {
            MKStandardMapConfiguration *configuration = [[MKStandardMapConfiguration alloc] init];
            configuration.pointOfInterestFilter = MKPointOfInterestFilter.filterIncludingAllCategories;
            configuration.showsTraffic = NO;
            self.map.preferredConfiguration = configuration;
        }
        self.map.showsBuildings = YES;
        self.map.pitchEnabled = YES;
        appliedMapType = desiredType;
        didApplyMapConfiguration = YES;
    }
    [self updateTransitNavigation];
}

- (void)updateTransitNavigation {
    BOOL showLayers = self.transitProUnlocked && self.shuttles.selectedRouteIDs.count > 0;
    MKMapType mapType = self.map.mapType;
    // This method owns these menu items. Only these state values affect them;
    // repeated style/appearance callbacks must not rebuild identical UIActions,
    // menus, bar buttons and item groups.
    if (didApplyNavigation && appliedNavigationShowsLayers == showLayers &&
        appliedNavigationShuttleLayer == self.shuttleLayer && appliedNavigationMapType == mapType)
        return;
    didApplyNavigation = YES;
    appliedNavigationShowsLayers = showLayers;
    appliedNavigationShuttleLayer = self.shuttleLayer;
    appliedNavigationMapType = mapType;
    if (!showLayers) {
        self.navigationItem.pinnedTrailingGroup = nil;
        self.navigationItem.trailingItemGroups = @[];
        if (@available(iOS 26.0, *)) {
            self.navigationItem.leftBarButtonItem = self.centerButton;
            self.navigationItem.rightBarButtonItem = self.routesButton;
        } else
            self.navigationItem.rightBarButtonItems = @[ self.routesButton, self.centerButton ];
        return;
    }
    __weak typeof(self) weakSelf = self;
    NSMutableArray *providers = [NSMutableArray array];
    for (NSNumber *shuttle in @[ @NO, @YES ]) {
        UIAction *action =
            [UIAction actionWithTitle:shuttle.boolValue ? NSLocalizedString(@"Campus Shuttles", nil) : @"CATA"
                                image:nil
                           identifier:nil
                              handler:^(UIAction *action) {
                                  [weakSelf setShuttleLayerVisible:shuttle.boolValue];
                              }];
        action.state = self.shuttleLayer == shuttle.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;
        [providers addObject:action];
    }
    NSMutableArray *styles = [NSMutableArray array];
    NSArray *titles = @[ NSLocalizedString(@"Standard", nil), NSLocalizedString(@"Satellite", nil) ];
    NSArray *types = @[ @(MKMapTypeStandard), @(MKMapTypeSatellite) ];
    for (NSUInteger index = 0; index < types.count; index++) {
        NSNumber *type = types[index];
        UIAction *action =
            [UIAction actionWithTitle:titles[index]
                                image:nil
                           identifier:nil
                              handler:^(UIAction *action) {
                                  [NSUserDefaults.standardUserDefaults setInteger:type.integerValue
                                                                           forKey:@"psuTransitMapStyle"];
                                  [weakSelf applyTransitMapStyle];
                              }];
        action.state = self.map.mapType == type.integerValue ? UIMenuElementStateOn : UIMenuElementStateOff;
        [styles addObject:action];
    }
    UIMenu *menu =
        [UIMenu menuWithTitle:@""
                     children:@[
                         [UIMenu menuWithTitle:NSLocalizedString(@"Transit", nil)
                                         image:nil
                                    identifier:nil
                                       options:UIMenuOptionsDisplayInline | UIMenuOptionsSingleSelection
                                      children:providers],
                         [UIMenu menuWithTitle:NSLocalizedString(@"Map Style", nil)
                                         image:nil
                                    identifier:nil
                                       options:UIMenuOptionsDisplayInline | UIMenuOptionsSingleSelection
                                      children:styles]
                     ]];
    UIBarButtonItem *layers =
        [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Layers", nil)
                                         image:[UIImage systemImageNamed:@"square.3.layers.3d"]
                                        target:nil
                                        action:nil
                                          menu:menu];
    self.navigationItem.rightBarButtonItems = nil;
    self.navigationItem.pinnedTrailingGroup =
        [[UIBarButtonItemGroup alloc] initWithBarButtonItems:@[ self.routesButton ] representativeItem:nil];
    NSArray *items;
    if (@available(iOS 26.0, *)) {
        self.navigationItem.leftBarButtonItem = self.centerButton;
        items = @[ layers ];
    } else
        items = @[ self.centerButton, layers ];
    self.navigationItem.trailingItemGroups = @[ [[UIBarButtonItemGroup alloc] initWithBarButtonItems:items
                                                                                  representativeItem:nil] ];
}

#pragma mark MKMapViewDelegate

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    MKOverlayRenderer *shuttleRenderer = [self.shuttles rendererForOverlay:overlay];
    if (shuttleRenderer) return shuttleRenderer;
    for (NSString *routeKey in self.activeRouteParsers) {
        KMLParser *parser = self.activeRouteParsers[routeKey];
        MKOverlayRenderer *renderer = [parser rendererForOverlay:overlay];
        if (renderer) {
            return renderer;
        }
    }
    return nil;
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    MKAnnotationView *shuttleView = [self.shuttles viewForAnnotation:annotation];
    if (shuttleView) return shuttleView;
    if ([annotation isMemberOfClass:[BusAnnotation class]]) {
        MKAnnotationView *view = [mapView dequeueReusableAnnotationViewWithIdentifier:kBusAnnotation
                                                                        forAnnotation:annotation];
        view.alpha = vehiclesAreStale ? 0.55 : 1.0;
        return view;
    }

    if ([annotation isMemberOfClass:[StopAnnotation class]]) {
        return [mapView dequeueReusableAnnotationViewWithIdentifier:kStopAnnotation forAnnotation:annotation];
    }

    return nil;
}

- (void)mapView:(MKMapView *)mapView didAddAnnotationViews:(NSArray<MKAnnotationView *> *)views {
    for (MKAnnotationView *view in views) {
        if ([view isMemberOfClass:objc_getClass("_MKUserLocationView")]) {
            userLocationView = (_MKUserLocationView *)view;
            userLocationView.shouldDisplayHeading = true;
        }
    }
}

@end
