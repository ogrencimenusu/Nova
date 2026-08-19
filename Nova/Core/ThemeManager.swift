//
//  ThemeManager.swift
//  Nova
//

import SwiftUI
import Combine
import WidgetKit

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    public var id: String { self.rawValue }
    
    public var title: String {
        switch self {
        case .system: return "Sistem Teması"
        case .light: return "Aydınlık Mod"
        case .dark: return "Karanlık Mod"
        }
    }
    
    public var iconName: String {
        switch self {
        case .system: return "gearshape"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    private static let appGroupSuiteName = "A64NZ37MJD.group.sakyol.nova"
    private static let themeStorageKey = "app_theme_mode"
    
    @Published public var currentTheme: AppTheme {
        didSet {
            saveTheme(currentTheme)
        }
    }
    
    private init() {
        let savedRaw: String
        if let sharedDefaults = UserDefaults(suiteName: ThemeManager.appGroupSuiteName),
           let raw = sharedDefaults.string(forKey: ThemeManager.themeStorageKey) {
            savedRaw = raw
        } else if let raw = UserDefaults.standard.string(forKey: ThemeManager.themeStorageKey) {
            savedRaw = raw
        } else {
            savedRaw = AppTheme.system.rawValue
        }
        
        self.currentTheme = AppTheme(rawValue: savedRaw) ?? .system
    }
    
    public func setTheme(_ theme: AppTheme) {
        self.currentTheme = theme
    }
    
    private func saveTheme(_ theme: AppTheme) {
        // Save to App Group for Widget access
        if let sharedDefaults = UserDefaults(suiteName: ThemeManager.appGroupSuiteName) {
            sharedDefaults.set(theme.rawValue, forKey: ThemeManager.themeStorageKey)
            sharedDefaults.synchronize()
        }
        
        // Save locally
        UserDefaults.standard.set(theme.rawValue, forKey: ThemeManager.themeStorageKey)
        
        // Notify WidgetKit to refresh widgets with new theme colors
        WidgetCenter.shared.reloadAllTimelines()
        
        NotificationCenter.default.post(name: Notification.Name("AppThemeDidChange"), object: theme)
    }
}

// SwiftUI Helper Modifier for Theme Application
public struct AppThemeModifier: ViewModifier {
    @ObservedObject var themeManager = ThemeManager.shared
    
    public func body(content: Content) -> some View {
        content
            .preferredColorScheme(themeManager.currentTheme.colorScheme)
    }
}

public extension View {
    func withAppTheme() -> some View {
        self.modifier(AppThemeModifier())
    }
}
