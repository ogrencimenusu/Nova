import SwiftUI
import GoogleSignIn

struct GoogleDrivePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var driveService = GoogleDriveService.shared
    
    let onSelectFile: (DriveFile) -> Void
    
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Google Drive'da Dekont Ara...", text: $searchText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onSubmit {
                            Task {
                                await driveService.fetchFiles(folderId: driveService.currentFolderId, searchQuery: searchText)
                            }
                        }
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            Task {
                                await driveService.fetchFiles(folderId: driveService.currentFolderId)
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.top, 8)
                
                // Category Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DriveCategory.allCases) { cat in
                            Button(action: {
                                driveService.folderStack = [("root", "Drive")]
                                driveService.currentFolderId = "root"
                                Task {
                                    await driveService.fetchFiles(folderId: "root", category: cat, searchQuery: searchText)
                                }
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: cat.iconName)
                                        .font(.caption)
                                    Text(cat.rawValue)
                                        .font(.subheadline.weight(.medium))
                                }
                                .padding(.vertical, 7)
                                .padding(.horizontal, 12)
                                .background(driveService.selectedCategory == cat ? Color.blue : Color(.systemGray6))
                                .foregroundColor(driveService.selectedCategory == cat ? .white : .primary)
                                .cornerRadius(18)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                
                Divider()
                
                // Folder Breadcrumb
                if driveService.folderStack.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button(action: {
                                Task {
                                    await driveService.navigateBack()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Geri")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.blue)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                            
                            ForEach(Array(driveService.folderStack.enumerated()), id: \.offset) { idx, folder in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Text(folder.name)
                                    .font(.subheadline)
                                    .foregroundColor(idx == driveService.folderStack.count - 1 ? .primary : .secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    Divider()
                }
                
                // Main Content
                if driveService.isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Google Drive Dosyaları Yükleniyor...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = driveService.errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        Button(action: {
                            Task {
                                if let user = GIDSignIn.sharedInstance.currentUser {
                                    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                          let rootVC = windowScene.windows.first?.rootViewController else { return }
                                    user.addScopes(["https://www.googleapis.com/auth/drive.file"], presenting: rootVC) { result, _ in
                                        if let updated = result?.user {
                                            AppGroupStorage.saveDriveToken(updated.accessToken.tokenString)
                                        }
                                        Task {
                                            await driveService.fetchFiles(folderId: driveService.currentFolderId)
                                        }
                                    }
                                } else {
                                    _ = try? await driveService.signInAndGrantScope()
                                    await driveService.fetchFiles(folderId: driveService.currentFolderId)
                                }
                            }
                        }) {
                            Text("Google Drive Yetkisi Ver / Yenile")
                                .fontWeight(.medium)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    Spacer()
                } else if driveService.files.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("Hiç dosya bulunamadı")
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(driveService.files) { file in
                            Button(action: {
                                if file.isFolder {
                                    Task {
                                        await driveService.navigateToFolder(id: file.id, name: file.name)
                                    }
                                } else {
                                    onSelectFile(file)
                                    dismiss()
                                }
                            }) {
                                HStack(spacing: 12) {
                                    fileIcon(for: file)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .lineLimit(2)
                                        
                                        if !file.formattedDate.isEmpty {
                                            Text(file.formattedDate)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if file.isFolder {
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    } else {
                                        HStack(spacing: 4) {
                                            Text("Seç")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.blue)
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.system(size: 14))
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await driveService.fetchFiles(folderId: driveService.currentFolderId)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                if driveService.files.isEmpty {
                    await driveService.fetchFiles(folderId: driveService.currentFolderId)
                }
            }
        }
    }
    
    @ViewBuilder
    private func fileIcon(for file: DriveFile) -> some View {
        if file.isFolder {
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .foregroundColor(.blue)
        } else if file.mimeType.contains("pdf") {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 24))
                .foregroundColor(.red)
        } else if file.mimeType.contains("image") {
            Image(systemName: "photo.fill")
                .font(.system(size: 24))
                .foregroundColor(.green)
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: 24))
                .foregroundColor(.gray)
        }
    }
}
