//
//  NovaWidgetBundle.swift
//  NovaWidget
//
//  Created by sakyol on 19.07.2026.
//

import WidgetKit
import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct NovaWidgetBundle: WidgetBundle {
    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        do {
            if let accessGroup = getKeychainGroup() {
                try Auth.auth().useUserAccessGroup(accessGroup)
            }
        } catch {
            print("Widget Keychain error: \(error)")
        }
    }

    var body: some Widget {
        NovaWidget()
        StreakWidget()
        BankWidget()
        FinanceWidget()
        StockWidget()
    }
}
