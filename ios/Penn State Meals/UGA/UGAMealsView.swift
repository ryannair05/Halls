//
//  UGAMealsView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 9/1/23.
//

import SwiftUI

// Stable values retained for saved preferences and existing Handoff activities.
enum UGADiningHall: String, CaseIterable, Sendable {
    case bolton, oglethorpe, snelling, niche, village
}

struct UGAMealsView: View {
    @State private var legacyRequest: CampusDiningLegacyRequest?

    var body: some View {
        CampusDiningView(school: .uga, legacyRequest: legacyRequest)
            // UIKit owns the navigation and table safe-area insets, as on PSU.
            .ignoresSafeArea(.container)
            .onContinueUserActivity("com.ryannair05.pennstatemeals.view-hall") { activity in
                if let hall = activity.userInfo?["hall"] as? String,
                   UGADiningHall(rawValue: hall) != nil {
                    legacyRequest = CampusDiningLegacyRequest(hall: hall)
                }
            }
    }
}

struct UGAMealsView_Previews: PreviewProvider {
    static var previews: some View {
        UGAMealsView()
    }
}

