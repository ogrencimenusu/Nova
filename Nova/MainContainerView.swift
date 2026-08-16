import SwiftUI
import UIKit
import ObjectiveC

struct MainContainerView: View {
    @ObservedObject var authViewModel: AuthenticationViewModel
    @State private var selectedOption: MenuOption = .home
    
    var body: some View {
        // Native SwiftUI TabView - Side menu and custom top navigation bar removed
        TabView(selection: $selectedOption) {
            HomeView()
                .tabItem {
                    Label("Anasayfa", systemImage: "square.grid.2x2")
                }
                .tag(MenuOption.home)
            
            DictionaryView()
                .tabItem {
                    Label("Sözlük", systemImage: "book")
                }
                .tag(MenuOption.dictionary)
            
            BankOperationsView()
                .tabItem {
                    Label("Banka", systemImage: "briefcase")
                }
                .tag(MenuOption.bankOperations)
            
            FinanceOperationsView()
                .tabItem {
                    Label("Finans", systemImage: "chart.pie")
                }
                .tag(MenuOption.financeOperations)
            
            NotesView()
                .tabItem {
                    Label("Notlar", systemImage: "note.text")
                }
                .tag(MenuOption.notes)
        }
        .environmentObject(authViewModel)
        .background(TabBarMenuConfigurator())
        .onAppear {
            // Configure system tab bar to display the official Apple glass effect natively
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTab"))) { notification in
            if let targetOption = notification.object as? MenuOption {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedOption = targetOption
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

// MARK: - TabBarMenuConfigurator for Native Context Menus on TabBarItems

struct TabBarMenuConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let root = view.window?.rootViewController {
                if let tabBarController = root as? UITabBarController ?? root.findTabBarController() {
                    let tabBar = tabBarController.tabBar
                    
                    // Attach delegate proxy to catch re-tapping current active tab
                    if !(tabBarController.delegate is TabBarControllerDelegateProxy) {
                        let proxy = TabBarControllerDelegateProxy(originalDelegate: tabBarController.delegate)
                        objc_setAssociatedObject(tabBarController, &tabBarDelegateKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        tabBarController.delegate = proxy
                    }
                    
                    // Find all TabBarButton subviews representing tabs
                    let tabButtons = tabBar.subviews
                        .filter { String(describing: type(of: $0)).contains("TabBarButton") }
                        .sorted { $0.frame.minX < $1.frame.minX }
                    
                    if tabButtons.count > 1 {
                        let dictionaryButton = tabButtons[1]
                        
                        let delegate = ContextMenuDelegate(
                            pratik: {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.dictionary)
                                NotificationCenter.default.post(name: Notification.Name("SelectDictionarySection"), object: "pratik")
                            },
                            sticky: {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.dictionary)
                                NotificationCenter.default.post(name: Notification.Name("SelectDictionarySection"), object: "sticky")
                            },
                            lists: {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.dictionary)
                                NotificationCenter.default.post(name: Notification.Name("SelectDictionarySection"), object: "lists")
                            }
                        )
                        
                        // Keep a reference to the delegate so it doesn't get deallocated
                        objc_setAssociatedObject(dictionaryButton, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        
                        let interaction = UIContextMenuInteraction(delegate: delegate)
                        dictionaryButton.addInteraction(interaction)
                    }
                }
            }
        }
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private var delegateKey: UInt8 = 0
private var tabBarDelegateKey: UInt8 = 0

// MARK: - TabBarControllerDelegateProxy implementation

class TabBarControllerDelegateProxy: NSObject, UITabBarControllerDelegate {
    weak var originalDelegate: UITabBarControllerDelegate?
    
    init(originalDelegate: UITabBarControllerDelegate?) {
        self.originalDelegate = originalDelegate
    }
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if tabBarController.selectedViewController == viewController {
            if let index = tabBarController.viewControllers?.firstIndex(of: viewController) {
                if index == 1 {
                    NotificationCenter.default.post(name: Notification.Name("DictionaryTabReselected"), object: nil)
                }
            }
        }
        return originalDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
    }
    
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        originalDelegate?.tabBarController?(tabBarController, didSelect: viewController)
    }
}

// MARK: - ContextMenuDelegate UIContextMenuInteractionDelegate implementation

class ContextMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    let pratikAction: () -> Void
    let stickyAction: () -> Void
    let listsAction: () -> Void
    
    init(pratik: @escaping () -> Void, sticky: @escaping () -> Void, lists: @escaping () -> Void) {
        self.pratikAction = pratik
        self.stickyAction = sticky
        self.listsAction = lists
    }
    
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            
            let pratik = UIAction(title: "Pratik Yap", image: UIImage(systemName: "play.circle")) { _ in
                self.pratikAction()
            }
            let sticky = UIAction(title: "Sticky Notlarım", image: UIImage(systemName: "note.text")) { _ in
                self.stickyAction()
            }
            let lists = UIAction(title: "Listelerim", image: UIImage(systemName: "list.bullet")) { _ in
                self.listsAction()
            }
            
            return UIMenu(title: "", children: [pratik, sticky, lists])
        }
    }
}

extension UIViewController {
    func findTabBarController() -> UITabBarController? {
        if let tab = self as? UITabBarController {
            return tab
        }
        for child in children {
            if let tab = child.findTabBarController() {
                return tab
            }
        }
        return nil
    }
}
