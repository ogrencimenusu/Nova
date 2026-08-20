import SwiftUI
import FirebaseCore
import GoogleSignIn
import FirebaseAuth

enum MenuOption: Int, CaseIterable {
    case home = 0
    case bankOperations
    case financeOperations
    case notes
    case tags
    case dictionary
    case recentlyDeleted
    case settings
    
    var title: String {
        switch self {
        case .home: return "Anasayfa"
        case .bankOperations: return "Banka İşlemleri"
        case .financeOperations: return "Finans İşlemleri"
        case .notes: return "Notlar"
        case .tags: return "Etiketler"
        case .dictionary: return "Sözlük"
        case .recentlyDeleted: return "Son Silinenler"
        case .settings: return "Ayarlar"
        }
    }
    
    var iconName: String {
        switch self {
        case .home: return "house"
        case .bankOperations: return "briefcase"
        case .financeOperations: return "chart.pie"
        case .notes: return "note.text"
        case .tags: return "tag"
        case .dictionary: return "book"
        case .recentlyDeleted: return "trash"
        case .settings: return "gearshape"
        }
    }
}

struct SideMenuView: View {
    @Binding var selectedOption: MenuOption
    @Binding var isShowing: Bool
    @ObservedObject var authViewModel: AuthenticationViewModel
    
    // Theme options
    let themes = ["Açık", "Koyu", "Sistem"]
    @State private var selectedTheme = "Sistem"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header / Logo
            HStack {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 70, alignment: .leading)
                Spacer()
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
            .padding(.leading, 20)
            
            // Menu Items
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(MenuOption.allCases, id: \.self) { option in
                        Button(action: {
                            withAnimation(.spring()) {
                                selectedOption = option
                                isShowing = false
                            }
                        }) {
                            HStack(spacing: 16) {
                                if #available(iOS 17.0, *) {
                                    Image(systemName: option.iconName)
                                        .font(.system(size: 20))
                                        .symbolEffect(.bounce, value: selectedOption == option)
                                        .foregroundColor(selectedOption == option ? .blue : .gray)
                                        .frame(width: 24)
                                } else {
                                    Image(systemName: option.iconName)
                                        .font(.system(size: 20))
                                        .foregroundColor(selectedOption == option ? .blue : .gray)
                                        .frame(width: 24)
                                }
                                
                                Text(option.title)
                                    .font(.system(size: 16, weight: selectedOption == option ? .bold : .medium, design: .rounded))
                                    .foregroundColor(selectedOption == option ? .blue : .black.opacity(0.8))
                                
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedOption == option ? Color.blue.opacity(0.1) : Color.clear)
                            )
                            .padding(.horizontal, 10)
                        }
                    }
                }
                .padding(.top, 10)
            }
            
            Spacer()
            
            // Bottom Section
            VStack(spacing: 15) {
                Divider()
                
                // Profile Info
                HStack(spacing: 12) {
                    if let photoURL = authViewModel.currentUser?.photoURL {
                        AsyncImage(url: photoURL) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    } else {
                        // Avatar placeholder
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Text(String(authViewModel.currentUser?.displayName?.prefix(1) ?? "U"))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.gray)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(authViewModel.currentUser?.displayName ?? "Kullanıcı")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Text("v2.0.1")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                        
                        Text(authViewModel.currentUser?.email ?? "email@example.com")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
                
                // Theme Picker
                HStack(spacing: 0) {
                    ThemeButton(title: "Açık", icon: "sun.max", isSelected: selectedTheme == "Açık") {
                        selectedTheme = "Açık"
                    }
                    ThemeButton(title: "Koyu", icon: "moon", isSelected: selectedTheme == "Koyu") {
                        selectedTheme = "Koyu"
                    }
                    ThemeButton(title: "Sistem", icon: "desktopcomputer", isSelected: selectedTheme == "Sistem") {
                        selectedTheme = "Sistem"
                    }
                }
                .padding(4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                // Logout & Refresh
                HStack(spacing: 10) {
                    Button(action: {
                        authViewModel.signOut()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Çıkış Yap")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .foregroundColor(.red)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.5), lineWidth: 1)
                        )
                    }
                    
                    Button(action: {
                        // Refresh action placeholder
                    }) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                
                // Version
                HStack {
                    Spacer()
                    Text("v2.0.5")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white
                .ignoresSafeArea()
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 5, y: 0)
        )
    }
}

struct ThemeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            }
            .foregroundColor(isSelected ? .blue : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.clear)
            .cornerRadius(6)
            .shadow(color: isSelected ? Color.black.opacity(0.05) : Color.clear, radius: 2, x: 0, y: 1)
        }
    }
}
