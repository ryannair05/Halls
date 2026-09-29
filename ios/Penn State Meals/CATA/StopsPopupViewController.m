//
//  StopsPopupViewController.m
//  Penn State Meals
//
//  Created by Ryan Nair on 3/11/25.
//

#import "StopsPopupViewController.h"
#import "CATARouteDataSource.h"
#import "CATARouteBadgeView.h"
#import "RouteModel.h"
#include <math.h>

static NSTimeInterval CATADeviationFromString(id value) {
    if (![value isKindOfClass:NSString.class]) return 0;

    NSString *duration = (NSString *)value;
    BOOL isNegative = [duration hasPrefix:@"-"];
    if (isNegative) duration = [duration substringFromIndex:1];

    NSArray<NSString *> *components = [duration componentsSeparatedByString:@":"];
    if (components.count == 3) {
        NSTimeInterval seconds = components[0].doubleValue * 3600
            + components[1].doubleValue * 60
            + components[2].doubleValue;
        return isNegative ? -seconds : seconds;
    }

    if (![duration hasPrefix:@"PT"]) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:[duration substringFromIndex:2]];
    NSTimeInterval seconds = 0;
    while (!scanner.isAtEnd) {
        NSUInteger startLocation = scanner.scanLocation;
        double amount = 0;
        if (![scanner scanDouble:&amount]) break;
        if ([scanner scanString:@"H" intoString:nil]) {
            seconds += amount * 3600;
        } else if ([scanner scanString:@"M" intoString:nil]) {
            seconds += amount * 60;
        } else if ([scanner scanString:@"S" intoString:nil]) {
            seconds += amount;
        } else {
            break;
        }
        if (scanner.scanLocation == startLocation) break;
    }
    return isNegative ? -seconds : seconds;
}

@interface DepartureInfo ()
// Assigned only from the immutable JSON string created in fetchDepartures.
@property (nonatomic, strong, nullable) NSString *itemIdentifier;
@end

@implementation DepartureInfo

- (instancetype)initWithRouteId:(NSNumber *)routeId
                    destination:(NSString *)destination
                  departureTime:(NSDate *)departureTime
                         status:(NSString *)status
                      deviation:(NSTimeInterval)deviation {
    self = [super init];
    if (self) {
        _routeId = routeId;
        _destination = [destination copy];
        _departureTime = departureTime;
        _status = [status copy];
        _deviation = deviation;
    }
    return self;
}

- (NSString *)timeRemainingWith:(NSDateFormatter *)formatter {
    if (![self.status isEqualToString:@"Scheduled"]) {
        return self.status;
    }
    NSTimeInterval timeRemaining = [self.departureTime timeIntervalSinceNow];
    if (timeRemaining < 0) {
        return @"Late";
    } else if (timeRemaining < 60) {
        return @"Now";
    } else if (timeRemaining < 3600) {
        int minutes = (int)(timeRemaining / 60);
        return [NSString stringWithFormat:@"%d min", minutes];
    } else {
        return [formatter stringFromDate:self.departureTime];
    }
}

@end

// Programmatic cell storage; all accessors and UIKit callbacks remain dynamic.
@interface CATADepartureCell : UITableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, strong, nonnull) CATARouteBadgeView *routeBadge;
@property (nonatomic, strong, nonnull) UILabel *destinationLabel;
@property (nonatomic, strong, nonnull) UILabel *detailLabel;
@property (nonatomic, strong, nonnull) UILabel *countdownLabel;
- (void)configureWithDeparture:(DepartureInfo *)departure
                         route:(nullable RouteModel *)route
                      selected:(BOOL)selected
                     formatter:(NSDateFormatter *)formatter;
@end

@implementation CATADepartureCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(6, 12, 6, 12);

        _routeBadge = [[CATARouteBadgeView alloc] initWithVariant:CATARouteBadgeVariantCompact];
        _routeBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _routeBadge.isAccessibilityElement = NO;
        [_routeBadge setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];

        _destinationLabel = [[UILabel alloc] init];
        _destinationLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _destinationLabel.adjustsFontForContentSizeCategory = YES;
        _destinationLabel.numberOfLines = 2;

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.adjustsFontForContentSizeCategory = YES;
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.numberOfLines = 2;

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_destinationLabel, _detailLabel]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 1;
        textStack.translatesAutoresizingMaskIntoConstraints = NO;

        _countdownLabel = [[UILabel alloc] init];
        _countdownLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _countdownLabel.adjustsFontForContentSizeCategory = YES;
        _countdownLabel.textAlignment = NSTextAlignmentRight;
        _countdownLabel.numberOfLines = 1;
        _countdownLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_countdownLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                         forAxis:UILayoutConstraintAxisHorizontal];

        [self.contentView addSubview:_routeBadge];
        [self.contentView addSubview:textStack];
        [self.contentView addSubview:_countdownLabel];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_routeBadge.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_routeBadge.centerYAnchor constraintEqualToAnchor:margins.centerYAnchor],
            [textStack.leadingAnchor constraintEqualToAnchor:_routeBadge.trailingAnchor constant:8],
            [textStack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [textStack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            [_countdownLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:textStack.trailingAnchor constant:8],
            [_countdownLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_countdownLabel.centerYAnchor constraintEqualToAnchor:margins.centerYAnchor],
            [_countdownLabel.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.routeBadge configureWithAbbreviation:@"—" colorHex:nil textColorHex:nil];
    self.destinationLabel.text = nil;
    self.detailLabel.text = nil;
    self.countdownLabel.text = nil;
    self.accessibilityLabel = nil;
    self.accessibilityValue = nil;
}

- (void)configureWithDeparture:(DepartureInfo *)departure
                         route:(RouteModel *)route
                      selected:(BOOL)selected
                     formatter:(NSDateFormatter *)formatter {
    NSString *routeName = route.abbreviation.length > 0 ? route.abbreviation : departure.routeId.stringValue;
    NSString *routeLongName = route.longName.length > 0 ? route.longName : [NSString stringWithFormat:@"Route %@", routeName];
    NSString *destination = departure.destination.length > 0
        ? departure.destination.capitalizedString : @"Upcoming departure";
    if (route) [self.routeBadge configureWithRoute:route];
    else [self.routeBadge configureWithAbbreviation:routeName colorHex:nil textColorHex:nil];
    self.destinationLabel.text = routeLongName;
    UIFontDescriptor *destinationDescriptor =
        [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
    if (selected) {
        destinationDescriptor = [destinationDescriptor
            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    }
    self.destinationLabel.font = [UIFont fontWithDescriptor:destinationDescriptor size:0];
    self.countdownLabel.text = [departure timeRemainingWith:formatter];
    UIFontDescriptor *countdownDescriptor =
        [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
    if (selected) {
        countdownDescriptor = [countdownDescriptor
            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    }
    self.countdownLabel.font = [UIFont fontWithDescriptor:countdownDescriptor size:0];

    self.detailLabel.text = destination;
    self.detailLabel.textColor = UIColor.secondaryLabelColor;

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = [NSString stringWithFormat:@"Route %@, %@, to %@",
        routeName, routeLongName, destination];
    self.accessibilityValue = [NSString stringWithFormat:@"%@, %@",
        self.countdownLabel.text, departure.status];
}

@end

@interface CATADepartureDataSource : UITableViewDiffableDataSource<NSNumber *, NSString *>
@end

@implementation CATADepartureDataSource
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"Upcoming Departures";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Times are approximate and subject to change";
}
@end

@interface StopsPopupViewController ()
@property (nonatomic, strong, readwrite, nullable) UILabel *headerLabel;
@property (nonatomic, strong, readwrite, nullable) UILabel *stopIdLabel;
@property (nonatomic, strong, readwrite, nullable) UIView *headerView;
@property (nonatomic, strong, readwrite, nullable) UIView *emptyStateView;
- (CGFloat)availableRouteBadgeWidth;
- (void)rebuildRouteBadgeRowsForWidth:(CGFloat)width;
- (void)cata_contentSizeCategoryDidChange;
- (void)loadRouteMetadata;
- (void)applyDepartureSnapshotAnimatingDifferences:(BOOL)animated;
@end

@implementation StopsPopupViewController {
    NSURLSessionDataTask *_currentTask;
    BOOL _isLoading;
    NSISO8601DateFormatter *_dateFormatter;
    NSDateFormatter *_timeFormatter;
    UIActivityIndicatorView *_loadingIndicator;
    CATADepartureDataSource *_departureDataSource;
    NSDictionary<NSString *, DepartureInfo *> *_departuresByID;
    UIStackView *_routeBadges;
    NSDictionary<NSNumber *, RouteModel *> *_routeModelsByID;
    NSSet<NSNumber *> *_selectedRouteIDs;
    NSArray<NSNumber *> *_badgeRouteIDs;
    NSInteger _routeBadgeWidthBucket;
    NSUUID *_departuresRequestID;
    NSString *_departuresLoadError;
    CGFloat _lastHeaderLayoutWidth;
}

- (instancetype)initWithTitle:(NSString *)title stopId:(NSNumber *)stopId location:(CLLocationDistance)userLocation annotations:(NSMutableDictionary<NSString *, KMLParser *> *)busAnnotations {
    if (self = [super initWithStyle:UITableViewStylePlain]) {
        _stopName = [title copy];
        _stopId = stopId;
        _userLocation = userLocation;
        _busAnnotations = busAnnotations;
        
        _departures = @[];
        _routeModelsByID = @{};
        NSDictionary<NSString *, NSNumber *> *savedRoutes =
            [NSUserDefaults.standardUserDefaults dictionaryForKey:@"selectedRoutes"];
        _selectedRouteIDs = [NSSet setWithArray:savedRoutes.allValues ?: @[]];
        _badgeRouteIDs = @[];
        _routeBadgeWidthBucket = NSNotFound;
        _lastHeaderLayoutWidth = NAN;
        _isLoading = NO;
        
        _dateFormatter = [[NSISO8601DateFormatter alloc] init];
        _dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
        _dateFormatter.formatOptions = NSISO8601DateFormatWithYear | NSISO8601DateFormatWithMonth | NSISO8601DateFormatWithDay | NSISO8601DateFormatWithTime | NSISO8601DateFormatWithDashSeparatorInDate | NSISO8601DateFormatWithColonSeparatorInTime;
        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateStyle = NSDateFormatterNoStyle;
        _timeFormatter.timeStyle = NSDateFormatterShortStyle;
        _timeFormatter.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self.tableView registerClass:CATADepartureCell.class forCellReuseIdentifier:@"DepartureCell"];
    [self registerForTraitChanges:@[UITraitPreferredContentSizeCategory.class]
                       withAction:@selector(cata_contentSizeCategoryDidChange)];

    [self setupDepartureDataSource];
    
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent],
        [UISheetPresentationControllerDetent largeDetent]];
    sheet.prefersGrabberVisible = YES;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;

    // Add loading indicator
    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
    
    [self fetchDepartures];
    [self loadRouteMetadata];
}

- (void)dealloc {
    [_currentTask cancel];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self cancelDepartureLoading];
}

- (void)loadRouteMetadata {
    __weak typeof(self) weakSelf = self;
    [CATARouteDataSource.shared
        loadVisibleRoutesWithMaximumAge:CATARouteDisplayCacheMaximumAge
        notifyOnRefresh:NO
        completion:^(NSArray<RouteModel *> *routeModels, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || routeModels.count == 0) return;
        NSMutableDictionary<NSNumber *, RouteModel *> *routes = [NSMutableDictionary dictionary];
        for (RouteModel *route in routeModels) {
            routes[@(route.routeId)] = route;
        }
        self->_routeModelsByID = [routes copy];
        self->_routeBadgeWidthBucket = NSNotFound;
        [self setupHeaderView];
        [self applyDepartureSnapshotAnimatingDifferences:NO];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (!header || width <= 0) return;
    if (isfinite(_lastHeaderLayoutWidth) && fabs(_lastHeaderLayoutWidth - width) < 0.5) return;
    _lastHeaderLayoutWidth = width;
    [self rebuildRouteBadgeRowsForWidth:[self availableRouteBadgeWidth]];
    header.frame = CGRectMake(0, 0, width, header.frame.size.height);
    [header setNeedsLayout];
    CGSize size = [header systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = ceil(size.height);
    if (fabs(header.frame.size.height - height) < 0.5) return;
    header.frame = CGRectMake(0, 0, width, height);
    self.tableView.tableHeaderView = header;
}

- (void)cata_contentSizeCategoryDidChange {
    _lastHeaderLayoutWidth = NAN;
    _routeBadgeWidthBucket = NSNotFound;
    [self.view setNeedsLayout];
}

- (void)fetchDepartures {
    if (_isLoading) return;

    NSUUID *requestID = [NSUUID UUID];
    _departuresRequestID = requestID;
    _isLoading = YES;
    if (!self.headerView && self.departures.count == 0) {
        [_loadingIndicator startAnimating];
    }
    
    NSString *departuresURLString = [NSString stringWithFormat:@"https://realtime.catabus.com/InfoPoint/rest/StopDepartures/Get/%@", self.stopId];
    NSURL *departuresURL = [NSURL URLWithString:departuresURLString];
    
    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:departuresURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        NSMutableArray *departureInfos = [NSMutableArray array];
        BOOL requestSucceeded = !error && data.length > 0 && httpResponse.statusCode == 200;
        NSString *loadError = nil;

        if (requestSucceeded) {
            NSError *jsonError = nil;
            id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            NSArray *responseArray = [jsonObject isKindOfClass:NSArray.class]
                ? (NSArray *)jsonObject : nil;
            requestSucceeded = !jsonError && responseArray != nil;

            NSArray *routeDirections = @[];
            if (requestSucceeded && responseArray.count > 0) {
                NSDictionary *jsonResponse = [responseArray.firstObject isKindOfClass:NSDictionary.class]
                    ? responseArray.firstObject : nil;
                routeDirections = [jsonResponse[@"RouteDirections"] isKindOfClass:NSArray.class]
                    ? jsonResponse[@"RouteDirections"] : nil;
                requestSucceeded = jsonResponse != nil && routeDirections != nil;
            }

            if (requestSucceeded) {
                for (id routeDirectionValue in routeDirections) {
                    if (![routeDirectionValue isKindOfClass:NSDictionary.class]) {
                        requestSucceeded = NO;
                        break;
                    }
                    NSDictionary *routeDirection = routeDirectionValue;
                    NSNumber *routeId = [routeDirection[@"RouteId"] isKindOfClass:NSNumber.class]
                        ? routeDirection[@"RouteId"] : nil;
                    NSArray *departures = [routeDirection[@"Departures"] isKindOfClass:NSArray.class]
                        ? routeDirection[@"Departures"] : nil;
                    if (!routeId || !departures) {
                        requestSucceeded = NO;
                        break;
                    }

                    for (id departureValue in departures) {
                        if (![departureValue isKindOfClass:NSDictionary.class]) {
                            requestSucceeded = NO;
                            break;
                        }
                        NSDictionary *departure = departureValue;
                        NSString *timeString = departure[@"EDTLocalTime"];
                        if (![timeString isKindOfClass:NSString.class]) continue;
                        NSDate *departureTime = [self->_dateFormatter dateFromString:timeString];
                        if (!departureTime) continue;

                        NSTimeInterval deviation = CATADeviationFromString(departure[@"Dev"]);

                        NSDictionary *tripInfo = [departure[@"Trip"] isKindOfClass:NSDictionary.class]
                            ? departure[@"Trip"] : @{};
                        NSString *destination = [tripInfo[@"InternetServiceDesc"] isKindOfClass:NSString.class]
                            ? tripInfo[@"InternetServiceDesc"] : @"Upcoming departure";
                        NSString *status = [tripInfo[@"TripStatusReportLabel"] isKindOfClass:NSString.class]
                            ? tripInfo[@"TripStatusReportLabel"] : @"Scheduled";

                        DepartureInfo *departureInfo = [[DepartureInfo alloc] initWithRouteId:routeId
                                                                                  destination:destination
                                                                                departureTime:departureTime
                                                                                       status:status
                                                                                    deviation:deviation];
                        // Scheduled time stays stable when the estimated departure changes.
                        id tripID = tripInfo[@"TripRecordId"] ?: tripInfo[@"TripId"];
                        NSString *scheduledTime = [departure[@"SDTLocalTime"] isKindOfClass:NSString.class]
                            ? departure[@"SDTLocalTime"] : timeString;
                        NSArray *identity = @[routeId, tripID ?: NSNull.null,
                            tripInfo[@"StopSequence"] ?: NSNull.null, scheduledTime];
                        NSData *identityData = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
                        departureInfo.itemIdentifier = [[NSString alloc] initWithData:identityData encoding:NSUTF8StringEncoding];
                        [departureInfos addObject:departureInfo];
                    }
                    if (!requestSucceeded) break;
                }
            }

            if (requestSucceeded) {
                [departureInfos sortUsingComparator:^NSComparisonResult(DepartureInfo *obj1, DepartureInfo *obj2) {
                    return [obj1.departureTime compare:obj2.departureTime];
                }];
            }
            if (!requestSucceeded) loadError = jsonError.localizedDescription ?: @"CATA returned an invalid departure response.";
        } else {
            loadError = error.localizedDescription ?: @"CATA returned an invalid departure response.";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self->_departuresRequestID isEqual:requestID]) return;
            self->_currentTask = nil;
            self->_isLoading = NO;
            [self->_loadingIndicator stopAnimating];

            if (requestSucceeded) {
                self.departures = departureInfos;
                self->_departuresLoadError = nil;
            } else {
                self->_departuresLoadError = loadError ?: @"CATA is temporarily unavailable.";
                if (error.code != NSURLErrorCancelled) {
                    NSLog(@"Error fetching departures: %@", self->_departuresLoadError);
                }
            }

            [self setupHeaderView];
            [self applyDepartureSnapshotAnimatingDifferences:YES];
        });
    }];
    
    [_currentTask resume];
}

- (void)setupHeaderView {
    [self.emptyStateView removeFromSuperview];
    self.emptyStateView = nil;

    if (!self.headerView) {
        UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 1)];
        self.headerView = headerView;

        UILabel *headerLabel = [[UILabel alloc] init];
        headerLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
            scaledFontForFont:[UIFont systemFontOfSize:24 weight:UIFontWeightBold]];
        headerLabel.adjustsFontForContentSizeCategory = YES;
        headerLabel.numberOfLines = 0;
        headerLabel.textAlignment = NSTextAlignmentCenter;
        self.headerLabel = headerLabel;

        UILabel *stopIdLabel = [[UILabel alloc] init];
        stopIdLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        stopIdLabel.adjustsFontForContentSizeCategory = YES;
        stopIdLabel.textColor = UIColor.secondaryLabelColor;
        stopIdLabel.numberOfLines = 0;
        stopIdLabel.textAlignment = NSTextAlignmentLeft;
        self.stopIdLabel = stopIdLabel;

        _routeBadges = [[UIStackView alloc] init];
        _routeBadges.axis = UILayoutConstraintAxisVertical;
        _routeBadges.alignment = UIStackViewAlignmentTrailing;
        _routeBadges.spacing = 5;
        [_routeBadges setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
        [_routeBadges setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                      forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *detailsRow = [[UIStackView alloc] initWithArrangedSubviews:@[
            stopIdLabel, _routeBadges
        ]];
        detailsRow.axis = UILayoutConstraintAxisHorizontal;
        detailsRow.alignment = UIStackViewAlignmentCenter;
        detailsRow.spacing = 8;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            headerLabel, detailsRow
        ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 0;
        [stack setCustomSpacing:14 afterView:headerLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [headerView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:headerView.topAnchor constant:16],
            [stack.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
            [stack.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor],
        ]];
    }

    self.headerLabel.text = self.stopName;
    double distanceInMiles = self.userLocation * 0.000621371192;
    NSMutableString *details = [NSMutableString stringWithFormat:@"Stop #%@", self.stopId];
    if (distanceInMiles > 0) {
        [details appendFormat:@" · %.1f miles away", distanceInMiles];
    }
    if (_departuresLoadError && self.departures.count > 0) {
        [details appendString:NSLocalizedString(@" · Live updates unavailable", nil)];
    }
    self.stopIdLabel.text = details;

    NSMutableDictionary<NSNumber *, DepartureInfo *> *routes = [NSMutableDictionary dictionary];
    for (DepartureInfo *departure in self.departures) routes[departure.routeId] = departure;
    NSArray<NSNumber *> *routeIDs = [routes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if (![routeIDs isEqualToArray:_badgeRouteIDs]) {
        _badgeRouteIDs = routeIDs;
        _routeBadgeWidthBucket = NSNotFound;
    }
    [self rebuildRouteBadgeRowsForWidth:[self availableRouteBadgeWidth]];
    _routeBadges.hidden = routeIDs.count == 0;

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    _lastHeaderLayoutWidth = width;
    self.headerView.frame = CGRectMake(0, 0, width, self.headerView.frame.size.height);
    [self.headerView setNeedsLayout];
    CGSize size = [self.headerView systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = ceil(size.height);
    if (self.tableView.tableHeaderView != self.headerView ||
        fabs(self.headerView.frame.size.height - height) >= 0.5) {
        self.headerView.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = self.headerView;
    }

    if (self.departures.count == 0 && !_isLoading) {
        UIContentUnavailableConfiguration *config = [UIContentUnavailableConfiguration emptyConfiguration];
        if (_departuresLoadError) {
            config.text = @"Departures unavailable";
            config.secondaryText = @"Departures will retry automatically.";
            config.image = [UIImage systemImageNamed:@"wifi.exclamationmark"];
        } else {
            config.text = @"No upcoming departures";
            config.secondaryText = @"Departures update automatically.";
            config.image = [UIImage systemImageNamed:@"calendar.badge.minus"];
        }
        UIContentUnavailableView *unavailableView =
            [[UIContentUnavailableView alloc] initWithConfiguration:config];
        unavailableView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.tableView addSubview:unavailableView];
        [NSLayoutConstraint activateConstraints:@[
            [unavailableView.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
            [unavailableView.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
            [unavailableView.widthAnchor constraintEqualToAnchor:self.tableView.widthAnchor],
        ]];
        self.emptyStateView = unavailableView;
    }
}

- (CGFloat)availableRouteBadgeWidth {
    CGFloat contentWidth = MAX(0, CGRectGetWidth(self.tableView.bounds) - 32);
    if (_badgeRouteIDs.count == 0) return 0;
    CGFloat detailsWidth = [self.stopIdLabel sizeThatFits:
        CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width;
    return MAX(0, contentWidth - MIN(detailsWidth, contentWidth) - 8);
}

- (void)rebuildRouteBadgeRowsForWidth:(CGFloat)width {
    if (!_routeBadges) return;
    NSInteger widthBucket = width > 0 ? (NSInteger)floor(width / 24.0) : 0;
    if (_routeBadgeWidthBucket == widthBucket && _routeBadges.arrangedSubviews.count > 0) return;
    _routeBadgeWidthBucket = widthBucket;
    for (UIView *row in [_routeBadges.arrangedSubviews copy]) {
        [_routeBadges removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    UIStackView *(^newRow)(void) = ^UIStackView *{
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 5;
        return row;
    };
    UIStackView *row = newRow();
    CGFloat rowWidth = 0;
    for (NSNumber *routeID in _badgeRouteIDs) {
        RouteModel *route = _routeModelsByID[routeID];
        CATARouteBadgeView *badge = [[CATARouteBadgeView alloc] initWithVariant:CATARouteBadgeVariantCompact];
        if (route) [badge configureWithRoute:route];
        else [badge configureWithAbbreviation:routeID.stringValue colorHex:nil textColorHex:nil];
        [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        CGFloat itemWidth = [badge systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width;
        CGFloat proposedWidth = rowWidth + (row.arrangedSubviews.count > 0 ? row.spacing : 0) + itemWidth;
        if (width > 0 && row.arrangedSubviews.count > 0 && proposedWidth > width) {
            [_routeBadges addArrangedSubview:row];
            row = newRow();
            rowWidth = 0;
        }
        [row addArrangedSubview:badge];
        rowWidth += (row.arrangedSubviews.count > 1 ? row.spacing : 0) + itemWidth;
    }
    if (row.arrangedSubviews.count > 0) [_routeBadges addArrangedSubview:row];
}

- (void)refreshDeparturesIfVisible {
    if (!self.isViewLoaded || self.view.window == nil || self.isBeingDismissed ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary<NSString *, NSNumber *> *savedRoutes =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"selectedRoutes"];
    _selectedRouteIDs = [NSSet setWithArray:savedRoutes.allValues ?: @[]];
    [self fetchDepartures];
}

- (void)cancelDepartureLoading {
    _departuresRequestID = nil;
    [_currentTask cancel];
    _currentTask = nil;
    _isLoading = NO;
    [_loadingIndicator stopAnimating];
}

- (void)setupDepartureDataSource {
    __weak typeof(self) weakSelf = self;
    _departureDataSource = [[CATADepartureDataSource alloc] initWithTableView:self.tableView
        cellProvider:^UITableViewCell *(UITableView *tableView, NSIndexPath *indexPath, NSString *identifier) {
        __strong typeof(weakSelf) self = weakSelf;
        CATADepartureCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DepartureCell" forIndexPath:indexPath];
        if (!self) return cell;
        DepartureInfo *departure = self->_departuresByID[identifier];
        RouteModel *route = self->_routeModelsByID[departure.routeId];
        NSString *routeKey = [NSString stringWithFormat:@"Route%@.kml", departure.routeId];
        BOOL selected = self.busAnnotations[routeKey] != nil ||
            [self->_selectedRouteIDs containsObject:departure.routeId];
        [cell configureWithDeparture:departure route:route selected:selected formatter:self->_timeFormatter];
        return cell;
    }];
}

- (void)applyDepartureSnapshotAnimatingDifferences:(BOOL)animated {
    BOOL hadRows = _departuresByID.count > 0;
    NSUInteger capacity = self.departures.count;
    NSMutableDictionary<NSString *, DepartureInfo *> *departuresByID =
        [NSMutableDictionary dictionaryWithCapacity:capacity];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:capacity];
    NSMutableArray<NSString *> *retainedIDs = [NSMutableArray arrayWithCapacity:capacity];
    for (DepartureInfo *departure in self.departures) {
        NSString *identifier = departure.itemIdentifier;
        // Coalesce duplicate records from the service rather than duplicating snapshot IDs.
        if (!identifier || departuresByID[identifier]) continue;
        departuresByID[identifier] = departure;
        [identifiers addObject:identifier];
        if (_departuresByID[identifier]) [retainedIDs addObject:identifier];
    }
    _departuresByID = [departuresByID copy];
    NSDiffableDataSourceSnapshot<NSNumber *, NSString *> *snapshot = [[NSDiffableDataSourceSnapshot alloc] init];
    [snapshot appendSectionsWithIdentifiers:@[@0]];
    [snapshot appendItemsWithIdentifiers:identifiers intoSectionWithIdentifier:@0];
    // Existing departures retain their identity while countdowns and status update.
    [snapshot reconfigureItemsWithIdentifiers:retainedIDs];
    if (hadRows) {
        [_departureDataSource applySnapshot:snapshot animatingDifferences:animated && self.view.window != nil];
    } else {
        // There are no existing rows to preserve or animate; skip the diff.
        [_departureDataSource applySnapshotUsingReloadData:snapshot];
    }
}

@end
