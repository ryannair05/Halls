//
//  RouteListViewController.m
//  Penn State Meals
//
//  Created by Ryan Nair on 5/16/25.
//

#import "RouteListViewController.h"
#import "CATARouteDataSource.h"
#import "CATARouteBadgeView.h"
#import "../Transit/PSUShuttleCoordinator.h"
#import <objc/message.h>
    
@interface RouteListViewController ()
// Main-thread state; preserve the existing isLoading getter selector.
@property (nonatomic) BOOL shuttleLoading;
@property (nonatomic, assign, readwrite) BOOL isLoading;
@property (nonatomic, strong, readwrite, nullable) NSError *error;
@property (nonatomic, strong, readwrite, nullable) UIActivityIndicatorView *loadingIndicator;
@end

@implementation RouteListViewController

- (instancetype)initWithSavedData:(NSArray<NSNumber *> *)savedData {
    self = [super init];
    if (self) {
        _selectedRouteIDs = [NSMutableSet setWithArray:savedData];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 60)];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Available Routes";
    titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [headerView addSubview:titleLabel];
    
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeClose];
    [closeButton addTarget:self action:@selector(dismissView) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:closeButton];
    
    // Layout header elements
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [titleLabel.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        
        [closeButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],
        [closeButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
    ]];
    
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70.0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.tableHeaderView = headerView;
    
    // Setup loading indicator
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _loadingIndicator = indicator;
    indicator.center = self.view.center;
    [self.view addSubview:indicator];
    
    [self fetchRoutes];
    self.shuttleLoading = YES;
    __weak typeof(self) weakSelf = self;
    [self.shuttles loadRoutes:^{
        weakSelf.shuttleLoading = NO;
        [weakSelf.tableView reloadData];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Closing while loading (or offline with no cached catalog) is not "deselect all".
    if (!routes.count) return;
    
    NSMutableDictionary<NSString *, NSNumber *> *savedData = [NSMutableDictionary dictionary];
    
    for (RouteModel *route in routes) {
        NSString *traceFilename = route.traceFilename;
        if (traceFilename.length > 0 && [_selectedRouteIDs containsObject:@(route.routeId)]) {
            savedData[traceFilename] = @(route.routeId);
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:savedData forKey:@"selectedRoutes"];
    
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wundeclared-selector"
        ((void(*)(id, SEL, NSDictionary<NSString *, NSNumber *> *)) objc_msgSend)(_viewController, @selector(handleSelectedRoutesChanged:), savedData);
    #pragma clang diagnostic pop
    
}

- (void)dismissView {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)fetchRoutes {
    _isLoading = YES;
    [_loadingIndicator startAnimating];

    __weak typeof(self) weakSelf = self;
    [CATARouteDataSource.shared
        loadVisibleRoutesWithMaximumAge:CATARouteOperationalCacheMaximumAge
        notifyOnRefresh:NO
        completion:^(NSArray<RouteModel *> *routeModels, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.isLoading = NO;
        [self.loadingIndicator stopAnimating];

        if (routeModels.count == 0) {
            self.error = error;
            [self showError];
            return;
        }

        self->routes = routeModels;
        [self.tableView reloadData];
    }];
}

- (void)showError {
    // Keep the independent shuttle section accessible if CATA metadata is unavailable.
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.shuttles ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? NSLocalizedString(@"Campus Shuttles · Pro", nil) : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0 && self.error && !routes.count) return NSLocalizedString(@"No CATA routes found", nil);
    return nil;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 1 ? MAX(1, self.shuttles.routes.count) : routes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShuttleRoute"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ShuttleRoute"];
        cell.textLabel.numberOfLines = 2;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryView = nil;
        if (!self.shuttles.routes.count) {
            cell.textLabel.text = self.shuttleLoading ? NSLocalizedString(@"Loading campus shuttles…", nil) : NSLocalizedString(@"Shuttle routes unavailable", nil);
            cell.detailTextLabel.text = self.shuttleLoading ? nil : NSLocalizedString(@"Tap to retry", nil);
            cell.imageView.image = [UIImage systemImageNamed:@"bus.fill"];
            cell.imageView.tintColor = UIColor.secondaryLabelColor;
        } else {
            PSUShuttleRoute *route = self.shuttles.routes[indexPath.row];
            cell.textLabel.text = route.name;
            cell.detailTextLabel.text = self.shuttleProUnlocked ? NSLocalizedString(@"Campus Shuttle", nil) : NSLocalizedString(@"Unlock live tracking with Halls Pro", nil);
            BOOL selected = [self.shuttles.selectedRouteIDs containsObject:route.identifier] && self.shuttleProUnlocked;
            cell.imageView.image = [UIImage systemImageNamed:self.shuttleProUnlocked ? (selected ? @"checkmark.circle.fill" : @"circle") : @"lock.fill"];
            cell.imageView.tintColor = route.color;
        }
        return cell;
    }
    static NSString *cellIdentifier = @"RouteCell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
    }
    
    RouteModel *route = routes[indexPath.row];
    
    // Configure cell
    cell.textLabel.text = route.longName;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    // Route trace filenames are implementation details, not useful route descriptions.
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    
    // Create badge view
    UIView *badgeView = [self createBadgeViewForRoute:route];
    cell.accessoryView = badgeView;
    
    // Set checkmark image
    if ([_selectedRouteIDs containsObject:@(route.routeId)]) {
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"circle"];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
    }
    
    return cell;
}

- (UIView *)createBadgeViewForRoute:(RouteModel *)route {
    CATARouteBadgeView *badge = [[CATARouteBadgeView alloc] initWithVariant:CATARouteBadgeVariantStandard];
    [badge configureWithRoute:route];
    CGSize size = badge.intrinsicContentSize;
    badge.frame = CGRectMake(0, 0, size.width, size.height);
    return badge;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.section == 1) {
        if (!self.shuttles.routes.count) {
            self.shuttleLoading = YES;
            [tableView reloadData];
            __weak typeof(self) weakSelf = self;
            [self.shuttles loadRoutes:^{ weakSelf.shuttleLoading = NO; [weakSelf.tableView reloadData]; }];
            return;
        }
        NSNumber *identifier = self.shuttles.routes[indexPath.row].identifier;
        if (!self.shuttleProUnlocked) {
            __weak typeof(self) weakSelf = self;
            if (self.requestShuttlePro) self.requestShuttlePro(^(BOOL unlocked) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || !unlocked) return;
                self.shuttleProUnlocked = YES;
                NSMutableSet *selected = [self.shuttles.selectedRouteIDs mutableCopy];
                [selected addObject:identifier];
                self.shuttles.selectedRouteIDs = selected;
                if (self.shuttleSelectionChanged) self.shuttleSelectionChanged();
                [self.tableView reloadData];
            });
        } else {
            NSMutableSet *selected = [self.shuttles.selectedRouteIDs mutableCopy];
            if ([selected containsObject:identifier]) [selected removeObject:identifier]; else [selected addObject:identifier];
            self.shuttles.selectedRouteIDs = selected;
            if (self.shuttleSelectionChanged) self.shuttleSelectionChanged();
            [tableView reloadData];
        }
        return;
    }
    RouteModel *selectedRoute = routes[indexPath.row];
    NSNumber *routeId = @(selectedRoute.routeId);
    
    if ([_selectedRouteIDs containsObject:routeId]) {
        [_selectedRouteIDs removeObject:routeId];
    } else {
        [_selectedRouteIDs addObject:routeId];
    }
    
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

@end
