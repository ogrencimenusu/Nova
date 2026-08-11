//
//  NovaApp.swift
//  Nova
//
//  Created by sakyol on 19.07.2026.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import WidgetKit
import FirebaseFirestore
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {
    private var listeners: [ListenerRegistration] = []
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        
        // Enable Firestore Offline Cache / Disk Persistence to dramatically reduce reads
        let settings = Firestore.firestore().settings
        settings.isPersistenceEnabled = true
        settings.cacheSettings = PersistentCacheSettings(sizeBytes: NSNumber(value: 100 * 1024 * 1024))
        Firestore.firestore().settings = settings
        
        // Share Firebase Auth with Widget
        do {
            if let accessGroup = getKeychainGroup() {
                try Auth.auth().useUserAccessGroup(accessGroup)
                print("Successfully set user access group to: \(accessGroup)")
                
                Auth.auth().addStateDidChangeListener { auth, user in
                    if let user = user {
                        self.startListening(uid: user.uid)
                    } else {
                        self.stopListening()
                    }
                }
            }
        } catch let error as NSError {
            print("Error changing user access group: %@", error)
        }
        
        return true
    }
    
    func stopListening() {
        for listener in listeners {
            listener.remove()
        }
        listeners.removeAll()
    }
    
    func startListening(uid: String) {
        stopListening()
        let db = Firestore.firestore()
        
        // Listen to Notes
        let l1 = db.collection("users").document(uid).collection("notes")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in notes! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Daily Stats
        let l2 = db.collection("users").document(uid).collection("daily_stats")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in daily_stats! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Banks
        let l3 = db.collection("users").document(uid).collection("banks")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in banks! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        // Listen to Bank Transactions
        let l4 = db.collection("users").document(uid).collection("bankTransactions")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in bankTransactions! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }

        // Listen to Institutions
        let l5 = db.collection("users").document(uid).collection("institutions")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in institutions! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }

        // Listen to Stocks
        let l6 = db.collection("users").document(uid).collection("stocks")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in stocks! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }

        // Listen to Finance Transactions
        let l7 = db.collection("users").document(uid).collection("financeTransactions")
            .addSnapshotListener { snapshot, error in
                guard let _ = snapshot else { return }
                print("App detected changes in financeTransactions! Reloading widget...")
                WidgetCenter.shared.reloadAllTimelines()
            }
            
        listeners = [l1, l2, l3, l4, l5, l6, l7]
    }
    
    private func getKeychainGroup() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "probe",
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &item)
        
        if status == errSecSuccess,
           let itemDict = item as? [String: Any],
           let group = itemDict[kSecAttrAccessGroup as String] as? String {
            SecItemDelete(query as CFDictionary)
            return group
        } else if status == errSecDuplicateItem {
            SecItemCopyMatching(query as CFDictionary, &item)
            if let itemDict = item as? [String: Any],
               let group = itemDict[kSecAttrAccessGroup as String] as? String {
                return group
            }
        }
        return nil
    }
}

import WidgetKit

@main
struct NovaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                    
                    let full = url.absoluteString.lowercased()
                    let host = url.host?.lowercased() ?? ""
                    
                    var noteId: String? = nil
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                       let queryItems = components.queryItems {
                        noteId = queryItems.first(where: { $0.name == "id" })?.value
                    }

                    if full.contains("note") || host.contains("note") {
                        // Always store in UserDefaults for cold-launch safety
                        if let id = noteId, !id.isEmpty {
                            UserDefaults.standard.set(id, forKey: "pendingDeepLinkNoteId")
                        }
                        // Also post notification for when app is already running
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            NotificationCenter.default.post(name: Notification.Name("OpenNoteDetail"), object: noteId)
                        }
                    } else {
                        let targetOption: MenuOption?
                        if full.contains("bank") || host.contains("bank") {
                            targetOption = .bankOperations
                        } else if full.contains("finan") || full.contains("stock") || host.contains("finan") || host.contains("stock") {
                            targetOption = .financeOperations
                        } else if full.contains("dict") || full.contains("sozluk") || full.contains("streak") || host.contains("dict") || host.contains("sozluk") || host.contains("streak") {
                            targetOption = .dictionary
                        } else if full.contains("tag") || host.contains("tag") {
                            targetOption = .tags
                        } else if full.contains("setting") || host.contains("setting") {
                            targetOption = .settings
                        } else if full.contains("home") || host.contains("home") {
                            targetOption = .home
                        } else {
                            targetOption = nil
                        }
                        
                        if let option = targetOption {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: option)
                            }
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active || newPhase == .background {
                // Uygulama her açıldığında veya alta alındığında widget'ı zorla güncelle
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

// MARK: - Firestore Cache Extensions
extension Query {
    func getDocumentsSmart() async throws -> QuerySnapshot {
        do {
            let cacheSnap = try await self.getDocuments(source: .cache)
            if !cacheSnap.documents.isEmpty {
                return cacheSnap
            }
        } catch {
            // Fallback to server if cache miss or error
        }
        return try await self.getDocuments(source: .default)
    }
}

extension DocumentReference {
    func getDocumentSmart() async throws -> DocumentSnapshot {
        do {
            let cacheSnap = try await self.getDocument(source: .cache)
            if cacheSnap.exists {
                return cacheSnap
            }
        } catch {
            // Fallback to server if cache miss or error
        }
        return try await self.getDocument(source: .default)
    }
}

// MARK: - Pre-Calculated Account Summary Helper
struct AccountSummary {
    var totalBankBalance: Double
    var totalStockPortfolio: Double
    var totalStockTax: Double
    var bankBalances: [String: Double]
    var lastUpdated: Date?
}

class AccountSummaryHelper {
    static let shared = AccountSummaryHelper()
    
    func summaryDocRef(uid: String) -> DocumentReference {
        return Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("summaries")
            .document("overview")
    }
    
    func updateBankTransactionSummary(uid: String, bankId: String, amountDelta: Double) {
        guard !uid.isEmpty else { return }
        let ref = summaryDocRef(uid: uid)
        
        ref.setData([
            "totalBankBalance": FieldValue.increment(amountDelta),
            "bankBalances.\(bankId)": FieldValue.increment(amountDelta),
            "lastUpdated": FieldValue.serverTimestamp()
        ], merge: true)
    }
    
    func updateStockPortfolioSummary(uid: String, portfolioDelta: Double, taxDelta: Double) {
        guard !uid.isEmpty else { return }
        let ref = summaryDocRef(uid: uid)
        
        ref.setData([
            "totalStockPortfolio": FieldValue.increment(portfolioDelta),
            "totalStockTax": FieldValue.increment(taxDelta),
            "lastUpdated": FieldValue.serverTimestamp()
        ], merge: true)
    }
    
    func resyncAllBankSummaries(uid: String, banks: [BankItem], transactions: [BankTransactionItem]) {
        guard !uid.isEmpty else { return }
        var balancesMap: [String: Double] = [:]
        var grandTotal: Double = 0.0
        
        for b in banks {
            balancesMap[b.id] = 0.0
        }
        
        for t in transactions {
            guard !t.deleted && t.type != "Eyv0oZlOuCPWJbmRkv0h" && !t.bankId.isEmpty else { continue }
            balancesMap[t.bankId] = (balancesMap[t.bankId] ?? 0.0) + t.amount
        }
        
        let visibleIds = Set(banks.filter { $0.visible }.map { $0.id })
        for (bId, bal) in balancesMap {
            if visibleIds.contains(bId) {
                grandTotal += bal
            }
        }
        
        summaryDocRef(uid: uid).setData([
            "bankBalances": balancesMap,
            "totalBankBalance": grandTotal,
            "lastUpdated": FieldValue.serverTimestamp()
        ], merge: true)
    }
    
    func resyncAllFinanceSummaries(uid: String, institutions: [FinanceInstitutionItem], stocks: [FinanceStockItem], transactions: [FinanceTransactionItem]) {
        guard !uid.isEmpty else { return }
        var instBalancesMap: [String: Double] = [:]
        var totalPortfolio: Double = 0.0
        var totalTax: Double = 0.0
        
        for inst in institutions {
            instBalancesMap[inst.id] = 0.0
        }
        
        var stockMap: [String: Double] = [:]
        for s in stocks {
            stockMap[s.id] = s.currentPrice
        }
        
        let activeTrans = transactions.filter { !$0.deleted }
        
        var stockBuyLots: [String: [(price: Double, taxRate: Double, remaining: Double)]] = [:]
        
        let sortedTrans = activeTrans.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let isAlis0 = $0.type.uppercased().hasPrefix("AL")
            let isAlis1 = $1.type.uppercased().hasPrefix("AL")
            if isAlis0 != isAlis1 { return isAlis0 }
            return ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast)
        }
        
        for t in sortedTrans {
            let key = "\(t.stockId)_\(t.institutionId)"
            if t.type.hasPrefix("AL") {
                if stockBuyLots[key] == nil { stockBuyLots[key] = [] }
                stockBuyLots[key]?.append((price: t.price, taxRate: t.taxRate, remaining: t.quantity))
            } else if t.type.hasPrefix("SAT") {
                var remainingToSell = t.quantity
                if var lots = stockBuyLots[key] {
                    for i in 0..<lots.count {
                        if remainingToSell <= 0 { break }
                        if lots[i].remaining <= 0 { continue }
                        let toDeduct = min(lots[i].remaining, remainingToSell)
                        lots[i].remaining -= toDeduct
                        remainingToSell -= toDeduct
                    }
                    stockBuyLots[key] = lots
                }
            }
        }
        
        var stockSummariesMap: [String: [String: Any]] = [:]
        
        for (key, lots) in stockBuyLots {
            let parts = key.split(separator: "_")
            guard parts.count >= 2 else { continue }
            let stockId = String(parts[0])
            let instId = String(parts[1])
            let currentPrice = stockMap[stockId] ?? 0.0
            
            for lot in lots {
                if lot.remaining > 0 {
                    let prc = currentPrice > 0 ? currentPrice : lot.price
                    let lotVal = lot.remaining * prc
                    totalPortfolio += lotVal
                    instBalancesMap[instId] = (instBalancesMap[instId] ?? 0.0) + lotVal
                    
                    let profit = (currentPrice - lot.price) * lot.remaining
                    if profit > 0 && lot.taxRate > 0 {
                        totalTax += profit * (lot.taxRate / 100.0)
                    }
                    
                    var stockSum = stockSummariesMap[stockId] ?? [
                        "stockId": stockId,
                        "quantity": 0.0,
                        "totalCost": 0.0,
                        "firstPurchaseDate": "",
                        "institutionBreakdown": [String: Double]()
                    ]
                    
                    let currentQty = (stockSum["quantity"] as? Double) ?? 0.0
                    let currentCost = (stockSum["totalCost"] as? Double) ?? 0.0
                    var currentBreakdown = (stockSum["institutionBreakdown"] as? [String: Double]) ?? [:]
                    
                    stockSum["quantity"] = currentQty + lot.remaining
                    stockSum["totalCost"] = currentCost + (lot.remaining * lot.price)
                    currentBreakdown[instId] = (currentBreakdown[instId] ?? 0.0) + lot.remaining
                    stockSum["institutionBreakdown"] = currentBreakdown
                    
                    stockSummariesMap[stockId] = stockSum
                }
            }
        }
        
        summaryDocRef(uid: uid).setData([
            "institutionBalances": instBalancesMap,
            "stockSummaries": stockSummariesMap,
            "totalStockPortfolio": totalPortfolio,
            "totalStockTax": totalTax,
            "lastUpdated": FieldValue.serverTimestamp()
        ], merge: true)
    }
}


