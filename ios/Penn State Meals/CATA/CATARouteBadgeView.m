#import "CATARouteBadgeView.h"
#import "RouteModel.h"
#include <math.h>

static CGFloat CATASRGBLinearComponent(CGFloat value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat CATAColorLuminance(UIColor *color) {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return NAN;
    return 0.2126 * CATASRGBLinearComponent(red)
        + 0.7152 * CATASRGBLinearComponent(green)
        + 0.0722 * CATASRGBLinearComponent(blue);
}

static UIColor *CATAColorFromHexString(NSString *hexString) {
    if (![hexString isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [hexString stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([normalized hasPrefix:@"#"]) normalized = [normalized substringFromIndex:1];
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"] invertedSet];
    if (normalized.length != 6 ||
        [normalized rangeOfCharacterFromSet:nonHex].location != NSNotFound) return nil;
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:normalized];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
}

static UIColor *CATAContrastingTextColor(UIColor *backgroundColor, UIColor *preferredColor) {
    CGFloat backgroundLuminance = CATAColorLuminance(backgroundColor);
    if (!isfinite(backgroundLuminance)) return UIColor.labelColor;
    if (preferredColor) {
        CGFloat preferredLuminance = CATAColorLuminance(preferredColor);
        if (isfinite(preferredLuminance)) {
            CGFloat lighter = MAX(backgroundLuminance, preferredLuminance);
            CGFloat darker = MIN(backgroundLuminance, preferredLuminance);
            if ((lighter + 0.05) / (darker + 0.05) >= 4.5) return preferredColor;
        }
    }
    CGFloat whiteContrast = 1.05 / (backgroundLuminance + 0.05);
    CGFloat blackContrast = (backgroundLuminance + 0.05) / 0.05;
    return blackContrast >= whiteContrast ? UIColor.blackColor : UIColor.whiteColor;
}

@interface CATARouteBadgeView ()
// Private view and configuration storage.
@property (nonatomic, strong, nonnull) UILabel *label;
@property (nonatomic, copy, readwrite, nonnull) NSString *abbreviation;
@property (nonatomic, copy, nullable) NSString *colorHex;
@property (nonatomic, copy, nullable) NSString *textColorHex;
@end

@implementation CATARouteBadgeView

- (instancetype)initWithVariant:(CATARouteBadgeVariant)variant {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _variant = variant;
        _abbreviation = @"—";
        _label = [[UILabel alloc] init];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontForContentSizeCategory = YES;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.72;
        _label.lineBreakMode = NSLineBreakByClipping;
        [self updateFont];
        [self addSubview:_label];

        CGFloat horizontalPadding = variant == CATARouteBadgeVariantCompact ? 7 : 9;
        CGFloat verticalPadding = variant == CATARouteBadgeVariantCompact ? 3 : 5;
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:horizontalPadding],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-horizontalPadding],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:verticalPadding],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-verticalPadding],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:
                variant == CATARouteBadgeVariantCompact ? 24 : 30],
        ]];
        [self configureWithAbbreviation:@"—" colorHex:nil textColorHex:nil];
        [self registerForTraitChanges:@[
            UITraitPreferredContentSizeCategory.class,
            UITraitAccessibilityContrast.class,
            UITraitUserInterfaceStyle.class,
        ] withAction:@selector(cata_badgeTraitsDidChange)];
    }
    return self;
}

- (void)configureWithRoute:(RouteModel *)route {
    [self configureWithAbbreviation:route.abbreviation
                           colorHex:route.color
                       textColorHex:route.textColor];
}

- (void)configureWithAbbreviation:(NSString *)abbreviation
                         colorHex:(NSString *)colorHex
                     textColorHex:(NSString *)textColorHex {
    NSString *visibleAbbreviation = abbreviation.length > 0 ? abbreviation : @"—";
    self.colorHex = colorHex;
    self.textColorHex = textColorHex;
    UIColor *background = CATAColorFromHexString(colorHex);
    UIColor *foreground = CATAColorFromHexString(textColorHex);
    if (!background) {
        background = UIColor.systemBlueColor;
        foreground = nil;
    }
    foreground = CATAContrastingTextColor(background, foreground);

    self.abbreviation = visibleAbbreviation;
    self.label.text = visibleAbbreviation;
    self.label.textColor = foreground;
    self.backgroundColor = background;
    self.layer.borderColor = foreground.CGColor;
    self.layer.borderWidth = self.traitCollection.accessibilityContrast
        == UIAccessibilityContrastHigh ? 1.5 : 0;
    [self invalidateIntrinsicContentSize];
}

- (CGSize)intrinsicContentSize {
    CGSize labelSize = self.label.intrinsicContentSize;
    CGFloat horizontalPadding = self.variant == CATARouteBadgeVariantCompact ? 14 : 18;
    CGFloat minimumHeight = self.variant == CATARouteBadgeVariantCompact ? 24 : 30;
    CGFloat verticalPadding = self.variant == CATARouteBadgeVariantCompact ? 6 : 10;
    return CGSizeMake(MIN(88, MAX(minimumHeight, ceil(labelSize.width + horizontalPadding))),
                      MAX(minimumHeight, ceil(labelSize.height + verticalPadding)));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
    self.layer.masksToBounds = YES;
}

- (void)updateFont {
    CGFloat size = self.variant == CATARouteBadgeVariantCompact ? 12 : 14;
    UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    self.label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:base compatibleWithTraitCollection:self.traitCollection];
}

- (void)cata_badgeTraitsDidChange {
    [self updateFont];
    [self configureWithAbbreviation:self.abbreviation
                           colorHex:self.colorHex
                       textColorHex:self.textColorHex];
}

@end
