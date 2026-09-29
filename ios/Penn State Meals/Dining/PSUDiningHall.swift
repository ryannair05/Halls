import Foundation
import CoreLocation

enum PSUDiningHall: String, CaseIterable, Identifiable, Sendable {
    case north = "north"
    case east = "east"
    case south = "south"
    case west = "west"
    case pollock = "pollock"
    var id: Self { self }
    var providerID: DiningProviderID { .pennState }
    var calendarContext: ProviderCalendarContext { ProviderCalendarContexts.pennState }
    var locationID: DiningLocationID { DiningLocationID(provider: .pennState, rawValue: rawValue) }

    var menuNumber: Int {
        switch self {
            case .north:
                return 17
            case .east:
                return 11
            case .south:
                return 13
            case .west:
                return 16
            case .pollock:
                return 14
        }
    }
}

extension PSUDiningHall {
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .north:
            return CLLocationCoordinate2DMake(40.802818, -77.866092)
        case .east:
            return CLLocationCoordinate2DMake(40.806427, -77.862289)
        case .south:
            return CLLocationCoordinate2DMake(40.799563, -77.855952)
        case .west:
            return CLLocationCoordinate2DMake(40.795732, -77.867459)
        case .pollock:
            return CLLocationCoordinate2DMake(40.801819, -77.856322)
        }
    }
}
