//
//  ContentView.swift
//  Nova
//
//  Created by sakyol on 19.07.2026.
//

import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// MARK: - Firebase Preloader / Warm Caching service

class FirebasePreloader: ObservableObject {
    static let shared = FirebasePreloader()
    
    @Published var isFinishedLoading = false
    private var loadedListeners: Set<String> = []
    private var listeners: [ListenerRegistration] = []
    private var isPrefetching = false
    
    // Timer to auto-release splash screen after 5 seconds as a safety fallback
    private var fallbackTimer: Timer?
    
    func startPrefetching() {
        guard let user = Auth.auth().currentUser else {
            DispatchQueue.main.async {
                self.isFinishedLoading = true
            }
            return
        }
        
        guard !isPrefetching else { return }
        isPrefetching = true
        
        stopPrefetching()
        loadedListeners.removeAll()
        isFinishedLoading = false
        
        let db = Firestore.firestore()
        let userDoc = db.collection("users").document(user.uid)
        
        // Start 5-second fallback timer so the user is never stuck forever on poor connections
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isFinishedLoading = true
            }
        }
        
        // 1. Prefetch Bank Operations data (via shared View Model listeners)
        BankOperationsViewModel.shared.startListeningIfNeeded()
        
        // Listen to Bank ViewModel changes to check when it finishes loading
        NotificationCenter.default.addObserver(self, selector: #selector(checkBankLoading), name: NSNotification.Name("BankLoadingStateChanged"), object: nil)
        
        // 2. Warm cache for Notes subcollection
        let notesL = userDoc.collection("notes").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("notes")
        }
        
        // 3. Warm cache for Dictionary subcollections
        let listsL = userDoc.collection("customLists").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("customLists")
        }
        let stickyL = userDoc.collection("stickyNotes").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("stickyNotes")
        }
        let wordsL = userDoc.collection("words").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("words")
        }
        
        // 4. Warm cache for Home/Finances subcollections
        let instL = userDoc.collection("institutions").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("institutions")
        }
        let assetsL = userDoc.collection("assets").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("assets")
        }
        let stocksL = userDoc.collection("stocks").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("stocks")
        }
        let limitsL = userDoc.collection("limitCount").addSnapshotListener { [weak self] _, _ in
            self?.markLoaded("limitCount")
        }
        
        listeners = [notesL, listsL, stickyL, wordsL, instL, assetsL, stocksL, limitsL]
    }
    
    @objc private func checkBankLoading() {
        if !BankOperationsViewModel.shared.isLoading {
            markLoaded("banks")
        }
    }
    
    private func markLoaded(_ name: String) {
        DispatchQueue.main.async {
            self.loadedListeners.insert(name)
            // Expecting initial loads for the 8 listeners
            let targetCount = 8
            let banksReady = !BankOperationsViewModel.shared.isLoading
            if (self.loadedListeners.count >= targetCount || (self.loadedListeners.count >= 7 && banksReady)) {
                self.fallbackTimer?.invalidate()
                self.isFinishedLoading = true
            }
        }
    }
    
    func stopPrefetching() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        for listener in listeners {
            listener.remove()
        }
        listeners.removeAll()
        NotificationCenter.default.removeObserver(self)
        isPrefetching = false
        isFinishedLoading = false
    }
}

// MARK: - Splash Screen (Twitter/X style)

struct SplashScreenView: View {
    @Binding var isFinished: Bool
    @ObservedObject var preloader = FirebasePreloader.shared

    @State private var logoScale: CGFloat = 1.0
    @State private var logoOpacity: Double = 1.0
    @State private var bgOpacity: Double = 1.0
    
    @State private var hasTriggeredZoom = false

    var body: some View {
        ZStack {
            // Premium light gradient background
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(red: 0.97, green: 0.97, blue: 1.00), location: 0.0),
                    .init(color: Color(red: 0.93, green: 0.94, blue: 0.99), location: 0.5),
                    .init(color: Color(red: 0.88, green: 0.90, blue: 0.98), location: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(bgOpacity)
            .ignoresSafeArea()

            // Decorative depth circles
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.6, green: 0.5, blue: 0.95).opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 160
                    )
                )
                .frame(width: 320, height: 320)
                .offset(x: -80, y: -120)
                .opacity(bgOpacity)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.14), .clear],
                        center: .center, startRadius: 0, endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .offset(x: 100, y: 140)
            // Logo — larger for better presence (%50 larger than 120pt is 180pt)
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
        }
        .onAppear {
            if let user = Auth.auth().currentUser {
                AppGroupStorage.saveUID(user.uid)
                preloader.startPrefetching()
            }
            checkLoadingState()
        }
        .onChange(of: preloader.isFinishedLoading) { finished in
            if finished {
                triggerZoomOut()
            }
        }
    }

    private func checkLoadingState() {
        // If not logged in, zoom out immediately after 0.85s delay
        if Auth.auth().currentUser == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                triggerZoomOut()
            }
        } else if preloader.isFinishedLoading {
            triggerZoomOut()
        }
    }

    private func triggerZoomOut() {
        guard !hasTriggeredZoom else { return }
        hasTriggeredZoom = true
        
        withAnimation(.easeIn(duration: 0.38)) {
            logoScale = 22.0
            logoOpacity = 0.0
        }
        withAnimation(.easeIn(duration: 0.38).delay(0.20)) {
            bgOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            isFinished = true
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var authViewModel = AuthenticationViewModel()
    @State private var splashFinished: Bool = false
    // Track previous auth state to detect login transition
    @State private var prevAuthenticated: Bool? = nil

    var body: some View {
        ZStack {
            Group {
                if authViewModel.isAuthenticated {
                    MainContainerView(authViewModel: authViewModel)
                } else {
                    LoginView(viewModel: authViewModel)
                }
            }

            if !splashFinished {
                SplashScreenView(isFinished: $splashFinished)
                    .zIndex(999)
            }
        }
        .onAppear {
            // Record initial auth state without triggering splash logic
            prevAuthenticated = authViewModel.isAuthenticated
            if splashFinished && authViewModel.isAuthenticated {
                FirebasePreloader.shared.startPrefetching()
            }
        }
        .onChange(of: splashFinished) { finished in
            if finished && authViewModel.isAuthenticated {
                FirebasePreloader.shared.startPrefetching()
            }
        }
        .onChange(of: authViewModel.isAuthenticated) { newVal in
            // Show splash when user transitions from logged-out → logged-in
            if newVal == true && prevAuthenticated == false {
                splashFinished = false
            }
            prevAuthenticated = newVal
            
            if newVal && splashFinished {
                FirebasePreloader.shared.startPrefetching()
            } else if !newVal {
                FirebasePreloader.shared.stopPrefetching()
            }
        }
    }
}

#Preview {
    ContentView()
}
