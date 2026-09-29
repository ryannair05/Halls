//
//  BarnardMealsView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 8/29/23.
//

import SwiftUI

// Stable values retained for saved preferences and existing Handoff activities.
enum BarnardDiningHall: String, CaseIterable, Sendable {
    case hewitt, kosher, lefrak, liz
}

struct BarnardMealsView: View {
    var body: some View {
        CampusDiningView(school: .barnardColumbia)
            // UIKit owns the navigation and table safe-area insets, as on PSU.
            .ignoresSafeArea(.container)
    }
}

struct BarnardMealsView_Previews: PreviewProvider {
    static var previews: some View {
        BarnardMealsView()
    }
}
