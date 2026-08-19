import Foundation
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import Combine

@MainActor
class AuthenticationViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User? = nil
    
    init() {
        self.currentUser = Auth.auth().currentUser
        self.isAuthenticated = self.currentUser != nil
        if let uid = self.currentUser?.uid {
            UserDefaults(suiteName: "group.sakyol.nova")?.set(uid, forKey: "current_user_uid")
        }
        
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
            self?.isAuthenticated = user != nil
            if let uid = user?.uid {
                UserDefaults(suiteName: "group.sakyol.nova")?.set(uid, forKey: "current_user_uid")
            }
        }
    }
    
    func signInWithGoogle() {
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        let driveScopes = [
            "https://www.googleapis.com/auth/drive.file",
            "https://www.googleapis.com/auth/drive",
            "https://www.googleapis.com/auth/drive.readonly"
        ]
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: nil, additionalScopes: driveScopes) { [weak self] result, error in
            if let error = error {
                print("Error signing in with Google: \(error.localizedDescription)")
                return
            }
            
            guard let user = result?.user,
                  let idToken = user.idToken?.tokenString else {
                return
            }
            
            AppGroupStorage.saveDriveToken(user.accessToken.tokenString)
            
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: user.accessToken.tokenString)
            
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error = error {
                    print("Error authenticating with Firebase: \(error.localizedDescription)")
                    return
                }
                
                print("Successfully signed in to Firebase")
            }
        }
    }
    
    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch let signOutError as NSError {
            print("Error signing out: %@", signOutError)
        }
    }
}
