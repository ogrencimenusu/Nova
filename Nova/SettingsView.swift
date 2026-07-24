import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authViewModel: AuthenticationViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
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
