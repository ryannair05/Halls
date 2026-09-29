//
//  RouteModel.h
//  Penn State Meals
//
//  Created by Ryan Nair on 5/16/25.
//

#ifndef RouteModel_h
#define RouteModel_h

#import <Foundation/Foundation.h>

// Missing dictionary fields and default initialization leave text fields nil.
// Text fields preserve the submitted values, including mutable string inputs.
NS_ASSUME_NONNULL_BEGIN

@interface RouteModel : NSObject

@property (nonatomic, assign) NSInteger routeId;
@property (nonatomic, copy, nullable) NSString *longName;
@property (nonatomic, copy, nullable) NSString *abbreviation;
@property (nonatomic, copy, nullable) NSString *textColor;
@property (nonatomic, copy, nullable) NSString *color;
@property (nonatomic, copy, nullable) NSString *traceFilename;
@property (nonatomic, assign) NSInteger sortOrder;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END

#endif /* RouteModel_h */
