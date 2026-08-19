import Foundation
import Combine
import GoogleSignIn
import FirebaseCore
import UIKit

enum GoogleDriveError: LocalizedError {
    case notSignedIn
    case permissionDenied
    case noRootViewController
    case invalidURL
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Google hesabına giriş yapılmamış."
        case .permissionDenied:
            return "Google Drive erişim izni verilmedi."
        case .noRootViewController:
            return "Ekran görüntülenemedi."
        case .invalidURL:
            return "Geçersiz API adresi."
        case .apiError(let msg):
            return "Google Drive Hatası: \(msg)"
        }
    }
}

struct DriveFile: Identifiable, Codable {
    let id: String
    let name: String
    let mimeType: String
    let webViewLink: String?
    let iconLink: String?
    let thumbnailLink: String?
    let modifiedTime: String?
    let size: String?
    
    var shareUrl: String {
        if let link = webViewLink, !link.isEmpty {
            return link
        }
        return "https://drive.google.com/file/d/\(id)/view?usp=sharing"
    }
    
    var isFolder: Bool {
        return mimeType == "application/vnd.google-apps.folder"
    }
    
    var formattedDate: String {
        guard let modifiedTime = modifiedTime else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: modifiedTime) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "dd.MM.yyyy HH:mm"
            return displayFormatter.string(from: date)
        }
        let fallbackFormatter = ISO8601DateFormatter()
        if let date = fallbackFormatter.date(from: modifiedTime) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "dd.MM.yyyy HH:mm"
            return displayFormatter.string(from: date)
        }
        return ""
    }
}

struct DriveFileListResponse: Codable {
    let files: [DriveFile]
    let nextPageToken: String?
}

enum DriveCategory: String, CaseIterable, Identifiable {
    case myDrive = "Drive'ım"
    case sharedWithMe = "Paylaşılanlar"
    case recent = "En Son"
    case starred = "Yıldızlı"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .myDrive: return "folder"
        case .sharedWithMe: return "person.2"
        case .recent: return "clock"
        case .starred: return "star"
        }
    }
}

@MainActor
class GoogleDriveService: ObservableObject {
    static let shared = GoogleDriveService()
    
    @Published var files: [DriveFile] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var currentFolderId: String = "root"
    @Published var folderStack: [(id: String, name: String)] = [("root", "Drive")]
    @Published var selectedCategory: DriveCategory = .myDrive
    
    private let driveScopes = [
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/drive.readonly"
    ]
    
    var isSignedIn: Bool {
        return GIDSignIn.sharedInstance.currentUser != nil
    }
    
    var hasDrivePermission: Bool {
        guard let user = GIDSignIn.sharedInstance.currentUser,
              let scopes = user.grantedScopes else { return false }
        return scopes.contains("https://www.googleapis.com/auth/drive.file") || scopes.contains("https://www.googleapis.com/auth/drive")
    }
    
    private func ensureConfiguration() {
        if GIDSignIn.sharedInstance.configuration == nil {
            if let clientID = FirebaseApp.app()?.options.clientID {
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            } else {
                let fallbackClientID = "262012268980-6namo25ddkj62fm44at1s2tr7mneqal1.apps.googleusercontent.com"
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: fallbackClientID)
            }
        }
    }
    
    private func saveCachedToken(_ token: String) {
        AppGroupStorage.saveDriveToken(token)
    }

    private func getCachedToken() -> String? {
        return AppGroupStorage.getDriveToken().token
    }

    func signInAndGrantScope() async throws -> String {
        ensureConfiguration()
        
        if let user = GIDSignIn.sharedInstance.currentUser {
            return try await withCheckedThrowingContinuation { continuation in
                user.refreshTokensIfNeeded { updatedUser, error in
                    if let error = error {
                        if let cachedToken = self.getCachedToken() {
                            continuation.resume(returning: cachedToken)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        let token = updatedUser?.accessToken.tokenString ?? user.accessToken.tokenString
                        self.saveCachedToken(token)
                        continuation.resume(returning: token)
                    }
                }
            }
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                    if let user = user {
                        user.refreshTokensIfNeeded { updatedUser, _ in
                            let token = updatedUser?.accessToken.tokenString ?? user.accessToken.tokenString
                            self.saveCachedToken(token)
                            continuation.resume(returning: token)
                        }
                    } else {
                        if let cachedToken = self.getCachedToken() {
                            continuation.resume(returning: cachedToken)
                        } else {
                            continuation.resume(throwing: GoogleDriveError.notSignedIn)
                        }
                    }
                }
            }
        }
    }
    
    func fetchFiles(folderId: String = "root", category: DriveCategory? = nil, searchQuery: String? = nil) async {
        self.isLoading = true
        self.errorMessage = nil
        if let cat = category {
            self.selectedCategory = cat
        }
        let activeCategory = category ?? self.selectedCategory
        
        do {
            let token = try await signInAndGrantScope()
            
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
            
            var queryParts: [String] = ["trashed = false"]
            if let search = searchQuery, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let sanitized = search.replacingOccurrences(of: "'", with: "\\'")
                queryParts.append("name contains '\(sanitized)'")
            } else {
                switch activeCategory {
                case .myDrive:
                    queryParts.append("'\(folderId)' in parents")
                case .sharedWithMe:
                    queryParts.append("sharedWithMe = true")
                case .recent:
                    // Ordered by modifiedTime desc
                    break
                case .starred:
                    queryParts.append("starred = true")
                }
            }
            
            let queryStr = queryParts.joined(separator: " and ")
            
            components?.queryItems = [
                URLQueryItem(name: "q", value: queryStr),
                URLQueryItem(name: "fields", value: "files(id, name, mimeType, webViewLink, iconLink, thumbnailLink, modifiedTime, size)"),
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "orderBy", value: "folder,modifiedTime desc")
            ]
            
            guard let url = components?.url else {
                throw GoogleDriveError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GoogleDriveError.apiError("Geçersiz sunucu yanıtı.")
            }
            
            if httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                let result = try decoder.decode(DriveFileListResponse.self, from: data)
                self.files = result.files
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                throw GoogleDriveError.apiError("HTTP \(httpResponse.statusCode): \(errBody)")
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.files = []
        }
        
        self.isLoading = false
    }
    
    func navigateToFolder(id: String, name: String) async {
        currentFolderId = id
        folderStack.append((id: id, name: name))
        await fetchFiles(folderId: id)
    }
    
    func navigateBack() async {
        guard folderStack.count > 1 else { return }
        folderStack.removeLast()
        if let target = folderStack.last {
            currentFolderId = target.id
            await fetchFiles(folderId: target.id)
        }
    }
    
    func uploadFile(fileData: Data, fileName: String, mimeType: String) async throws -> DriveFile {
        let token = try await signInAndGrantScope()
        
        guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,webViewLink") else {
            throw GoogleDriveError.invalidURL
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Metadata Part
        let metadata: [String: Any] = [
            "name": fileName,
            "mimeType": mimeType
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [])
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Media Part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // End Boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveError.apiError("Geçersiz sunucu yanıtı.")
        }
        
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            let decoder = JSONDecoder()
            let uploadedFile = try decoder.decode(DriveFile.self, from: data)
            return uploadedFile
        } else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.apiError("HTTP \(httpResponse.statusCode): \(errBody)")
        }
    }
}
