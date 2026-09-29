//
//  Penn_State_MealsApp.swift
//  Penn State Meals
//
//  Created by Ryan Nair on 2/1/23.
//

import SwiftUI
import AppIntents
import FirebaseCore
import Combine

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    @MainActor var isBTChatSelected = false {
        didSet { chatViewModel?.meshService.setBackgroundReceptionEnabled(isBTChatSelected) }
    }
    weak var chatViewModel: BitchatViewModel?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Firebase is optional in source builds. Add your own plist as an app resource.
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        if #available(iOS 26.0, *) {
            // Siri must fetch suggested hall entities before it can expand parameterized phrases.
            DiningHallShortcuts.updateAppShortcutParameters()
        }
        return true;
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                DispatchQueue.main.async {
                    self.chatViewModel?.startPrivateChat(with: peerID)
                }
            }
        }
        if response.notification.request.content.categoryIdentifier
                == MealReminderScheduler.categoryIdentifier,
           let rawID = userInfo[MealReminderScheduler.recordIDKey] as? String,
           let recordID = UUID(uuidString: rawID) {
            MealReminderNavigation.queue(recordID)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .meetAndEatOpenMealRecord,
                    object: recordID
                )
            }
        }
        
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                // Don't show notification if the private chat is already open
                if chatViewModel?.selectedPrivateChatPeer == peerID {
                    completionHandler([])
                    return
                }
            }
        }
        
        // Show notification in all other cases
        completionHandler([.banner])
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        chatViewModel?.applicationWillTerminate()
    }
}

// Compatibility only: the unmodified bitchat dependency requests this delegate
// through @EnvironmentObject. App-owned views receive the delegate directly.
extension AppDelegate: nonisolated ObservableObject {}

@main
struct Penn_State_MealsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
    }
}
