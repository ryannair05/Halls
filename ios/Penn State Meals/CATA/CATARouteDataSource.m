#import "CATARouteDataSource.h"
#include <float.h>

NSTimeInterval const CATARouteDisplayCacheMaximumAge = 24 * 60 * 60;
NSTimeInterval const CATARouteOperationalCacheMaximumAge = 60 * 60;

static NSString * const CATARouteDataSourceErrorDomain = @"CATARouteDataSourceErrorDomain";
static NSInteger const CATARouteCacheVersion = 1;

typedef NS_ENUM(NSInteger, CATARouteDataSourceErrorCode) {
    CATARouteDataSourceErrorInvalidResponse = 1,
};

@interface CATARouteDataSource ()
- (instancetype)initPrivate;
@end

@implementation CATARouteDataSource {
    dispatch_queue_t _stateQueue;
    NSArray<RouteModel *> *_routes;
    NSArray<NSDictionary *> *_reducedRoutes;
    NSDate *_fetchedAt;
    BOOL _didLoadDiskCache;
    BOOL _isRefreshing;
    NSMutableArray<CATARouteLoadCompletion> *_refreshCompletions;
}

+ (CATARouteDataSource *)shared {
    static CATARouteDataSource *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CATARouteDataSource alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.ryannair05.pennstatemeals.cata-routes", DISPATCH_QUEUE_SERIAL);
        _routes = @[];
        _reducedRoutes = @[];
        _refreshCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)loadVisibleRoutesWithMaximumAge:(NSTimeInterval)maximumAge
                        notifyOnRefresh:(BOOL)notifyOnRefresh
                             completion:(CATARouteLoadCompletion)completion {
    if (!completion) return;

    dispatch_async(_stateQueue, ^{
        [self loadDiskCacheIfNeeded];

        NSArray<RouteModel *> *cachedRoutes = self->_routes;
        BOOL hasCache = cachedRoutes.count > 0 && self->_fetchedAt != nil;
        NSTimeInterval age = hasCache
            ? MAX(0, -[self->_fetchedAt timeIntervalSinceNow])
            : DBL_MAX;

        if (hasCache) {
            [self deliverRoutes:cachedRoutes error:nil completion:completion];
        }
        if (hasCache && age <= maximumAge) return;

        if (!hasCache || notifyOnRefresh) {
            [self->_refreshCompletions addObject:[completion copy]];
        }
        [self startRefreshIfNeeded];
    });
}

- (void)startRefreshIfNeeded {
    if (_isRefreshing) return;
    _isRefreshing = YES;

    NSURL *url = [NSURL URLWithString:
        @"https://realtime.catabus.com/InfoPoint/rest/Routes/GetVisibleRoutes"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        NSError *resultError = error;
        NSArray<NSDictionary *> *reducedRoutes = @[];
        NSArray<RouteModel *> *routeModels = @[];

        if (!resultError && (!data || httpResponse.statusCode != 200)) {
            resultError = [NSError errorWithDomain:CATARouteDataSourceErrorDomain
                                              code:CATARouteDataSourceErrorInvalidResponse
                                          userInfo:@{NSLocalizedDescriptionKey: @"CATA returned an invalid route response."}];
        }
        if (!resultError) {
            NSError *jsonError = nil;
            id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            reducedRoutes = [self reducedRouteDictionariesFromPayload:payload];
            routeModels = [self routeModelsFromReducedDictionaries:reducedRoutes];
            if (jsonError || routeModels.count == 0) {
                resultError = jsonError ?: [NSError errorWithDomain:CATARouteDataSourceErrorDomain
                                                                code:CATARouteDataSourceErrorInvalidResponse
                                                            userInfo:@{NSLocalizedDescriptionKey: @"CATA returned no valid routes."}];
            }
        }

        dispatch_async(self->_stateQueue, ^{
            self->_isRefreshing = NO;
            NSArray<CATARouteLoadCompletion> *completions = [self->_refreshCompletions copy];
            [self->_refreshCompletions removeAllObjects];

            if (!resultError) {
                self->_routes = routeModels;
                self->_reducedRoutes = reducedRoutes;
                self->_fetchedAt = [NSDate date];
                [self writeDiskCache];
            }

            NSArray<RouteModel *> *availableRoutes = self->_routes;
            for (CATARouteLoadCompletion callback in completions) {
                [self deliverRoutes:availableRoutes error:resultError completion:callback];
            }
        });
    }];
    [task resume];
}

- (void)deliverRoutes:(NSArray<RouteModel *> *)routes
                 error:(NSError *)error
            completion:(CATARouteLoadCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(routes, error);
    });
}

- (NSArray<NSDictionary *> *)reducedRouteDictionariesFromPayload:(id)payload {
    if (![payload isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (id value in (NSArray *)payload) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *route = value;
        NSNumber *routeID = [route[@"RouteId"] isKindOfClass:NSNumber.class]
            ? route[@"RouteId"] : nil;
        NSString *longName = [route[@"LongName"] isKindOfClass:NSString.class]
            ? route[@"LongName"] : nil;
        NSString *abbreviation = [route[@"RouteAbbreviation"] isKindOfClass:NSString.class]
            ? route[@"RouteAbbreviation"] : nil;
        NSString *traceFilename = [route[@"RouteTraceFilename"] isKindOfClass:NSString.class]
            ? route[@"RouteTraceFilename"] : nil;
        if (routeID.integerValue <= 0 || longName.length == 0 ||
            abbreviation.length == 0 || traceFilename.length == 0) continue;

        NSMutableDictionary *reduced = [@{
            @"RouteId": routeID,
            @"LongName": longName,
            @"RouteAbbreviation": abbreviation,
            @"RouteTraceFilename": traceFilename,
            @"SortOrder": [route[@"SortOrder"] isKindOfClass:NSNumber.class]
                ? route[@"SortOrder"] : @0,
        } mutableCopy];
        if ([route[@"TextColor"] isKindOfClass:NSString.class]) {
            reduced[@"TextColor"] = route[@"TextColor"];
        }
        if ([route[@"Color"] isKindOfClass:NSString.class]) {
            reduced[@"Color"] = route[@"Color"];
        }
        [result addObject:reduced];
    }
    return [result copy];
}

- (NSArray<RouteModel *> *)routeModelsFromReducedDictionaries:(NSArray<NSDictionary *> *)dictionaries {
    NSMutableArray<RouteModel *> *models = [NSMutableArray arrayWithCapacity:dictionaries.count];
    for (NSDictionary *dictionary in dictionaries) {
        [models addObject:[[RouteModel alloc] initWithDictionary:dictionary]];
    }
    [models sortUsingComparator:^NSComparisonResult(RouteModel *first, RouteModel *second) {
        if (first.sortOrder < second.sortOrder) return NSOrderedAscending;
        if (first.sortOrder > second.sortOrder) return NSOrderedDescending;
        if (first.routeId < second.routeId) return NSOrderedAscending;
        if (first.routeId > second.routeId) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return [models copy];
}

- (void)loadDiskCacheIfNeeded {
    if (_didLoadDiskCache) return;
    _didLoadDiskCache = YES;

    NSURL *cacheURL = [self cacheFileURL];
    NSData *data = [NSData dataWithContentsOfURL:cacheURL];
    if (!data) return;

    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![value isKindOfClass:NSDictionary.class]) {
        [NSFileManager.defaultManager removeItemAtURL:cacheURL error:nil];
        return;
    }

    NSDictionary *container = value;
    NSNumber *version = [container[@"version"] isKindOfClass:NSNumber.class]
        ? container[@"version"] : nil;
    NSNumber *timestamp = [container[@"fetchedAt"] isKindOfClass:NSNumber.class]
        ? container[@"fetchedAt"] : nil;
    NSArray<NSDictionary *> *reducedRoutes =
        [self reducedRouteDictionariesFromPayload:container[@"routes"]];
    NSArray<RouteModel *> *models = [self routeModelsFromReducedDictionaries:reducedRoutes];
    if (version.integerValue != CATARouteCacheVersion || !timestamp || models.count == 0) {
        [NSFileManager.defaultManager removeItemAtURL:cacheURL error:nil];
        return;
    }

    _reducedRoutes = reducedRoutes;
    _routes = models;
    _fetchedAt = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
}

- (void)writeDiskCache {
    NSDictionary *container = @{
        @"version": @(CATARouteCacheVersion),
        @"fetchedAt": @(_fetchedAt.timeIntervalSince1970),
        @"routes": _reducedRoutes,
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:container options:0 error:&error];
    if (!data || error) return;

    NSURL *cacheURL = [self cacheFileURL];
    NSURL *cacheDirectoryURL = cacheURL.URLByDeletingLastPathComponent;
    if (!cacheDirectoryURL) return;
    [NSFileManager.defaultManager createDirectoryAtURL:cacheDirectoryURL
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    [data writeToURL:cacheURL options:NSDataWritingAtomic error:nil];
}

- (NSURL *)cacheFileURL {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    return [[caches URLByAppendingPathComponent:@"CATA" isDirectory:YES]
        URLByAppendingPathComponent:@"visible-routes-v1.json" isDirectory:NO];
}

@end
