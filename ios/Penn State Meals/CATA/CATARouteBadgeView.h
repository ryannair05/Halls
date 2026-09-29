#import <UIKit/UIKit.h>

@class RouteModel;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CATARouteBadgeVariant) {
    CATARouteBadgeVariantCompact,
    CATARouteBadgeVariantStandard,
};

@interface CATARouteBadgeView : UIView

@property (nonatomic, readonly) CATARouteBadgeVariant variant;
@property (nonatomic, copy, readonly) NSString *abbreviation;

- (instancetype)initWithVariant:(CATARouteBadgeVariant)variant NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)configureWithRoute:(RouteModel *)route;
- (void)configureWithAbbreviation:(nullable NSString *)abbreviation
                         colorHex:(nullable NSString *)colorHex
                     textColorHex:(nullable NSString *)textColorHex;

@end

NS_ASSUME_NONNULL_END
