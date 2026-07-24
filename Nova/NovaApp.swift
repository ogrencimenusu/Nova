//
//  NovaApp.swift
//  Nova
//
//  Created by sakyol on 19.07.2026.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import WidgetKit
import FirebaseFirestore
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {
    var listener: ListenerRegistration?
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        
        // Share Firebase Auth with Widget
        do {
            if let accessGroup = getKeychainGroup() {
                try Auth.auth().useUserAccessGroup(accessGroup)
                print("Successfully set user access group to: \(accessGroup)")
                
                Auth.auth().addStateDidChangeListener { auth, user in
                    if let user = user {
                        self.startListening(uid: user.uid)
                    } else {
                        self.listener?.remove()
                        self.listener = nil
                    }
                }
            }
        } catch let error as NSError {
            print("Error changing user access group: %@", error)
        }
        
        return true
    }
    
    func startListening(uid: String) {
        let db = Firestore.firestore()
        
        // Listen to Notes
        listener?.remove()
        listener = db.collection("users").document(uid).collection("notes")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in notes! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Daily Stats
        db.collection("users").document(uid).collection("daily_stats")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in daily_stats! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Banks
        db.collection("users").document(uid).collection("banks")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in banks! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Bank Transactions
        db.collection("users").document(uid).collection("bankTransactions")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in bankTransactions! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
    }
    
    private func getKeychainGroup() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "probe",
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &item)
        
        if status == errSecSuccess,
           let itemDict = item as? [String: Any],
           let group = itemDict[kSecAttrAccessGroup as String] as? String {
            SecItemDelete(query as CFDictionary)
            return group
        } else if status == errSecDuplicateItem {
            SecItemCopyMatching(query as CFDictionary, &item)
            if let itemDict = item as? [String: Any],
               let group = itemDict[kSecAttrAccessGroup as String] as? String {
                return group
            }
        }
        return nil
    }
}

import WidgetKit

@main
struct NovaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                    
                    let full = url.absoluteString.lowercased()
                    let host = url.host?.lowercased() ?? ""
                    
                    var noteId: String? = nil
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                       let queryItems = components.queryItems {
                        noteId = queryItems.first(where: { $0.name == "id" })?.value
                    }

                    if full.contains("note") || host.contains("note") {
                        // Always store in UserDefaults for cold-launch safety
                        if let id = noteId, !id.isEmpty {
                            UserDefaults.standard.set(id, forKey: "pendingDeepLinkNoteId")
                        }
                        // Also post notification for when app is already running
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            NotificationCenter.default.post(name: Notification.Name("OpenNoteDetail"), object: noteId)
                        }
                    } else {
                        let targetOption: MenuOption?
                        if full.contains("bank") || host.contains("bank") {
                            targetOption = .bankOperations
                        } else if full.contains("finan") || full.contains("stock") || host.contains("finan") || host.contains("stock") {
                            targetOption = .financeOperations
                        } else if full.contains("dict") || full.contains("sozluk") || full.contains("streak") || host.contains("dict") || host.contains("sozluk") || host.contains("streak") {
                            targetOption = .dictionary
                        } else if full.contains("tag") || host.contains("tag") {
                            targetOption = .tags
                        } else if full.contains("setting") || host.contains("setting") {
                            targetOption = .settings
                        } else if full.contains("home") || host.contains("home") {
                            targetOption = .home
                        } else {
                            targetOption = nil
                        }
                        
                        if let option = targetOption {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: option)
                            }
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active || newPhase == .background {
                // Uygulama her açıldığında veya alta alındığında widget'ı zorla güncelle
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
