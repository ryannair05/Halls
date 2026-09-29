//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct BitchatApp: View {
    @StateObject private var chatViewModel = BitchatViewModel()
    @EnvironmentObject var appDelegate: AppDelegate
    
    var body: some View {
        BitchatContentView()
            .environmentObject(chatViewModel)
            .onAppear {
                // Check for shared content
                chatViewModel.startServices()
                UNUserNotificationCenter.current().delegate = appDelegate
                
                appDelegate.chatViewModel = chatViewModel
                chatViewModel.meshService.setBackgroundReceptionEnabled(appDelegate.isBTChatSelected)
            }
    }
}
