#import "PSUShuttleData.h"
#import <math.h>

NSNumber *PSUShuttleNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? value : nil;
}
NSString *PSUShuttleString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
NSNumber *PSUShuttleIdentifier(NSDictionary *value, NSString *upper, NSString *mixed) {
    NSNumber *number = PSUShuttleNumber(value[upper]) ?: PSUShuttleNumber(value[mixed]);
    return number && number.doubleValue >= 0 && number.doubleValue == number.longLongValue ? number : nil;
}
static NSError *PSUShuttleInvalidData(void) {
    return [NSError errorWithDomain:@"PSUShuttle" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Shuttle data is unavailable. Please try again."}];
}
id PSUShuttleDecodeJSON(NSData *data, NSError **error) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![text hasPrefix:@"["] && ![text hasPrefix:@"{"]) {
        // Accept a single callback wrapper, never execute JavaScript or strip arbitrary code.
        NSRegularExpression *wrapper = [NSRegularExpression regularExpressionWithPattern:
            @"^[A-Za-z_$][A-Za-z0-9_$.]*\\s*\\(([\\s\\S]*)\\)\\s*;?$" options:0 error:nil];
        NSTextCheckingResult *match = text ? [wrapper firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
        if (!match) { if (error) *error = PSUShuttleInvalidData(); return nil; }
        text = [text substringWithRange:[match rangeAtIndex:1]];
    }
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
}

static BOOL PSUDecodeComponent(NSString *text, NSUInteger *index, int64_t *delta) {
    uint64_t result = 0;
    for (NSUInteger shift = 0; shift <= 30; shift += 5) {
        if (*index >= text.length) return NO;
        unichar character = [text characterAtIndex:(*index)++];
        if (character < 63 || character > 126) return NO;
        unsigned byte = character - 63;
        result |= ((uint64_t)(byte & 31)) << shift;
        if (byte < 32) { *delta = (result & 1) ? -(int64_t)((result >> 1) + 1) : (int64_t)(result >> 1); return YES; }
    }
    return NO;
}
MKPolyline *PSUShuttleDecodePolyline(NSString *encoded) {
    if (!encoded.length || encoded.length > 1000000) return nil;
    NSMutableData *points = [NSMutableData data];
    NSUInteger index = 0;
    int64_t latitude = 0, longitude = 0, delta = 0;
    while (index < encoded.length) {
        if (!PSUDecodeComponent(encoded, &index, &delta)) return nil;
        latitude += delta;
        if (!PSUDecodeComponent(encoded, &index, &delta)) return nil;
        longitude += delta;
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude / 1e5, longitude / 1e5);
        if (!CLLocationCoordinate2DIsValid(coordinate)) return nil;
        [points appendBytes:&coordinate length:sizeof(coordinate)];
    }
    NSUInteger count = points.length / sizeof(CLLocationCoordinate2D);
    return count >= 2 ? [MKPolyline polylineWithCoordinates:points.bytes count:count] : nil;
}
NSDate *PSUShuttleDate(id value) {
    NSString *text = PSUShuttleString(value);
    if ([text hasPrefix:@"/Date("]) {
        NSScanner *scanner = [NSScanner scannerWithString:[text substringFromIndex:6]];
        long long milliseconds;
        if ([scanner scanLongLong:&milliseconds] && [text hasSuffix:@")/"]) {
            return [NSDate dateWithTimeIntervalSince1970:milliseconds / 1000.0];
        }
    }
    if (!text.length) return nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [formatter dateFromString:text];
    if (!date) {
        formatter.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
        date = [formatter dateFromString:text];
    }
    return date;
}
NSTimeInterval PSUShuttleVehicleAge(NSDictionary *vehicle, NSDate *received, NSDate *now) {
    NSNumber *seconds = PSUShuttleNumber(vehicle[@"Seconds"]);
    return (seconds ? MAX(0, seconds.doubleValue) : 0) + MAX(0, [now timeIntervalSinceDate:received]);
}
NSArray<NSDictionary *> *PSUShuttleArrivalRows(NSArray *values, NSDate *now, NSUInteger limit) {
    NSMutableArray *rows = [NSMutableArray array];
    for (id raw in values) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *value = raw;
        if ([PSUShuttleNumber(value[@"IsDeparted"]) boolValue]) continue;
        NSDate *estimate = PSUShuttleDate(value[@"EstimateTime"]);
        NSDate *scheduled = PSUShuttleDate(value[@"ScheduledArrivalTime"]) ?: PSUShuttleDate(value[@"ScheduledTime"]);
        NSNumber *seconds = PSUShuttleNumber(value[@"Seconds"]);
        BOOL live = estimate != nil || (!scheduled && seconds != nil);
        NSDate *arrival = estimate ?: scheduled;
        if (!arrival && seconds) arrival = [now dateByAddingTimeInterval:seconds.doubleValue];
        // Old server estimates must not become a fresh countdown just because HTTP succeeded.
        if (!arrival || [arrival timeIntervalSinceDate:now] < -60) continue;
        NSMutableDictionary *row = [value mutableCopy];
        row[@"arrival"] = arrival;
        row[@"live"] = @(live);
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"arrival"] compare:b[@"arrival"]]; }];
    return [rows subarrayWithRange:NSMakeRange(0, MIN(limit, rows.count))];
}

@implementation PSUShuttleStop
- (instancetype)initWithDictionary:(NSDictionary *)value routeID:(NSNumber *)routeID {
    NSNumber *identifier = PSUShuttleIdentifier(value, @"RouteStopID", @"RouteStopId");
    NSNumber *latitude = PSUShuttleNumber(value[@"Latitude"]), *longitude = PSUShuttleNumber(value[@"Longitude"]);
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!identifier || !latitude || !longitude || !CLLocationCoordinate2DIsValid(coordinate)) return nil;
    if ((self = [super init])) {
        _identifier = identifier; _routeID = routeID; _coordinate = coordinate;
        _name = [PSUShuttleString(value[@"Description"]) copy];
        if (!_name.length) _name = [PSUShuttleString(value[@"Name"]) copy];
        if (!_name.length) _name = NSLocalizedString(@"Shuttle stop", nil);
    }
    return self;
}
@end

@implementation PSUShuttleRoute
- (instancetype)initWithDictionary:(NSDictionary *)value {
    NSNumber *identifier = PSUShuttleIdentifier(value, @"RouteID", @"RouteId");
    NSString *name = PSUShuttleString(value[@"Description"]);
    if (!identifier || ![PSUShuttleNumber(value[@"IsVisibleOnMap"]) boolValue] ||
        [name rangeOfString:@"Campus Shuttle" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
    if ((self = [super init])) {
        _identifier = identifier; _name = [name copy];
        NSString *hex = [PSUShuttleString(value[@"MapLineColor"]) stringByReplacingOccurrencesOfString:@"#" withString:@""];
        unsigned color = 0;
        BOOL valid = hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&color];
        _color = valid ? [UIColor colorWithRed:((color >> 16) & 255) / 255.0 green:((color >> 8) & 255) / 255.0 blue:(color & 255) / 255.0 alpha:1] : UIColor.systemBlueColor;
        if (![PSUShuttleNumber(value[@"HideRouteLine"]) boolValue]) {
            NSString *encoded = PSUShuttleString(value[@"EncodedPolyline"]);
            _polyline = PSUShuttleDecodePolyline(encoded);
        }
        NSMutableArray *stops = [NSMutableArray array];
        NSArray *rawStops = [value[@"Stops"] isKindOfClass:NSArray.class] ? value[@"Stops"] : @[];
        NSMutableSet *seen = [NSMutableSet set];
        for (id raw in rawStops) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            PSUShuttleStop *stop = [[PSUShuttleStop alloc] initWithDictionary:raw routeID:identifier];
            if (stop && ![seen containsObject:stop.identifier]) { [stops addObject:stop]; [seen addObject:stop.identifier]; }
        }
        _stops = [stops copy];
    }
    return self;
}
@end

@interface PSUShuttleAPIClient ()
@property (nonatomic, strong) NSURLSession *session;
@end
@implementation PSUShuttleAPIClient
- (instancetype)init { return [self initWithSession:NSURLSession.sharedSession]; }
- (instancetype)initWithSession:(NSURLSession *)session {
    if ((self = [super init])) _session = session;
    return self;
}
- (NSURLSessionDataTask *)fetch:(NSString *)method query:(NSDictionary<NSString *,NSString *> *)query completion:(void (^)(NSArray *, NSError *))completion {
    NSURLComponents *url = [NSURLComponents componentsWithString:[@"https://pennstate.transloc.com/Services/JSONPRelay.svc/" stringByAppendingString:method]];
    NSMutableArray *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) { [items addObject:[NSURLQueryItem queryItemWithName:key value:value]]; }];
    url.queryItems = items.count ? items : nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"application/json,text/javascript" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        id values;
        if (!error && http.statusCode == 200 && data.length) values = PSUShuttleDecodeJSON(data, &error);
        if (!error && ![values isKindOfClass:NSArray.class]) error = PSUShuttleInvalidData();
        if (error) values = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(values, error); });
    }];
    [task resume];
    return task;
}
@end
