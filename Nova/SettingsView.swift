import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authViewModel: AuthenticationViewModel
    @ObservedObject var themeManager = ThemeManager.shared
    @AppStorage("unsolved_words_threshold_days") private var unsolvedWordsThresholdDays: Int = 15
    @AppStorage("unsolved_words_max_count") private var unsolvedWordsMaxCount: Double = 15
    @Environment(\.presentationMode) var presentationMode
    
    private var currentThresholdMaxCountBinding: Binding<Double> {
        Binding<Double>(
            get: {
                let key = "unsolved_words_max_count_\(unsolvedWordsThresholdDays)"
                let val = UserDefaults.standard.double(forKey: key)
                if val > 0 { return val }
                return unsolvedWordsMaxCount > 0 ? unsolvedWordsMaxCount : 15.0
            },
            set: { newVal in
                let key = "unsolved_words_max_count_\(unsolvedWordsThresholdDays)"
                UserDefaults.standard.set(newVal, forKey: key)
                unsolvedWordsMaxCount = newVal
            }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Görünüm & Tema")) {
                    Picker(selection: $themeManager.currentTheme, label: HStack {
                        Image(systemName: themeManager.currentTheme.iconName)
                            .foregroundColor(.purple)
                        Text("Uygulama Teması")
                    }) {
                        ForEach(AppTheme.allCases) { theme in
                            HStack {
                                Image(systemName: theme.iconName)
                                Text(theme.title)
                            }
                            .tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(
                    header: Text("Sözlük & Tekrar Ayarları"),
                    footer: Text("Sözlük ana sayfasındaki slider'da seçili gün eşiğine (\(unsolvedWordsThresholdDays) gün) göre çözülmemiş veya hiç çözülmemiş kelimeler listelenir.")
                ) {
                    Picker(selection: $unsolvedWordsThresholdDays, label: HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.orange)
                        Text("Tekrar Hatırlatma Eşiği")
                    }) {
                        Text("7 Gün").tag(7)
                        Text("15 Gün (Önerilen)").tag(15)
                        Text("30 Gün").tag(30)
                        Text("60 Gün").tag(60)
                    }
                    .pickerStyle(.menu)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundColor(.blue)
                                Text("Kelime Limiti (\(unsolvedWordsThresholdDays) Gün İçin)")
                            }
                            Spacer()
                            Text("\(Int(currentThresholdMaxCountBinding.wrappedValue)) Kelime")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.blue)
                        }
                        
                        Slider(value: currentThresholdMaxCountBinding, in: 3...50, step: 1)
                            .tint(.blue)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Veri & Önbellek")) {
                    Button(action: {
                        BankOperationsViewModel.shared.clearCacheAndReload()
                    }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                            Text("Önbelleği Temizle & Verileri Yenile")
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                Section(header: Text("Hesap")) {
                    Button(action: {
                        authViewModel.signOut()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.red)
                            Text("Çıkış Yap")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
