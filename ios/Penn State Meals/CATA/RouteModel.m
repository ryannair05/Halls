//
//  RouteModel.m
//  Penn State Meals
//
//  Created by Ryan Nair on 5/16/25.
//

#import "RouteModel.h"

@implementation RouteModel

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        _routeId = [dictionary[@"RouteId"] integerValue];
        _longName = [dictionary[@"LongName"] copy];
        _abbreviation = [dictionary[@"RouteAbbreviation"] copy];
        _textColor = [dictionary[@"TextColor"] copy];
        _color = [dictionary[@"Color"] copy];
        _traceFilename = [dictionary[@"RouteTraceFilename"] copy];
        _sortOrder = [dictionary[@"SortOrder"] integerValue];
    }
    return self;
}

@end
