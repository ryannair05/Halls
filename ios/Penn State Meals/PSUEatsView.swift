//
//  PSUEatsView.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/2/23.
//

import SwiftUI
import WebView
import WebKit

struct PSUEatsView: View {
    @StateObject private var webViewStore = WebViewStore()
    private let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    var body: some View {
        VStack {
            WebView(webView: webViewStore.webView)
                .navigationTitle(webViewStore.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(action: {
                            webViewStore.webView.goBack()
                        }, label: {
                            Image(systemName: "chevron.left")
                                .imageScale(.large)
                        })
                        .disabled(!webViewStore.canGoBack)
                        .keyboardShortcut("[")
                        .contextMenu {
                            ForEach(webViewStore.webView.backForwardList.backList, id: \.self) { item in
                                Button(item.title ?? item.url.absoluteString) {
                                    webViewStore.webView.go(to: item)
                                }
                            }
                        }
                        Button(action: {
                            webViewStore.webView.goForward()
                        }, label: {
                            Image(systemName: "chevron.right")
                                .imageScale(.large)
                        })
                        .disabled(!webViewStore.canGoForward)
                        .keyboardShortcut("]")
                        .contextMenu {
                            ForEach(webViewStore.webView.backForwardList.forwardList, id: \.self) { item in
                                Button(item.title ?? item.url.absoluteString) {
                                    webViewStore.webView.go(to: item)
                                }
                            }
                        }
                        Spacer()
                    }
                }
                .toolbarRole(.browser)
        }
        .task {
            guard webViewStore.webView.backForwardList.backList.isEmpty else { return }
            var request = URLRequest(url: url)
            request.attribution = .user
            let webView = webViewStore.webView
            webView.load(request)
            webView.allowsBackForwardNavigationGestures = true
        }
    }
}


#Preview {
    PSUEatsView(url: URL(string: "https://pennstateeats.psu.edu/1114").unsafelyUnwrapped)
}
