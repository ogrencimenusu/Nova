import SwiftUI

struct MainTabView: View {
    @ObservedObject var authViewModel: AuthenticationViewModel
    
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Anasayfa", systemImage: "square.grid.2x2")
                }
            
            BankOperationsView()
                .tabItem {
                    Label("Banka İşlemleri", systemImage: "briefcase")
                }
            
            FinanceOperationsView()
                .tabItem {
                    Label("Finans İşlemleri", systemImage: "chart.pie")
                }
            
            NotesView()
                .tabItem {
                    Label("Notlar", systemImage: "note.text")
                }
            
            TagsView()
                .tabItem {
                    Label("Etiketler", systemImage: "tag")
                }
            
            DictionaryView()
                .tabItem {
                    Label("Sözlük", systemImage: "book")
                }
            
            RecentlyDeletedView()
                .tabItem {
                    Label("Son Silinenler", systemImage: "trash")
                }
            
            SettingsView()
                .tabItem {
                    Label("Ayarlar", systemImage: "gearshape")
                }
        }
        // Native TabView automatically puts items > 4 into a "More" (Daha Fazla) tab.
    }
}

// MARK: - Global UINavigationController Swipe Back Extension

extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}
