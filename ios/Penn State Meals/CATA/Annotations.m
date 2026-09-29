//
//  RoutesViewController.m
//  Penn State Meals
//
//  Created by Ryan Nair on 3/12/25.
//

#import "Annotations.h"
#include <math.h>
#import <objc/runtime.h>

@implementation BusAnnotation
@end

@implementation StopAnnotation
@end

static NSString* emptyString(__unsafe_unretained UIView* const self, SEL _cmd) {
    return nil;
}

static void CATAInstallMapLabelHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        class_addMethod(objc_getClass("_MKUILabel"), @selector(text), (IMP)&emptyString, "@16@0:8");
    });
}

@interface BusAnnotationView ()
@property(nonatomic) BOOL hasDisplayedHeading;
@property(nonatomic) CLLocationDegrees displayedHeading;
@property(nonatomic, strong) UIColor *displayedBusColor;
@property(nonatomic) CGFloat displayedImageScale;
@property(nonatomic) BOOL busImageTraitsChanged;
@property(nonatomic) BOOL hasCapacitySnapshot;
@property(nonatomic) BOOL lastCapacityValid;
@property(nonatomic) double lastCapacity;
@property(nonatomic) double lastOnBoard;
@property(nonatomic, copy) NSString *displayedDirection;
- (void)updateBusImage:(BusAnnotation *)annotation;
- (UIImage *)bodyImageForColor:(UIColor *)color scale:(CGFloat)scale;
- (void)updateHeading:(CLLocationDegrees)heading;
- (void)updateCapacityInfo:(BusAnnotation *)busAnnotation;
- (void)setupDetailCallout:(BusAnnotation *)busAnnotation;
- (void)updateCalloutContent:(BusAnnotation *)busAnnotation;
- (void)clearCallout;
@end

@implementation BusAnnotationView

static UIImage *CATABusBodyImage(UIColor *resolvedColor, CGFloat scale) {
    static NSCache<NSArray *, UIImage *> *cache;
    static UIImage *busSymbol;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 24;
        cache.totalCostLimit = 2 * 1024 * 1024;
        busSymbol = [[UIImage systemImageNamed:@"bus"] imageWithTintColor:UIColor.whiteColor
                                                            renderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    // Only reached on first image, color change, scale change or color-trait change.
    NSArray *key = @[ resolvedColor, @(scale) ];
    UIImage *cachedImage = [cache objectForKey:key];
    if (cachedImage) return cachedImage;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)
                                                                               format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextSetFillColorWithColor(cg, [resolvedColor colorWithAlphaComponent:1.0].CGColor);
        CGContextFillEllipseInRect(cg, CGRectMake(5, 5, 30, 30));
        [busSymbol drawInRect:CGRectMake(12, 12, 16, 16)];
    }];
    CGImageRef cgImage = image.CGImage;
    NSUInteger cost = cgImage ? CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage) : 0;
    [cache setObject:image forKey:key cost:cost];
    return image;
}

- (instancetype)initWithAnnotation:(BusAnnotation *)annotation reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithAnnotation:annotation reuseIdentifier:reuseIdentifier];
    if (self) {
        CATAInstallMapLabelHook();
        self.canShowCallout = YES;

        // Make sure the annotation can be centered on screen during animation
        self.centerOffset = CGPointMake(0, -15);

        headingLayer = [CAShapeLayer layer];
        UIBezierPath *arrowPath = [UIBezierPath bezierPath];
        [arrowPath moveToPoint:CGPointMake(20, 0)];
        [arrowPath addLineToPoint:CGPointMake(16, 6)];
        [arrowPath addLineToPoint:CGPointMake(24, 6)];
        [arrowPath closePath];
        headingLayer.path = arrowPath.CGPath;
        headingLayer.fillColor = UIColor.whiteColor.CGColor;
        headingLayer.bounds = CGRectMake(0, 0, 40, 40);
        headingLayer.anchorPoint = CGPointMake(0.5, 0.5);
        [self.layer addSublayer:headingLayer];
        if ([annotation isKindOfClass:BusAnnotation.class]) {
            [self updateBusImage:annotation];
            [self updateHeading:annotation.heading];
        }
    }
    return self;
}

- (void)clearCallout {
    self.detailCalloutAccessoryView = nil;
    titleLabel = nil;
    directionLabel = nil;
    capacityLabel = nil;
    capacityBar = nil;
    _displayedDirection = nil;
    _hasCapacitySnapshot = NO;
}

- (void)setAnnotation:(BusAnnotation *)annotation {
    if (self.annotation != annotation) [self clearCallout];
    [super setAnnotation:annotation];
    if ([annotation isKindOfClass:BusAnnotation.class]) {
        [self updateBusImage:annotation];
        [self updateHeading:annotation.heading];
    }
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    // Custom labels are necessary because the preserved private text hook can
    // suppress MapKit's built-in title/subtitle. Still allocate only on selection.
    if (selected && [self.annotation isKindOfClass:BusAnnotation.class]) {
        [self setupDetailCallout:(BusAnnotation *)self.annotation];
    }
    [super setSelected:selected animated:animated];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self clearCallout];
    _hasDisplayedHeading = NO;
    self.alpha = 1.0;
    // Keep a usable image/color pair: reusing for the same color needs no lookup.
}

- (void)prepareForDisplay {
    [super prepareForDisplay];
    if ([self.annotation isKindOfClass:BusAnnotation.class]) {
        BusAnnotation *annotation = (BusAnnotation *)self.annotation;
        [self updateBusImage:annotation];
        [self updateHeading:annotation.heading];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    if (!CGPointEqualToPoint(headingLayer.position, position)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        headingLayer.position = position;
        [CATransaction commit];
    }
}

- (void)animateToCoordinate:(CLLocationCoordinate2D)toCoordinate withHeading:(CLLocationDegrees)heading {
    BusAnnotation *busAnnotation = (BusAnnotation *)self.annotation;
    if (![busAnnotation isKindOfClass:BusAnnotation.class]) return;

    [self updateBusImage:busAnnotation];
    if (self.selected) [self updateCalloutContent:busAnnotation];

    CLLocationCoordinate2D fromCoordinate = [busAnnotation coordinate];
    BOOL coordinateChanged = toCoordinate.latitude != fromCoordinate.latitude ||
                             toCoordinate.longitude != fromCoordinate.longitude;
    if (!isfinite(heading)) heading = 0;
    BOOL headingChanged = heading != busAnnotation.heading;

    if (headingChanged) {
        busAnnotation.heading = heading;
    }
    [self updateHeading:heading]; // One target transform, never old then new.

    if (!coordinateChanged) return;

    [UIView
        animateWithDuration:1.0
                      delay:0
                    options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState |
                            UIViewAnimationOptionAllowUserInteraction
                 animations:^{
                     busAnnotation.coordinate = toCoordinate;
                 }
                 completion:nil];
}

- (UIImage *)bodyImageForColor:(UIColor *)color scale:(CGFloat)scale {
    return CATABusBodyImage(color, scale);
}

- (void)updateBusImage:(BusAnnotation *)annotation {
    __unsafe_unretained UIColor *color = annotation.busColor;
    self.hidden = color == nil;
    if (!color) return;
    CGFloat scale = self.traitCollection.displayScale;
    if (!_busImageTraitsChanged && self.image && _displayedImageScale == scale &&
        (_displayedBusColor == color || [_displayedBusColor isEqual:color]))
        return;
    UIColor *resolved = [color resolvedColorWithTraitCollection:self.traitCollection];
    UIImage *image = [self bodyImageForColor:resolved scale:scale];
    _displayedBusColor = color;
    _displayedImageScale = scale;
    _busImageTraitsChanged = NO;
    if (self.image != image) {
        self.image = image;
        [self setNeedsLayout];
    }
}

- (void)updateHeading:(CLLocationDegrees)heading {
    if (!headingLayer) return; // A superclass initializer may call setAnnotation:.
    if (!isfinite(heading)) heading = 0;
    if (_hasDisplayedHeading && _displayedHeading == heading) return;
    _hasDisplayedHeading = YES;
    _displayedHeading = heading;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    headingLayer.transform = CATransform3DMakeRotation(heading * M_PI / 180.0, 0, 0, 1);
    [CATransaction commit];
}

- (void)updateCapacityInfo:(BusAnnotation *)busAnnotation {
    if (!capacityLabel || !capacityBar) return;
    // The annotation owns both objects throughout this synchronous calculation.
    __unsafe_unretained NSNumber *seatingCapacity = busAnnotation.seatingCapacity;
    __unsafe_unretained NSNumber *onBoard = busAnnotation.onBoard;
    double capacity = [seatingCapacity isKindOfClass:NSNumber.class] ? seatingCapacity.doubleValue : NAN;
    double boardCount = [onBoard isKindOfClass:NSNumber.class] ? onBoard.doubleValue : NAN;
    double percentage = capacity > 0 ? (boardCount / capacity) * 100.0 : NAN;
    BOOL valid = [seatingCapacity isKindOfClass:NSNumber.class] && [onBoard isKindOfClass:NSNumber.class] &&
                 isfinite(capacity) && capacity > 0 && isfinite(boardCount) && boardCount >= 0 &&
                 isfinite(percentage);
    if (_hasCapacitySnapshot && _lastCapacityValid == valid &&
        (!valid || (_lastCapacity == capacity && _lastOnBoard == boardCount)))
        return;
    _hasCapacitySnapshot = YES;
    _lastCapacityValid = valid;
    _lastCapacity = capacity;
    _lastOnBoard = boardCount;
    NSString *text = valid ? [NSString stringWithFormat:@"Passengers: %.0f / %.0f (%.0f%%)", boardCount,
                                                        capacity, percentage]
                           : @"Passenger count unavailable";
    if (![capacityLabel.text isEqualToString:text]) capacityLabel.text = text;
    float progress = valid ? (float)(MIN(100.0, MAX(0.0, percentage)) / 100.0) : 0;
    UIColor *color =
        !valid ? UIColor.systemGrayColor
               : (progress > 0.8f ? UIColor.systemRedColor
                                  : (progress > 0.5f ? UIColor.systemYellowColor : UIColor.systemGreenColor));
    if (![capacityBar.progressTintColor isEqual:color]) capacityBar.progressTintColor = color;
    if (capacityBar.progress != progress) capacityBar.progress = progress;
}

- (void)setupDetailCallout:(BusAnnotation *)busAnnotation {
    if (!self.detailCalloutAccessoryView) {
        UIView *calloutView = [[UIView alloc] init];

        titleLabel = [[UILabel alloc] init];
        titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        titleLabel.adjustsFontForContentSizeCategory = YES;
        titleLabel.numberOfLines = 0;
        [calloutView addSubview:titleLabel];

        directionLabel = [[UILabel alloc] init];
        directionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        directionLabel.adjustsFontForContentSizeCategory = YES;
        directionLabel.numberOfLines = 0;
        [calloutView addSubview:directionLabel];

        capacityLabel = [[UILabel alloc] init];
        capacityLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        capacityLabel.adjustsFontForContentSizeCategory = YES;
        capacityLabel.numberOfLines = 0;
        [calloutView addSubview:capacityLabel];

        capacityBar = [[UIProgressView alloc] init];
        [calloutView addSubview:capacityBar];

        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        directionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        capacityLabel.translatesAutoresizingMaskIntoConstraints = NO;
        capacityBar.translatesAutoresizingMaskIntoConstraints = NO;

        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:calloutView.topAnchor],
            [titleLabel.leadingAnchor constraintEqualToAnchor:calloutView.leadingAnchor constant:10],
            [titleLabel.trailingAnchor constraintEqualToAnchor:calloutView.trailingAnchor constant:-10],

            [directionLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
            [directionLabel.leadingAnchor constraintEqualToAnchor:calloutView.leadingAnchor constant:10],
            [directionLabel.trailingAnchor constraintEqualToAnchor:calloutView.trailingAnchor constant:-10],

            [capacityLabel.topAnchor constraintEqualToAnchor:directionLabel.bottomAnchor constant:8],
            [capacityLabel.leadingAnchor constraintEqualToAnchor:calloutView.leadingAnchor constant:10],
            [capacityLabel.trailingAnchor constraintEqualToAnchor:calloutView.trailingAnchor constant:-10],

            [capacityBar.topAnchor constraintEqualToAnchor:capacityLabel.bottomAnchor constant:8],
            [capacityBar.leadingAnchor constraintEqualToAnchor:calloutView.leadingAnchor constant:10],
            [capacityBar.trailingAnchor constraintEqualToAnchor:calloutView.trailingAnchor constant:-10],
            [capacityBar.bottomAnchor constraintEqualToAnchor:calloutView.bottomAnchor constant:-10]
        ]];

        self.detailCalloutAccessoryView = calloutView;
    }

    [self updateCalloutContent:busAnnotation];
}

- (void)updateCalloutContent:(BusAnnotation *)busAnnotation {
    if (!self.detailCalloutAccessoryView) return;
    if (titleLabel.text != busAnnotation.title && ![titleLabel.text isEqualToString:busAnnotation.title]) {
        titleLabel.text = busAnnotation.title;
    }
    __unsafe_unretained NSString *direction = busAnnotation.subtitle ?: @"N/A";
    if (_displayedDirection != direction && ![_displayedDirection isEqualToString:direction]) {
        _displayedDirection = [direction copy];
        directionLabel.text = [NSString stringWithFormat:@"Direction: %@", direction];
    }
    [self updateCapacityInfo:busAnnotation];
}

@end

@implementation StopAnnotationView

- (instancetype)initWithAnnotation:(id<MKAnnotation>)annotation reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithAnnotation:annotation reuseIdentifier:reuseIdentifier];
    if (self) {
        static UIImage *stopImage;
        if (!stopImage) {
            UIGraphicsImageRenderer *renderer =
                [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(10, 10)];
            stopImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [UIColor.systemGrayColor setFill];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 10, 10)] fill];
            }];
        }
        self.image = stopImage;
        self.layer.cornerRadius = 10;
    }
    return self;
}

@end
