//
//  InfoView.swift
//  Meet and Eat
//
//  Created by Ryan Nair on 8/27/23.
//

import SwiftUI

private struct InfoRowView: View {
    let title: String
    let linkDestination: String

    var body: some View {
        VStack {
            Divider().padding(.vertical, 4)
            HStack {
                if let url = URL(string: linkDestination) {
                    Link(destination: url) {
                        Text(title)
                    }
                } else {
                    Text(title)
                }
            }
        }
    }
}

@MainActor
struct InfoView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 12) {
                    AnimatedAppLogo()
                        .frame(width: 150, height: 150)
                    Text("Halls")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .tracking(-1)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)

                Text("Developing this app was an amazing experience and thank you to everyone who helped along the way. This app has won HackPSU and the Swift Student Challenge.")
                    .font(.body)
                    .padding(.all, 8)
                
                Text("While the app was designed to be used at my university, Penn State, it can be expanded to work at any college. Get in touch if you would like your university to add support!")
                    .font(.body)
                    .padding(.horizontal, 8)
                    .lineLimit(nil)
                
                Text("Features")
                    .font(.title2)
                    .fontWeight(.medium)
                    .padding(.all, 8)
                    .lineLimit(nil)
                
                InfoRowView(title: "WJAC-TV", linkDestination: "https://wjactv.com/news/local/psu-student-wins-apples-swift-student-challenge-with-an-app-he-created")
                InfoRowView(title: "TAPinto", linkDestination: "https://www.tapinto.net/towns/west-essex/sections/education/articles/penn-state-student-from-west-caldwell-invents-app-and-gets-to-meet-apple-ceo")
                InfoRowView(title: " The Daily Collegian", linkDestination: "https://www.psucollegian.com/news/campus/new-student-created-dining-app-for-social-engagements-created-on-campus/article_c1788466-55c7-11ee-a29f-8b2a3fd82abd.html")
                InfoRowView(title: "Her Campus", linkDestination: "https://www.hercampus.com/life/meet-and-eat-app-explainer/")
                InfoRowView(title: "HackPSU Winner", linkDestination: "https://devpost.com/software/meet-eat-t1jipf")
                
                Text("Thanks to Jason Selsley, Danielle Rapsas, and Zöe Dilts for their support and help bringing Halls to life for their universities")
                    .padding(.all, 15)
            }
            .padding(.vertical)
        }
        .navigationTitle("Information")
    }
}

struct InfoView_Previews: PreviewProvider {
    static var previews: some View {
        InfoView()
    }
}
