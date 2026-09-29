#import "CATAGamedayRoutes.h"
#import <CoreLocation/CoreLocation.h>

@interface CATAGamedayRoutes ()
@property (nonatomic, copy) NSArray<RouteModel *> *catalog;
@property (nonatomic, copy) NSDictionary<NSNumber *, RouteModel *> *detours;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, RouteModel *> *overrides;
@property (nonatomic, strong) NSCalendar *calendar;
@property (nonatomic, strong) NSDate *dayStart;
@property (nonatomic, strong) NSDate *nextDay;
@property (nonatomic, strong) NSDate *nextProbe;
@property (nonatomic) BOOL saturday;
@end
@implementation CATAGamedayRoutes
- (instancetype)init {
    if ((self = [super init])) {
        _detours = @{}; _overrides = [NSMutableDictionary dictionary];
        _calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        _calendar.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
    }
    return self;
}
- (void)updateRouteCatalog:(NSArray<RouteModel *> *)routes {
    if (self.catalog == routes) return;
    self.catalog = routes;
    NSMutableDictionary<NSString *, RouteModel *> *byAbbreviation = [NSMutableDictionary dictionary];
    for (RouteModel *route in routes) {
        if (route.abbreviation.length && route.traceFilename.length) byAbbreviation[route.abbreviation.uppercaseString] = route;
    }
    NSMutableDictionary *detours = [NSMutableDictionary dictionary];
    for (NSString *base in @[@"BL", @"WL", @"H"]) {
        RouteModel *regular = byAbbreviation[base];
        RouteModel *detour = byAbbreviation[[base stringByAppendingString:@" GAMEDAY"]];
        if (regular && detour) detours[@(regular.routeId)] = detour;
    }
    self.detours = detours;
    for (NSNumber *base in self.overrides.allKeys) {
        if (detours[base]) self.overrides[base] = detours[base];
        else [self.overrides removeObjectForKey:base];
    }
}
- (BOOL)refreshDay:(NSDate *)date {
    if (self.nextDay && [date compare:self.dayStart] != NSOrderedAscending && [date compare:self.nextDay] == NSOrderedAscending) return NO;
    BOOL changed = self.overrides.count > 0;
    [self.overrides removeAllObjects]; self.nextProbe = nil;
    self.dayStart = [self.calendar startOfDayForDate:date];
    self.nextDay = [self.calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:self.dayStart options:0];
    self.saturday = [self.calendar component:NSCalendarUnitWeekday fromDate:date] == 7;
    return changed;
}
- (NSDictionary<NSString *,NSNumber *> *)effectiveSelection:(NSDictionary<NSString *,NSNumber *> *)selection {
    if (!self.overrides.count) return selection;
    NSMutableDictionary *effective = [NSMutableDictionary dictionaryWithCapacity:selection.count];
    [selection enumerateKeysAndObjectsUsingBlock:^(NSString *filename, NSNumber *identifier, BOOL *stop) {
        RouteModel *detour = self.overrides[identifier];
        if (detour) effective[detour.traceFilename] = @(detour.routeId);
        else effective[filename] = identifier;
    }];
    return effective;
}
- (void)retainOverridesForSelection:(NSDictionary<NSString *,NSNumber *> *)selection {
    NSSet *selected = [NSSet setWithArray:selection.allValues];
    for (NSNumber *base in self.overrides.allKeys) if (![selected containsObject:base]) [self.overrides removeObjectForKey:base];
}
- (BOOL)shouldCheckAtDate:(NSDate *)date {
    return self.saturday && self.detours.count > self.overrides.count && (!self.nextProbe || [date compare:self.nextProbe] != NSOrderedAscending);
}
- (NSDictionary<NSNumber *,RouteModel *> *)candidatesForSelection:(NSDictionary<NSString *,NSNumber *> *)selection visibleRouteIDs:(NSSet<NSNumber *> *)visibleRouteIDs date:(NSDate *)date {
    if (![self shouldCheckAtDate:date]) return nil;
    NSMutableDictionary *candidates = [NSMutableDictionary dictionary];
    for (NSNumber *identifier in selection.allValues) {
        RouteModel *detour = self.detours[identifier];
        if (detour && !self.overrides[identifier] && ![visibleRouteIDs containsObject:identifier] && ![selection.allValues containsObject:@(detour.routeId)]) candidates[identifier] = detour;
    }
    if (!candidates.count) return nil;
    self.nextProbe = [date dateByAddingTimeInterval:5 * 60];
    return candidates;
}
- (BOOL)acceptVehicles:(NSArray *)vehicles candidates:(NSDictionary<NSNumber *,RouteModel *> *)candidates {
    if (!self.saturday) return NO;
    NSMutableSet *liveRoutes = [NSMutableSet set];
    for (id raw in vehicles) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSNumber *routeID = [raw[@"RouteId"] isKindOfClass:NSNumber.class] ? raw[@"RouteId"] : nil;
        NSNumber *vehicleID = [raw[@"VehicleId"] isKindOfClass:NSNumber.class] ? raw[@"VehicleId"] : nil;
        NSNumber *latitude = [raw[@"Latitude"] isKindOfClass:NSNumber.class] ? raw[@"Latitude"] : nil;
        NSNumber *longitude = [raw[@"Longitude"] isKindOfClass:NSNumber.class] ? raw[@"Longitude"] : nil;
        if (routeID && vehicleID && latitude && longitude && CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue))) [liveRoutes addObject:routeID];
    }
    BOOL changed = NO;
    for (NSNumber *base in candidates) {
        RouteModel *detour = candidates[base];
        if ([liveRoutes containsObject:@(detour.routeId)]) { self.overrides[base] = detour; changed = YES; }
    }
    return changed;
}
@end
