//
//  RoutesViewController.h
//  Penn State Meals
//
//  Created by Ryan Nair on 3/12/25.
//

#import <MapKit/MapKit.h>

#define kBusAnnotation @"BusAnnotation"
#define kStopAnnotation @"StopAnnotation"

NS_ASSUME_NONNULL_BEGIN

// Once published to MapKit, annotation mutation and observation are main-thread-only.
// Unpublished StopAnnotation objects may be prepared on the serial parsing queue.
@interface BusAnnotation : MKPointAnnotation
@property (nonatomic, strong, nullable) UIColor *busColor;
@property (nonatomic, strong, nullable) NSNumber *onBoard;
@property (nonatomic, strong, nullable) NSNumber *seatingCapacity;
@property (nonatomic, strong, nullable) NSNumber *routeId;
@property (nonatomic, copy, nullable) NSString *lastUpdated;
@property (nonatomic, assign) CLLocationDegrees heading;
@end

@interface BusAnnotationView : MKAnnotationView  {
    UILabel* titleLabel;
    UILabel* directionLabel;
    UILabel* capacityLabel;
    UIProgressView* capacityBar;
    CAShapeLayer* headingLayer;
}
- (void)animateToCoordinate:(CLLocationCoordinate2D)toCoordinate withHeading:(CLLocationDegrees)heading;
@end

@interface StopAnnotation : NSObject <MKAnnotation>
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, strong, nullable) NSNumber *stopId;
@end

@interface StopAnnotationView : MKAnnotationView
@end

NS_ASSUME_NONNULL_END
