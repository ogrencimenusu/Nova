import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import SafariServices
import UniformTypeIdentifiers

// MARK: - Models (Moved to BankModels.swift)

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - BankOperationsViewModel (Shared Data Store & Mutators)

class BankOperationsViewModel: ObservableObject {
    static let shared = BankOperationsViewModel()
    
    @Published var banks: [BankItem] = []
    @Published var transactions: [BankTransactionItem] = []
    @Published var quickActions: [TagItem] = []
    @Published var transactionTypes: [TagItem] = []
    @Published var isLoading: Bool = true
    
    // Firestore config
    @Published var selectedGroupBy: String = "none"
    @Published var groupSettings: [String: [String: Any]] = [:]
    @Published var bankGroupConfigs: [String: Any] = [:] // Persistent group configurations (date filters, etc.)
    @Published var configTrigger = UUID() // Equatable trigger for SwiftUI onChange
    
    private var listeners: [ListenerRegistration] = []
    private var hasStarted: Bool = false
    
    func startListeningIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        loadAllData()
    }
    
    func clearCacheAndReload() {
        removeListeners()
        hasStarted = false
        let db = Firestore.firestore()
        db.clearPersistence { _ in
            DispatchQueue.main.async {
                self.startListeningIfNeeded()
            }
        }
    }
    
    func loadAllData() {
        guard let user = Auth.auth().currentUser else { return }
        
        removeListeners()
        DispatchQueue.main.async {
            self.isLoading = true
        }
        let db = Firestore.firestore()
        let userDoc = db.collection("users").document(user.uid)
        
        // 1. Listen for config (bankSettings)
        let configListener = userDoc.collection("config").document("bankSettings").addSnapshotListener { snap, err in
            if let data = snap?.data() {
                DispatchQueue.main.async {
                    self.selectedGroupBy = data["groupBy"] as? String ?? "none"
                }
            }
        }
        
        // 2. Listen for groupSettings (bankGroups)
        let groupSettingsListener = userDoc.collection("groupSettings").document("bankGroups").addSnapshotListener { snap, err in
            if let data = snap?.data() {
                var settings: [String: [String: Any]] = [:]
                var cachedTypes: [CachedTransactionType] = []
                for (key, val) in data {
                    if let dict = val as? [String: Any] {
                        settings[key] = dict
                        if let name = dict["name"] as? String {
                            cachedTypes.append(CachedTransactionType(id: key, name: name))
                        }
                    }
                }
                // Cache transaction types to AppGroup disk so Share Extension can read without Firebase Auth
                if !cachedTypes.isEmpty {
                    AppGroupStorage.saveTransactionTypes(cachedTypes)
                }
                DispatchQueue.main.async {
                    self.groupSettings = settings
                }
            }
        }
        
        // 3. Listen for bankGroupConfigs
        let groupConfigsListener = userDoc.collection("config").document("bankGroupConfigs").addSnapshotListener { snap, err in
            if let data = snap?.data() {
                DispatchQueue.main.async {
                    self.bankGroupConfigs = data
                    self.configTrigger = UUID()
                }
            }
        }
        
        // 4. Listen for Banks
        let bankListener = userDoc.collection("banks").addSnapshotListener { snap, err in
            guard let docs = snap?.documents else { return }
            var list: [BankItem] = []
            for doc in docs {
                let data = doc.data()
                let deleted = data["deleted"] as? Bool ?? false
                if deleted { continue }
                
                let name = data["name"] as? String ?? ""
                let logo = data["logo"] as? String ?? ""
                let visible = (data["visible"] as? Bool ?? true) && (data["visible"] as? String != "false")
                
                var order = 999
                if let intVal = data["order"] as? Int { order = intVal }
                else if let dblVal = data["order"] as? Double { order = Int(dblVal) }
                else if let strVal = data["order"] as? String { order = Int(strVal) ?? 999 }
                
                list.append(BankItem(id: doc.documentID, name: name, logo: logo, visible: visible, order: order, deleted: deleted))
            }
            
            list.sort { $0.order < $1.order }
            DispatchQueue.main.async {
                self.banks = list
                self.recalculateBankBalances()
                self.isLoading = false
                NotificationCenter.default.post(name: NSNotification.Name("BankLoadingStateChanged"), object: nil)
                // Cache banks to AppGroup disk so Share Extension can read without Firebase Auth
                let cached = list.map { CachedBank(id: $0.id, name: $0.name, logo: $0.logo, order: $0.order) }
                AppGroupStorage.saveBanks(cached)
            }
        }
        
        // 5. Listen for Transactions
        let transListener = userDoc.collection("bankTransactions")
            .order(by: "date", descending: true)
            .addSnapshotListener { snap, err in
                guard let docs = snap?.documents else { return }
                var list: [BankTransactionItem] = []
                for doc in docs {
                    let data = doc.data()
                    let deleted = data["deleted"] as? Bool ?? false
                    if deleted { continue }
                    
                    let bankId = data["bankId"] as? String ?? ""
                    let title = data["title"] as? String ?? ""
                    let qas = data["quickActions"] as? [String] ?? []
                    let type = data["type"] as? String ?? ""
                    let amount = parseAmountDouble(data["amount"])
                    let date = data["date"] as? String ?? ""
                    let receiptUrl = data["receiptUrl"] as? String
                    let createdAtVal = parseFirestoreDate(data["createdAt"])
                    
                    list.append(BankTransactionItem(id: doc.documentID, bankId: bankId, title: title, quickActions: qas, type: type, amount: amount, date: date, createdAt: createdAtVal, deleted: deleted, receiptUrl: receiptUrl))
                }
                
                list.sort { a, b in
                    if a.date != b.date {
                        return a.date > b.date
                    }
                    let dateA = a.createdAt ?? Date.distantFuture
                    let dateB = b.createdAt ?? Date.distantFuture
                    if dateA != dateB {
                        return dateA > dateB
                    }
                    return a.id > b.id
                }
                
                DispatchQueue.main.async {
                    self.transactions = list
                    self.recalculateBankBalances()
                }
            }
            
        // 6. Listen for Quick Actions
        let qaListener = userDoc.collection("quickActions").order(by: "order").addSnapshotListener { snap, err in
            guard let docs = snap?.documents else { return }
            var list: [TagItem] = []
            for doc in docs {
                let data = doc.data()
                let name = data["name"] as? String ?? ""
                let color = data["color"] as? String ?? "Gray"
                let order = data["order"] as? Int ?? 0
                list.append(TagItem(id: doc.documentID, name: name, color: color, order: order))
            }
            DispatchQueue.main.async {
                self.quickActions = list
                let cached = list.map { CachedQuickAction(id: $0.id, name: $0.name, color: $0.color, order: $0.order) }
                AppGroupStorage.saveQuickActions(cached)
            }
        }
        
        // 7. Listen for Transaction Types
        let typeListener = userDoc.collection("transactionTypes").order(by: "order").addSnapshotListener { snap, err in
            guard let docs = snap?.documents else { return }
            var list: [TagItem] = []
            for doc in docs {
                let data = doc.data()
                let name = data["name"] as? String ?? ""
                let color = data["color"] as? String ?? "Gray"
                let order = data["order"] as? Int ?? 0
                list.append(TagItem(id: doc.documentID, name: name, color: color, order: order))
            }
            DispatchQueue.main.async {
                self.transactionTypes = list
                let cached = list.map { CachedTransactionType(id: $0.id, name: $0.name, order: $0.order) }
                AppGroupStorage.saveTransactionTypes(cached)
            }
        }
        
        self.listeners = [configListener, groupSettingsListener, groupConfigsListener, bankListener, transListener, qaListener, typeListener]
    }
    
    private func removeListeners() {
        for listener in listeners {
            listener.remove()
        }
        listeners.removeAll()
        hasStarted = false
    }
    
    func recalculateBankBalances() {
        for i in 0..<banks.count {
            let bankId = banks[i].id
            let activeTrans = transactions.filter {
                $0.bankId == bankId && !$0.deleted && $0.type != "Eyv0oZlOuCPWJbmRkv0h"
            }
            let bal = activeTrans.reduce(0.0) { $0 + $1.amount }
            banks[i].balance = bal
        }
        if let user = Auth.auth().currentUser {
            AccountSummaryHelper.shared.resyncAllBankSummaries(uid: user.uid, banks: self.banks, transactions: self.transactions)
        }
    }
    
    func updateGroupBy(to type: String) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("config").document("bankSettings").setData([
            "groupBy": type
        ], merge: true)
    }
    
    func toggleGroupVisibility(groupId: String) {
        guard let user = Auth.auth().currentUser, !selectedGroupBy.isEmpty else { return }
        let db = Firestore.firestore()
        
        var currentSettings = groupSettings[selectedGroupBy] ?? [:]
        var visibility = currentSettings["visibility"] as? [String: Bool] ?? [:]
        let currentVal = visibility[groupId] ?? true
        visibility[groupId] = !currentVal
        visibility[groupId] = visibility[groupId]
        currentSettings["visibility"] = visibility
        
        groupSettings[selectedGroupBy] = currentSettings
        
        db.collection("users").document(user.uid).collection("groupSettings").document("bankGroups").setData([
            selectedGroupBy: currentSettings
        ], merge: true)
    }
    
    func saveGroupOrder(order: [String]) {
        guard let user = Auth.auth().currentUser, !selectedGroupBy.isEmpty else { return }
        let db = Firestore.firestore()
        
        var currentSettings = groupSettings[selectedGroupBy] ?? [:]
        currentSettings["order"] = order
        groupSettings[selectedGroupBy] = currentSettings
        
        db.collection("users").document(user.uid).collection("groupSettings").document("bankGroups").setData([
            selectedGroupBy: currentSettings
        ], merge: true)
    }
    
    // Save group Date Filter (start, end) to config/bankGroupConfigs
    func saveGroupDateFilter(groupId: String, startDate: Date, endDate: Date, isEnabled: Bool) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        var filters: [[String: Any]] = []
        if isEnabled {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)
            
            filters.append([
                "propId": "date",
                "operator": "between",
                "value": "\(startStr),\(endStr)"
            ])
        }
        
        // Update local copy and fire trigger immediately to prevent delay
        self.bankGroupConfigs[groupId] = ["filters": filters]
        self.configTrigger = UUID()
        
        db.collection("users").document(user.uid).collection("config").document("bankGroupConfigs").setData([
            groupId: [
                "filters": filters
            ]
        ], merge: true)
    }
    
    func saveBank(name: String, logo: String, visible: Bool, order: Int) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("banks").addDocument(data: [
            "name": name,
            "logo": logo,
            "visible": visible,
            "order": order,
            "deleted": false
        ])
    }
    
    func updateBank(id: String, name: String, logo: String, visible: Bool, order: Int) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("banks").document(id).updateData([
            "name": name,
            "logo": logo,
            "visible": visible,
            "order": order
        ])
    }
    
    // Amount is saved as a String with commas, matching the web project style
    func saveTransaction(bankId: String, title: String, quickActions: [String], type: String, amount: String, date: String, receiptUrl: String) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("bankTransactions").addDocument(data: [
            "bankId": bankId,
            "title": title,
            "quickActions": quickActions,
            "type": type,
            "amount": amount,
            "date": date,
            "receiptUrl": receiptUrl,
            "createdAt": FieldValue.serverTimestamp(),
            "deleted": false
        ])
        
        let numAmount = parseAmount(amount)
        if numAmount != 0 {
            AccountSummaryHelper.shared.updateBankTransactionSummary(uid: user.uid, bankId: bankId, amountDelta: numAmount)
        }
    }
    
    func updateTransaction(id: String, bankId: String, title: String, quickActions: [String], type: String, amount: String, date: String, receiptUrl: String) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        let oldTrans = transactions.first(where: { $0.id == id })
        let oldAmount = oldTrans != nil ? parseAmount(oldTrans!.amount) : 0.0
        let oldBankId = oldTrans?.bankId ?? bankId
        let newAmount = parseAmount(amount)
        
        db.collection("users").document(user.uid).collection("bankTransactions").document(id).updateData([
            "bankId": bankId,
            "title": title,
            "quickActions": quickActions,
            "type": type,
            "amount": amount,
            "date": date,
            "receiptUrl": receiptUrl
        ])
        
        if oldBankId == bankId {
            let delta = newAmount - oldAmount
            if delta != 0 {
                AccountSummaryHelper.shared.updateBankTransactionSummary(uid: user.uid, bankId: bankId, amountDelta: delta)
            }
        } else {
            if oldAmount != 0 {
                AccountSummaryHelper.shared.updateBankTransactionSummary(uid: user.uid, bankId: oldBankId, amountDelta: -1.0 * oldAmount)
            }
            if newAmount != 0 {
                AccountSummaryHelper.shared.updateBankTransactionSummary(uid: user.uid, bankId: bankId, amountDelta: newAmount)
            }
        }
    }
    
    func deleteTransaction(id: String) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        let oldTrans = transactions.first(where: { $0.id == id })
        let oldAmount = oldTrans != nil ? parseAmount(oldTrans!.amount) : 0.0
        let oldBankId = oldTrans?.bankId ?? ""
        
        db.collection("users").document(user.uid).collection("bankTransactions").document(id).updateData([
            "deleted": true
        ])
        
        if !oldBankId.isEmpty && oldAmount != 0 {
            AccountSummaryHelper.shared.updateBankTransactionSummary(uid: user.uid, bankId: oldBankId, amountDelta: -1.0 * oldAmount)
        }
    }
    
    func addQuickTransactionInGroup(groupId: String, lastTransaction: BankTransactionItem? = nil, completion: ((BankTransactionItem) -> Void)? = nil) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let todayStr = today.string(from: Date())
        
        var bankId = ""
        var typeId = ""
        var quickActions: [String] = []
        
        if selectedGroupBy == "bankId" {
            bankId = groupId
            typeId = lastTransaction?.type ?? (transactionTypes.first?.id ?? "")
            quickActions = lastTransaction?.quickActions ?? []
        } else if selectedGroupBy == "type" {
            typeId = groupId
            bankId = lastTransaction?.bankId ?? (banks.first?.id ?? "")
            quickActions = lastTransaction?.quickActions ?? []
        } else if selectedGroupBy == "quickActions" {
            quickActions = [groupId]
            bankId = lastTransaction?.bankId ?? (banks.first?.id ?? "")
            typeId = lastTransaction?.type ?? (transactionTypes.first?.id ?? "")
        } else {
            bankId = lastTransaction?.bankId ?? (banks.first?.id ?? "")
            typeId = lastTransaction?.type ?? (transactionTypes.first?.id ?? "")
            quickActions = lastTransaction?.quickActions ?? []
        }
        
        var ref: DocumentReference? = nil
        ref = db.collection("users").document(user.uid).collection("bankTransactions").addDocument(data: [
            "bankId": bankId,
            "title": "",
            "quickActions": quickActions,
            "type": typeId,
            "amount": "",
            "date": todayStr,
            "receiptUrl": "",
            "createdAt": FieldValue.serverTimestamp(),
            "deleted": false
        ]) { error in
            if let error = error {
                print("Error adding transaction: \(error)")
            } else if let docId = ref?.documentID {
                let newItem = BankTransactionItem(
                    id: docId,
                    bankId: bankId,
                    title: "",
                    quickActions: quickActions,
                    type: typeId,
                    amount: 0.0,
                    date: todayStr,
                    createdAt: Date(),
                    deleted: false,
                    receiptUrl: nil
                )
                DispatchQueue.main.async {
                    completion?(newItem)
                }
            }
        }
    }
}

// MARK: - BankOperationsView

struct BankOperationsView: View {
    @ObservedObject private var viewModel = BankOperationsViewModel.shared
    
    // UI Filters & Search
    @State private var searchText: String = ""
    @State private var isDateFilterEnabled: Bool = false
    @State private var filterStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var filterEndDate: Date = Date()
    
    @State private var filterTitleText: String = ""
    @State private var filterTitleOp: String = "contains" // "contains" or "notContains"
    
    @State private var selectedQuickActionIds: Set<String> = []
    @State private var selectedTypeIds: Set<String> = []
    @State private var selectedBankIds: Set<String> = []
    
    @State private var showFilterSheet: Bool = false
    
    private var isAnyFilterActive: Bool {
        isDateFilterEnabled ||
        !filterTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !selectedQuickActionIds.isEmpty ||
        !selectedTypeIds.isEmpty ||
        !selectedBankIds.isEmpty
    }
    
    private func resetFilters() {
        isDateFilterEnabled = false
        filterStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        filterEndDate = Date()
        filterTitleText = ""
        filterTitleOp = "contains"
        selectedQuickActionIds = []
        selectedTypeIds = []
        selectedBankIds = []
    }
    
    // Pagination (Limit Count)
    @State private var limitCount: Int = 5
    
    // In-app Safari sheet URL state (fallback if native app can't open)
    @State private var activeSafariURL: IdentifiableURL? = nil
    
    // Sheets & Modals
    @State private var showGroupSettingsSheet: Bool = false
    @State private var showBankVisibilitySheet: Bool = false
    @State private var editingTransaction: BankTransactionItem? = nil
    @State private var isAddTransactionPresented: Bool = false
    
    // Right-to-left Swipe Alert Confirmation
    @State private var transactionToDelete: BankTransactionItem? = nil
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background Gradient
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 0.97, green: 0.97, blue: 1.00), location: 0.0),
                        .init(color: Color(red: 0.94, green: 0.95, blue: 0.99), location: 0.5),
                        .init(color: Color(red: 0.90, green: 0.91, blue: 0.98), location: 1.0)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if viewModel.isLoading {
                    ProgressView("Veriler Yükleniyor...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            
                            // Standard Page Title Header with Glass Plus Button
                            HStack(alignment: .center) {
                                Text("Banka")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Button(action: { isAddTransactionPresented = true }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.primary)
                                        .frame(width: 36, height: 36)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                                        )
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            
                            // MARK: - Bank Cards horizontal slider
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(viewModel.banks.filter { $0.visible }) { bank in
                                        BankListCardView(bank: bank)
                                    }
                                    
                                    // Bank Visibility Settings Button
                                    Button(action: { showBankVisibilitySheet = true }) {
                                        VStack(alignment: .center, spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                                    .frame(width: 38, height: 38)
                                                    .background(Circle().fill(Color.gray.opacity(0.05)))
                                                Image(systemName: "eye")
                                                    .foregroundColor(.gray)
                                                    .font(.system(size: 16, weight: .bold))
                                            }
                                            Text("Banka Görünüm")
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundColor(.gray)
                                            Text("Gizle / Göster")
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                                .foregroundColor(.gray.opacity(0.8))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .frame(width: 100, height: 85)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.top, 8)
                            
                            // MARK: - Bank Transactions List Title & Section Filter Button
                            HStack {
                                Text("Banka İşlemleri")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.black.opacity(0.8))
                                Spacer()
                                
                                Button(action: { showFilterSheet = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isAnyFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                        Text("Filtrele")
                                            .font(.system(size: 12, weight: .bold))
                                        if isAnyFilterActive {
                                            let activeCount = (isDateFilterEnabled ? 1 : 0) +
                                                (filterTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1) +
                                                selectedQuickActionIds.count +
                                                selectedTypeIds.count +
                                                selectedBankIds.count
                                            Text("\(activeCount)")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.white)
                                                .foregroundColor(.blue)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(isAnyFilterActive ? .white : .blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isAnyFilterActive ? Color.blue : Color.white)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            
                            // MARK: - Plain List View
                            LazyVStack(spacing: 10) {
                                let allFiltered = filterTransactions(viewModel.transactions)
                                let limitVal = (limitCount == -1) ? allFiltered.count : limitCount
                                let visibleTransactions = Array(allFiltered.prefix(limitVal))
                                
                                if allFiltered.isEmpty {
                                    Text("İşlem bulunamadı.")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 14))
                                        .padding(.vertical, 20)
                                } else {
                                    ForEach(visibleTransactions) { trans in
                                        let b = viewModel.banks.first(where: { $0.id == trans.bankId })
                                        let tag = viewModel.transactionTypes.first(where: { $0.id == trans.type })
                                        let qas = viewModel.quickActions.filter { trans.quickActions.contains($0.id) }
                                        
                                        TransactionRowView(
                                            transaction: trans,
                                            bank: b,
                                            typeTag: tag,
                                            quickActionTags: qas,
                                            onTap: { editingTransaction = trans },
                                            onDelete: { transactionToDelete = trans },
                                            onShowReceipt: { url in
                                                openReceiptURL(url)
                                            }
                                        )
                                    }
                                    
                                    // MARK: - Web-Style View Limit Selector
                                    VStack(alignment: .leading, spacing: 8) {
                                        Divider().padding(.vertical, 8)
                                        HStack(spacing: 6) {
                                            Text("GÖRÜNÜM LİMİTİ:")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.gray)
                                            
                                            ForEach([5, 10, 20, 50, 100], id: \.self) { val in
                                                Button(action: {
                                                    withAnimation { limitCount = val }
                                                }) {
                                                    Text("\(val)")
                                                        .font(.system(size: 11, weight: limitCount == val ? .bold : .medium))
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(limitCount == val ? Color.blue.opacity(0.12) : Color.clear)
                                                        .foregroundColor(limitCount == val ? .blue : .gray)
                                                        .cornerRadius(4)
                                                }
                                            }
                                            
                                            Button(action: {
                                                withAnimation { limitCount = -1 }
                                            }) {
                                                Text("Hepsini Gör (\(allFiltered.count))")
                                                    .font(.system(size: 11, weight: limitCount == -1 ? .bold : .medium))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(limitCount == -1 ? Color.blue.opacity(0.12) : Color.clear)
                                                    .foregroundColor(limitCount == -1 ? .blue : .gray)
                                                    .cornerRadius(4)
                                                }
                                            }
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                                .padding(.horizontal, 16)
                            
                            // MARK: - Bank Group Transactions Section
                            VStack(alignment: .leading, spacing: 12) {
                                Divider().padding(.vertical, 8)
                                
                                HStack {
                                    Text("Banka Grup İşlemleri")
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundColor(.black.opacity(0.8))
                                    
                                    Spacer()
                                    
                                    // Grouping Selector Menu Button
                                    Menu {
                                        Button(action: { viewModel.updateGroupBy(to: "none") }) {
                                            HStack {
                                                Text("Gruplama Yok")
                                                if viewModel.selectedGroupBy == "none" { Image(systemName: "checkmark") }
                                            }
                                        }
                                        Button(action: { viewModel.updateGroupBy(to: "bankId") }) {
                                            HStack {
                                                Text("Bankaya Göre")
                                                if viewModel.selectedGroupBy == "bankId" { Image(systemName: "checkmark") }
                                            }
                                        }
                                        Button(action: { viewModel.updateGroupBy(to: "type") }) {
                                            HStack {
                                                Text("İşlem Türüne Göre")
                                                if viewModel.selectedGroupBy == "type" { Image(systemName: "checkmark") }
                                            }
                                        }
                                        Button(action: { viewModel.updateGroupBy(to: "quickActions") }) {
                                            HStack {
                                                Text("Hızlı İşlemlere Göre")
                                                if viewModel.selectedGroupBy == "quickActions" { Image(systemName: "checkmark") }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "circle.grid.hex")
                                            .font(.system(size: 16))
                                            .foregroundColor(.gray)
                                            .padding(6)
                                            .background(Circle().fill(Color.white))
                                            .overlay(Circle().stroke(Color.black.opacity(0.04), lineWidth: 1))
                                    }
                                    
                                    if viewModel.selectedGroupBy != "none" {
                                        Button(action: { showGroupSettingsSheet = true }) {
                                            Image(systemName: "gearshape")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gray)
                                                .padding(6)
                                                .background(Circle().fill(Color.white))
                                                .overlay(Circle().stroke(Color.black.opacity(0.04), lineWidth: 1))
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                
                                if viewModel.selectedGroupBy != "none" {
                                    LazyVStack(spacing: 12) {
                                        let rawGroups = getGroupedTransactions()
                                        let visibleMap = viewModel.groupSettings[viewModel.selectedGroupBy]?["visibility"] as? [String: Bool] ?? [:]
                                        let visibleGroups = rawGroups.filter { visibleMap[$0.id] ?? true }
                                        
                                        if visibleGroups.isEmpty {
                                            Text("Gruplanacak işlem bulunamadı.")
                                                .foregroundColor(.gray)
                                                .font(.system(size: 14))
                                                .padding(.vertical, 20)
                                        } else {
                                            ForEach(visibleGroups) { group in
                                                GroupSectionView(
                                                    group: group,
                                                    banks: viewModel.banks,
                                                    transactionTypes: viewModel.transactionTypes,
                                                    quickActions: viewModel.quickActions,
                                                    onEditTransaction: { trans in editingTransaction = trans },
                                                    onDeleteTransaction: { trans in transactionToDelete = trans },
                                                    onShowReceipt: { url in
                                                        openReceiptURL(url)
                                                    }
                                                )
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                } else {
                                    Text("İşlemleri gruplamak için yukarıdaki simgeye dokunarak bir kriter seçin.")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.gray)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                }
                            }
                            
                            Spacer().frame(height: 30)
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.startListeningIfNeeded()
            }
            // Bank Visibility Sheet
            .sheet(isPresented: $showBankVisibilitySheet) {
                BankVisibilitySettingsSheetView(banks: viewModel.banks)
            }
            // Add Transaction Sheet
            .sheet(isPresented: $isAddTransactionPresented) {
                let uniqueTitles = Array(Set(viewModel.transactions.map { $0.title }.filter { !$0.isEmpty })).sorted()
                AddEditTransactionSheetView(
                    transactionToEdit: nil,
                    banks: viewModel.banks,
                    types: viewModel.transactionTypes,
                    quickActions: viewModel.quickActions,
                    uniqueTitles: uniqueTitles,
                    onSave: { bankId, title, selectedQAs, typeId, amount, dateStr, recUrl in
                        viewModel.saveTransaction(bankId: bankId, title: title, quickActions: selectedQAs, type: typeId, amount: amount, date: dateStr, receiptUrl: recUrl)
                    },
                    onTestLink: { url in
                        openReceiptURL(url)
                    }
                )
            }
            // Edit Transaction Sheet
            .sheet(item: $editingTransaction) { trans in
                let uniqueTitles = Array(Set(viewModel.transactions.map { $0.title }.filter { !$0.isEmpty })).sorted()
                AddEditTransactionSheetView(
                    transactionToEdit: trans,
                    banks: viewModel.banks,
                    types: viewModel.transactionTypes,
                    quickActions: viewModel.quickActions,
                    uniqueTitles: uniqueTitles,
                    onSave: { bankId, title, selectedQAs, typeId, amount, dateStr, recUrl in
                        viewModel.updateTransaction(id: trans.id, bankId: bankId, title: title, quickActions: selectedQAs, type: typeId, amount: amount, date: dateStr, receiptUrl: recUrl)
                    },
                    onTestLink: { url in
                        openReceiptURL(url)
                    }
                )
            }
            // Group Settings Sheet
            .sheet(isPresented: $showGroupSettingsSheet) {
                GroupSettingsSheetView(
                    allGroups: getGroupedTransactions(),
                    selectedGroupBy: viewModel.selectedGroupBy,
                    visibility: viewModel.groupSettings[viewModel.selectedGroupBy]?["visibility"] as? [String: Bool] ?? [:],
                    onToggle: { groupId in
                        viewModel.toggleGroupVisibility(groupId: groupId)
                    },
                    onReorder: { newOrder in
                        viewModel.saveGroupOrder(order: newOrder)
                    }
                )
            }
            // Advanced Filter Sheet
            .sheet(isPresented: $showFilterSheet) {
                let uniqueTitles = Array(Set(viewModel.transactions.map { $0.title }.filter { !$0.isEmpty })).sorted()
                BankFilterSheetView(
                    isDateFilterEnabled: $isDateFilterEnabled,
                    filterStartDate: $filterStartDate,
                    filterEndDate: $filterEndDate,
                    filterTitleText: $filterTitleText,
                    filterTitleOp: $filterTitleOp,
                    selectedQuickActionIds: $selectedQuickActionIds,
                    selectedTypeIds: $selectedTypeIds,
                    selectedBankIds: $selectedBankIds,
                    banks: viewModel.banks,
                    types: viewModel.transactionTypes,
                    quickActions: viewModel.quickActions,
                    uniqueTitles: uniqueTitles,
                    matchingCount: filterTransactions(viewModel.transactions).count,
                    onReset: resetFilters
                )
            }
            // In-app Safari sheet to display Google Drive PDFs/receipts safely inside the app as a fallback
            .sheet(item: $activeSafariURL) { wrapper in
                SafariView(url: wrapper.url)
                    .edgesIgnoringSafeArea(.all)
            }
            // Right-to-left swipe delete dialog alert
            .alert(item: $transactionToDelete) { trans in
                Alert(
                    title: Text("İşlemi Sil"),
                    message: Text("Bu işlemi silmek istediğinize emin misiniz?"),
                    primaryButton: .destructive(Text("Sil")) {
                        viewModel.deleteTransaction(id: trans.id)
                    },
                    secondaryButton: .cancel(Text("Vazgeç"))
                )
            }
        }
    }
    
    // Open receipt in Google Drive app natively, fallback to SafariViewController
    private func openReceiptURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                DispatchQueue.main.async {
                    self.activeSafariURL = IdentifiableURL(url: url)
                }
            }
        }
    }
    
    // MARK: - Search & Date Range Filters
    
    private func filterTransactions(_ source: [BankTransactionItem]) -> [BankTransactionItem] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let startStr = isDateFilterEnabled ? formatter.string(from: filterStartDate) : ""
        let endStr = isDateFilterEnabled ? formatter.string(from: filterEndDate) : ""
        let trimmedTitleFilter = filterTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let filtered = source.filter { t in
            // Search text from top bar search input
            if !searchText.isEmpty {
                let match = t.title.localizedCaseInsensitiveContains(searchText)
                if !match { return false }
            }
            
            // 1. Date Range Filter (Fast string comparison)
            if isDateFilterEnabled {
                if t.date < startStr || t.date > endStr {
                    return false
                }
            }
            
            // 2. Title Filter (contains / notContains)
            if !trimmedTitleFilter.isEmpty {
                let match = t.title.localizedCaseInsensitiveContains(trimmedTitleFilter)
                if filterTitleOp == "contains" {
                    if !match { return false }
                } else if filterTitleOp == "notContains" {
                    if match { return false }
                }
            }
            
            // 3. Quick Actions Filter
            if !selectedQuickActionIds.isEmpty {
                let hasAnyQA = t.quickActions.contains { selectedQuickActionIds.contains($0) }
                if !hasAnyQA { return false }
            }
            
            // 4. Transaction Type Filter
            if !selectedTypeIds.isEmpty {
                if !selectedTypeIds.contains(t.type) { return false }
            }
            
            // 5. Bank Filter
            if !selectedBankIds.isEmpty {
                if !selectedBankIds.contains(t.bankId) { return false }
            }
            
            return true
        }
        
        return filtered.sorted { a, b in
            if a.date != b.date {
                return a.date > b.date
            }
            let dateA = a.createdAt ?? Date.distantFuture
            let dateB = b.createdAt ?? Date.distantFuture
            if dateA != dateB {
                return dateA > dateB
            }
            return a.id > b.id
        }
    }
    
    private func getGroupedTransactions() -> [TransactionGroup] {
        let filtered = filterTransactions(viewModel.transactions)
        var dict: [String: [BankTransactionItem]] = [:]
        
        for t in filtered {
            var key = "Empty"
            if viewModel.selectedGroupBy == "bankId" {
                key = t.bankId.isEmpty ? "Empty" : t.bankId
            } else if viewModel.selectedGroupBy == "type" {
                key = t.type.isEmpty ? "Empty" : t.type
            } else if viewModel.selectedGroupBy == "quickActions" {
                key = t.quickActions.first ?? "Empty"
            }
            dict[key, default: []].append(t)
        }
        
        var groups: [TransactionGroup] = []
        for (key, items) in dict {
            var label = "Değer Yok"
            var colorHex = "808080"
            
            if viewModel.selectedGroupBy == "bankId" {
                if let b = viewModel.banks.first(where: { $0.id == key }) {
                    label = b.name
                } else if key == "Empty" {
                    label = "Bankasız"
                }
            } else if viewModel.selectedGroupBy == "type" {
                if let typeTag = viewModel.transactionTypes.first(where: { $0.id == key }) {
                    label = typeTag.name
                    colorHex = tagColorToHex(typeTag.color)
                } else if key == "Empty" {
                    label = "Tür Belirtilmemiş"
                }
            } else if viewModel.selectedGroupBy == "quickActions" {
                if let qaTag = viewModel.quickActions.first(where: { $0.id == key }) {
                    label = qaTag.name
                    colorHex = tagColorToHex(qaTag.color)
                } else if key == "Empty" {
                    label = "Hızlı İşlem Yok"
                }
            }
            
            let sortedGroupItems = items.sorted { a, b in
                if a.date != b.date {
                    return a.date > b.date
                }
                let dateA = a.createdAt ?? Date.distantFuture
                let dateB = b.createdAt ?? Date.distantFuture
                if dateA != dateB {
                    return dateA > dateB
                }
                return a.id > b.id
            }
            groups.append(TransactionGroup(id: key, label: label, color: colorHex, items: sortedGroupItems))
        }
        
        let customOrder = viewModel.groupSettings[viewModel.selectedGroupBy]?["order"] as? [String] ?? []
        groups.sort { a, b in
            let idxA = customOrder.firstIndex(of: a.id) ?? 999
            let idxB = customOrder.firstIndex(of: b.id) ?? 999
            if idxA != idxB {
                return idxA < idxB
            }
            return a.label.localizedCompare(b.label) == .orderedAscending
        }
        
        return groups
    }
}

// MARK: - Supporting Row / Card Views (Static design, tap action removed)

struct BankListCardView: View {
    let bank: BankItem
    
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white))
                
                if let logoName = getLocalLogoName(for: bank.name) {
                    Image(logoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 26)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "landmark.circle.fill")
                        .resizable()
                        .foregroundColor(.gray.opacity(0.5))
                        .frame(width: 26, height: 26)
                }
            }
            
            VStack(spacing: 3) {
                Text(bank.name)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Text(formatCurrencyDouble(bank.balance))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(bank.balance < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 100, height: 85)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
    }
}

// MARK: - Interactive Row Layout: Bank Logo opens PDF if available

struct TransactionRowView: View {
    let transaction: BankTransactionItem
    let bank: BankItem?
    let typeTag: TagItem?
    let quickActionTags: [TagItem]
    var onTap: () -> Void
    var onDelete: () -> Void
    var onShowReceipt: (URL) -> Void
    
    @State private var offset: CGFloat = 0
    @State private var isSwiped: Bool = false
    
    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete button background on swipe (underneath, right side)
            if offset < 0 {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation {
                            offset = 0
                            isSwiped = false
                        }
                        onDelete()
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.white)
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 70, height: 60)
                            .background(Color.red)
                            .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(width: 70)
                }
                .transition(.opacity)
            }
            
            // Front content row
            HStack(spacing: 12) {
                // Interactive Left Bank Logo Column
                Button(action: {
                    if let receiptStr = transaction.receiptUrl, !receiptStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: receiptStr) {
                        onShowReceipt(url)
                    } else {
                        onTap()
                    }
                }) {
                    ZStack(alignment: .bottomTrailing) {
                        // Centered ZStack for bank logo and circular background
                        ZStack(alignment: .center) {
                            Circle()
                                .fill(Color(hex: "f1f5f9"))
                                .frame(width: 38, height: 38)
                            if let bName = bank?.name, let logoName = getLocalLogoName(for: bName) {
                                Image(logoName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "landmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        // Overlay a small red PDF badge at the bottom-right of the circle logo container
                        if let receiptStr = transaction.receiptUrl, !receiptStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Image(systemName: "doc.text.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 9, height: 9)
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Circle().fill(Color.red))
                                .offset(x: 4, y: 4)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                VStack(alignment: .leading, spacing: 4) {
                    // If title is empty, show "Başlık girilmemiş" with 50% opacity
                    Text(transaction.title.isEmpty ? "Başlık girilmemiş" : transaction.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .opacity(transaction.title.isEmpty ? 0.5 : 1.0)
                        .lineLimit(1)
                    
                    if let tTag = typeTag {
                        Text(tTag.name)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: tagColorToHex(tTag.color)).opacity(0.15)))
                            .foregroundColor(Color(hex: tagColorToHex(tTag.color)))
                    }
                    
                    if !quickActionTags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(quickActionTags.prefix(2)) { qa in
                                Text(qa.name)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatCurrencyDouble(transaction.amount))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(transaction.amount < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                    
                    Text(formatShortDate(transaction.date))
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.03), lineWidth: 1)
            )
            .offset(x: offset)
            .gesture(
                DragGesture(minimumDistance: 25, coordinateSpace: .local)
                    .onChanged { value in
                        // Only track horizontal swipes to allow vertical ScrollView gestures
                        if abs(value.translation.width) > abs(value.translation.height) {
                            if value.translation.width < 0 {
                                offset = value.translation.width
                            }
                        }
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)) {
                            if value.translation.width < -60 && abs(value.translation.width) > abs(value.translation.height) {
                                offset = -80
                                isSwiped = true
                            } else {
                                offset = 0
                                isSwiped = false
                            }
                        }
                    }
            )
            .onTapGesture(perform: onTap)
        }
    }
}

// MARK: - Premium Collapsed Group Section View (Filters & Settings loaded from DB)

struct GroupSectionView: View {
    let group: TransactionGroup
    let banks: [BankItem]
    let transactionTypes: [TagItem]
    let quickActions: [TagItem]
    var onEditTransaction: (BankTransactionItem) -> Void
    var onDeleteTransaction: (BankTransactionItem) -> Void
    var onShowReceipt: (URL) -> Void
    
    @ObservedObject private var viewModel = BankOperationsViewModel.shared
    
    @State private var isExpanded: Bool = false
    @State private var localStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var localEndDate: Date = Date()
    @State private var isLocalFilterEnabled: Bool = false
    @State private var localLimitCount: Int = 5
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() } }) {
                    HStack {
                        Text(group.label)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: group.color))
                        
                        Spacer()
                        
                        let displayItems = filterLocalGroupItems()
                        let displayTotal = displayItems.reduce(0.0) { $0 + $1.amount }
                        
                        Text(formatCurrencyDouble(displayTotal))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(displayTotal < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(hex: group.color))
                            .padding(.leading, 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                
                Button(action: {
                    let lastItem = filterLocalGroupItems().first ?? group.items.first
                    viewModel.addQuickTransactionInGroup(groupId: group.id, lastTransaction: lastItem) { newTrans in
                        onEditTransaction(newTrans)
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(hex: group.color))
                        .padding(10)
                        .background(Circle().fill(Color(hex: group.color).opacity(0.12)))
                        .padding(.trailing, 10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: group.color).opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: group.color).opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color(hex: group.color).opacity(0.02), radius: 4, x: 0, y: 2)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Local Date Picker
                    HStack {
                        Button(action: {
                            isLocalFilterEnabled.toggle()
                            saveFiltersToDB()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isLocalFilterEnabled ? "calendar.badge.minus" : "calendar.badge.plus")
                                Text(isLocalFilterEnabled ? "Filtreyi Kaldır" : "Tarih Filtresi")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isLocalFilterEnabled ? .red : Color(hex: group.color))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isLocalFilterEnabled ? Color.red.opacity(0.1) : Color(hex: group.color).opacity(0.12))
                            .cornerRadius(6)
                        }
                        
                        if isLocalFilterEnabled {
                            Spacer()
                            DatePicker("", selection: $localStartDate, displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "tr_TR"))
                                .scaleEffect(0.85)
                                .onChange(of: localStartDate) { _ in saveFiltersToDB() }
                            Text("-")
                                .foregroundColor(.gray)
                            DatePicker("", selection: $localEndDate, displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.locale, Locale(identifier: "tr_TR"))
                                .scaleEffect(0.85)
                                .onChange(of: localEndDate) { _ in saveFiltersToDB() }
                        }
                    }
                    .padding(.horizontal, 6)
                    
                    let items = filterLocalGroupItems()
                    let limitVal = (localLimitCount == -1) ? items.count : localLimitCount
                    let visibleItems = Array(items.prefix(limitVal))
                    
                    if items.isEmpty {
                        Text("Tarih aralığına uygun işlem yok.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .padding(.vertical, 10)
                            .padding(.leading, 8)
                    } else {
                        ForEach(visibleItems) { trans in
                            TransactionRowView(
                                transaction: trans,
                                bank: banks.first(where: { $0.id == trans.bankId }),
                                typeTag: transactionTypes.first(where: { $0.id == trans.type }),
                                quickActionTags: quickActions.filter { trans.quickActions.contains($0.id) },
                                onTap: { onEditTransaction(trans) },
                                onDelete: { onDeleteTransaction(trans) },
                                onShowReceipt: onShowReceipt
                            )
                        }
                        
                        // Independent Group Pagination selector bar
                        VStack(alignment: .leading, spacing: 8) {
                            Divider().padding(.vertical, 8)
                            HStack(spacing: 6) {
                                Text("GÖRÜNÜM LİMİTİ:")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.gray)
                                
                                ForEach([5, 10, 20, 50, 100], id: \.self) { val in
                                    Button(action: {
                                        withAnimation { localLimitCount = val }
                                    }) {
                                        Text("\(val)")
                                            .font(.system(size: 11, weight: localLimitCount == val ? .bold : .medium))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(localLimitCount == val ? Color(hex: group.color).opacity(0.12) : Color.clear)
                                            .foregroundColor(localLimitCount == val ? Color(hex: group.color) : .gray)
                                            .cornerRadius(4)
                                    }
                                }
                                
                                Button(action: {
                                    withAnimation { localLimitCount = -1 }
                                }) {
                                    Text("Hepsini Gör (\(items.count))")
                                        .font(.system(size: 11, weight: localLimitCount == -1 ? .bold : .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(localLimitCount == -1 ? Color(hex: group.color).opacity(0.12) : Color.clear)
                                        .foregroundColor(localLimitCount == -1 ? Color(hex: group.color) : .gray)
                                        .cornerRadius(4)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .onAppear {
            loadLocalFiltersFromDB()
        }
        .onChange(of: viewModel.configTrigger) { _ in
            loadLocalFiltersFromDB()
        }
    }
    
    private func loadLocalFiltersFromDB() {
        guard let groupConfig = viewModel.bankGroupConfigs[group.id] as? [String: Any],
              let filters = groupConfig["filters"] as? [[String: Any]] else {
            return
        }
        
        if let dateFilter = filters.first(where: { ($0["propId"] as? String) == "date" }),
           let op = dateFilter["operator"] as? String, op == "between",
           let valStr = dateFilter["value"] as? String {
            
            let parts = valStr.split(separator: ",")
            if parts.count == 2 {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let start = formatter.date(from: String(parts[0])),
                   let end = formatter.date(from: String(parts[1])) {
                    DispatchQueue.main.async {
                        self.localStartDate = start
                        self.localEndDate = end
                        self.isLocalFilterEnabled = true
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.isLocalFilterEnabled = false
            }
        }
    }
    
    private func saveFiltersToDB() {
        viewModel.saveGroupDateFilter(
            groupId: group.id,
            startDate: localStartDate,
            endDate: localEndDate,
            isEnabled: isLocalFilterEnabled
        )
    }
    
    private func filterLocalGroupItems() -> [BankTransactionItem] {
        var items = group.items
        if isLocalFilterEnabled {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let startOfStartDate = Calendar.current.startOfDay(for: localStartDate)
            let endOfEndDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: localEndDate) ?? localEndDate
            items = items.filter { t in
                guard let tDate = formatter.date(from: t.date) else { return false }
                return tDate >= startOfStartDate && tDate <= endOfEndDate
            }
        }
        return items.sorted { a, b in
            if a.date != b.date {
                return a.date > b.date
            }
            let dateA = a.createdAt ?? Date.distantFuture
            let dateB = b.createdAt ?? Date.distantFuture
            if dateA != dateB {
                return dateA > dateB
            }
            return a.id > b.id
        }
    }
}

// MARK: - Bank Visibility & Ordering Sheet View

struct BankVisibilitySettingsSheetView: View {
    @Environment(\.dismiss) var dismiss
    @State var banks: [BankItem]
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("BANKA GÖRÜNÜRLÜĞÜ")) {
                    ForEach($banks) { $bank in
                        HStack {
                            let logoName = getLocalLogoName(for: bank.name)
                            if let logo = logoName {
                                Image(logo)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "landmark.circle.fill")
                                    .foregroundColor(.gray)
                                    .frame(width: 24, height: 24)
                            }
                            
                            Text(bank.name)
                                .font(.system(size: 14, weight: .semibold))
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation {
                                    bank.visible.toggle()
                                    updateVisibilityInDB(bank)
                                }
                            }) {
                                Image(systemName: bank.visible ? "eye" : "eye.slash")
                                    .font(.system(size: 16))
                                    .foregroundColor(bank.visible ? .blue : .gray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .onMove(perform: moveBanks)
                }
            }
            .navigationTitle("Banka Görünüm & Sıra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
    
    private func moveBanks(from source: IndexSet, to destination: Int) {
        banks.move(fromOffsets: source, toOffset: destination)
        
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        for i in 0..<banks.count {
            banks[i].order = i
            db.collection("users").document(user.uid).collection("banks").document(banks[i].id).updateData([
                "order": i
            ])
        }
    }
    
    private func updateVisibilityInDB(_ bank: BankItem) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("banks").document(bank.id).updateData([
            "visible": bank.visible
        ])
    }
}

// MARK: - Group Settings Sheet View (Visibility Toggle & Drag-Reordering Enabled)

struct GroupSettingsSheetView: View {
    @Environment(\.dismiss) var dismiss
    @State var allGroups: [TransactionGroup]
    var selectedGroupBy: String
    @State var visibility: [String: Bool]
    var onToggle: (String) -> Void
    var onReorder: ([String]) -> Void
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("GRUP GÖRÜNÜRLÜĞÜ & SIRASI")) {
                    ForEach(allGroups) { group in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { visibility[group.id] ?? true },
                                set: { _ in
                                    onToggle(group.id)
                                    visibility[group.id] = !(visibility[group.id] ?? true)
                                }
                            )) {
                                HStack {
                                    Text(group.label)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }
                    }
                    .onMove(perform: moveGroups)
                }
            }
            .navigationTitle("Grup Ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
    
    private func moveGroups(from source: IndexSet, to destination: Int) {
        allGroups.move(fromOffsets: source, toOffset: destination)
        let newOrder = allGroups.map { $0.id }
        onReorder(newOrder)
    }
}

// MARK: - Add / Edit Sheets with Copy & Paste buttons

struct AddEditBankSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    var bankToEdit: BankItem?
    var onSave: (String, String, Bool, Int) -> Void
    
    @State private var bankName: String = ""
    @State private var selectedLogo: String = "landmark"
    @State private var isVisible: Bool = true
    @State private var order: String = "0"
    
    let logos = ["akbank", "denizbank", "enpara", "garanti", "halkbank", "isbank", "vakifbank", "ziraat"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Banka Bilgileri")) {
                    TextField("Banka Adı", text: $bankName)
                    
                    Picker("Görsel Logo", selection: $selectedLogo) {
                        Text("Diğer / Yok").tag("landmark")
                        ForEach(logos, id: \.self) { logo in
                            Text(logo.uppercased()).tag(logo)
                        }
                    }
                    
                    Toggle("Aktif Görünür", isOn: $isVisible)
                    
                    TextField("Sıra No", text: $order)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle(bankToEdit == nil ? "Yeni Banka Ekle" : "Bankayı Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        let parsedOrder = Int(order) ?? 0
                        onSave(bankName, selectedLogo, isVisible, parsedOrder)
                        dismiss()
                    }
                    .disabled(bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let bank = bankToEdit {
                    bankName = bank.name
                    selectedLogo = bank.logo
                    isVisible = bank.visible
                    order = String(bank.order)
                }
            }
        }
    }
}

struct AddEditTransactionSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    var transactionToEdit: BankTransactionItem?
    var banks: [BankItem]
    var types: [TagItem]
    var quickActions: [TagItem]
    var uniqueTitles: [String]
    
    var onSave: (String, String, [String], String, String, String, String) -> Void
    var onTestLink: (URL) -> Void
    
    @State private var title: String = ""
    @State private var selectedBankId: String = ""
    @State private var selectedTypeId: String = ""
    @State private var amountString: String = ""
    @State private var selectedDate: Date = Date()
    @State private var selectedQAs: Set<String> = []
    @State private var receiptUrl: String = ""
    @State private var showDrivePicker: Bool = false
    
    private var filteredSuggestions: [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if trimmedTitle.isEmpty { return [] }
        return uniqueTitles.filter {
            let suggestLower = $0.lowercased(with: Locale(identifier: "tr_TR"))
            return suggestLower.contains(trimmedTitle) && suggestLower != trimmedTitle
        }
        .prefix(8)
        .map { $0 }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Genel Bilgiler")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Açıklama / Başlık", text: $title)
                        
                        if !filteredSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(filteredSuggestions, id: \.self) { suggestion in
                                        Button(action: {
                                            title = suggestion
                                        }) {
                                            Text(suggestion)
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.blue.opacity(0.08))
                                                .foregroundColor(.blue)
                                                .cornerRadius(8)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .transition(.opacity)
                        }
                    }
                    
                    Picker("Banka", selection: $selectedBankId) {
                        Text("Banka Seçin").tag("")
                        ForEach(banks) { b in
                            Text(b.visible ? b.name : "\(b.name) (Gizli)").tag(b.id)
                        }
                    }
                    
                    DatePicker("İşlem Tarihi", selection: $selectedDate, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "tr_TR"))
                }
                
                Section(header: Text("Tutar ve Kategoriler")) {
                    // Turkish Lira formatted input with numbers, minus sign and commas
                    TextField("Tutar (Örn: -9845,60)", text: $amountString)
                        .keyboardType(.numbersAndPunctuation)
                        .onChange(of: amountString) { newValue in
                            if newValue.contains(".") {
                                amountString = newValue.replacingOccurrences(of: ".", with: ",")
                            }
                        }
                    
                    Picker("İşlem Türü", selection: $selectedTypeId) {
                        Text("Tür Seçin").tag("")
                        ForEach(types) { t in
                            Text(t.name).tag(t.id)
                        }
                    }
                }
                
                Section(header: Text("Dekont Görseli / PDF Bağlantısı")) {
                    HStack(spacing: 8) {
                        TextField("Dekont URL (Google Drive vb.)", text: $receiptUrl)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                        
                        if !receiptUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(action: {
                                UIPasteboard.general.string = receiptUrl
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            if let url = URL(string: receiptUrl) {
                                Button(action: {
                                    onTestLink(url)
                                }) {
                                    Image(systemName: "safari")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 15))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        
                        Button(action: {
                            if let clipboard = UIPasteboard.general.string {
                                receiptUrl = clipboard
                            }
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(.blue)
                                .font(.system(size: 15))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 2)
                    
                    Button(action: {
                        showDrivePicker = true
                    }) {
                        HStack {
                            Image(systemName: "icloud.and.arrow.down")
                                .foregroundColor(.blue)
                            Text("Google Drive'dan Dekont Seç")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.blue)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                Section(header: Text("Hızlı İşlemler")) {
                    ForEach(quickActions) { qa in
                        Button(action: {
                            if selectedQAs.contains(qa.id) {
                                selectedQAs.remove(qa.id)
                            } else {
                                selectedQAs.insert(qa.id)
                            }
                        }) {
                            HStack {
                                Circle()
                                    .fill(Color(hex: tagColorToHex(qa.color)))
                                    .frame(width: 8, height: 8)
                                Text(qa.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedQAs.contains(qa.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(transactionToEdit == nil ? "Yeni İşlem Ekle" : "İşlemi Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        // Replace any dots with commas to preserve Turkish virgüllü string format
                        let formattedAmount = amountString.replacingOccurrences(of: ".", with: ",")
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        let dateStr = formatter.string(from: selectedDate)
                        
                        onSave(selectedBankId, title, Array(selectedQAs), selectedTypeId, formattedAmount, dateStr, receiptUrl)
                        dismiss()
                    }
                    .disabled(selectedBankId.isEmpty)
                }
            }
            .onAppear {
                if let trans = transactionToEdit {
                    title = trans.title
                    selectedBankId = trans.bankId
                    selectedTypeId = trans.type
                    
                    // Display amount as a string with commas (Turkish Style)
                    let formattedVal = String(format: "%.2f", trans.amount).replacingOccurrences(of: ".", with: ",")
                    if formattedVal.hasSuffix(",00") {
                        amountString = String(formattedVal.dropLast(3))
                    } else if formattedVal.hasSuffix("0") {
                        amountString = String(formattedVal.dropLast(1))
                    } else {
                        amountString = formattedVal
                    }
                    
                    selectedQAs = Set(trans.quickActions)
                    receiptUrl = trans.receiptUrl ?? ""
                    
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    if let parsedDate = formatter.date(from: trans.date) {
                        selectedDate = parsedDate
                    }
                } else if let firstBank = banks.first(where: { $0.visible })?.id ?? banks.first?.id {
                    selectedBankId = firstBank
                }
            }
            .sheet(isPresented: $showDrivePicker) {
                GoogleDrivePickerView { selectedFile in
                    receiptUrl = selectedFile.shareUrl
                }
            }
        }
    }
}

// MARK: - Utility Functions

fileprivate func getLocalLogoName(for bankName: String) -> String? {
    let lowerName = bankName.lowercased(with: Locale(identifier: "tr_TR"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "ş", with: "s")
        .replacingOccurrences(of: "ç", with: "c")
        .replacingOccurrences(of: "ğ", with: "g")
        .replacingOccurrences(of: "ü", with: "u")
        .replacingOccurrences(of: "ö", with: "o")
        .replacingOccurrences(of: "i̇", with: "i")
    
    let knownBanks = ["akbank", "denizbank", "enpara", "garanti", "halkbank", "isbank", "vakifbank", "ziraat"]
    for kb in knownBanks {
        if lowerName.contains(kb) {
            return kb
        }
    }
    return nil
}

fileprivate func tagColorToHex(_ color: String) -> String {
    switch color.lowercased() {
    case "red": return "ef4444"
    case "blue": return "3b82f6"
    case "green": return "10b981"
    case "orange": return "f97316"
    case "yellow": return "eab308"
    case "purple": return "a855f7"
    case "teal": return "14b8a6"
    case "indigo": return "6366f1"
    case "pink": return "ec4899"
    case "gray": return "6b7280"
    default:
        if color.hasPrefix("#") || color.count >= 6 {
            return color
        }
        return "6b7280"
    }
}

fileprivate func parseAmountDouble(_ val: Any?) -> Double {
    guard let val = val else { return 0.0 }
    if let doubleVal = val as? Double {
        return doubleVal
    }
    if let numVal = val as? NSNumber {
        return numVal.doubleValue
    }
    if let intVal = val as? Int {
        return Double(intVal)
    }
    if let strVal = val as? String {
        let trimmed = strVal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0.0 }
        
        let isNegative = trimmed.hasPrefix("-")
        var clean = trimmed.replacingOccurrences(of: "-", with: "")
                           .replacingOccurrences(of: "+", with: "")
                           .replacingOccurrences(of: "₺", with: "")
                           .replacingOccurrences(of: "$", with: "")
                           .replacingOccurrences(of: "€", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if clean.contains(",") && clean.contains(".") {
            if clean.lastIndex(of: ",")! > clean.lastIndex(of: ".")! {
                clean = clean.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                clean = clean.replacingOccurrences(of: ",", with: "")
            }
        } else if clean.contains(",") {
            clean = clean.replacingOccurrences(of: ",", with: ".")
        } else if clean.contains(".") {
            let components = clean.components(separatedBy: ".")
            if components.count > 1 {
                let lastComp = components.last ?? ""
                if lastComp.count == 3 {
                    clean = clean.replacingOccurrences(of: ".", with: "")
                }
            }
        }
        
        let res = Double(clean) ?? 0.0
        return isNegative ? -res : res
    }
    return 0.0
}

fileprivate func formatCurrencyDouble(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencySymbol = ""
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    
    let formatted = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    return formatted.trimmingCharacters(in: .whitespaces) + " TL"
}

fileprivate func formatShortDate(_ dateStr: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: dateStr) else { return dateStr }
    let display = DateFormatter()
    display.locale = Locale(identifier: "tr_TR")
    display.dateFormat = "d MMM yyyy"
    return display.string(from: date)
}

// MARK: - BankFilterSheetView

struct BankFilterSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var isDateFilterEnabled: Bool
    @Binding var filterStartDate: Date
    @Binding var filterEndDate: Date
    
    @Binding var filterTitleText: String
    @Binding var filterTitleOp: String
    
    @Binding var selectedQuickActionIds: Set<String>
    @Binding var selectedTypeIds: Set<String>
    @Binding var selectedBankIds: Set<String>
    
    var banks: [BankItem]
    var types: [TagItem]
    var quickActions: [TagItem]
    var uniqueTitles: [String]
    var matchingCount: Int
    var onReset: () -> Void
    
    // Expandable / Collapsible state for long categories (Default: Closed)
    @State private var isQuickActionsExpanded: Bool = false
    @State private var isTypesExpanded: Bool = false
    
    private var isAnyFilterActive: Bool {
        isDateFilterEnabled ||
        !filterTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !selectedQuickActionIds.isEmpty ||
        !selectedTypeIds.isEmpty ||
        !selectedBankIds.isEmpty
    }
    
    private var filteredSuggestions: [String] {
        let trimmedTitle = filterTitleText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if trimmedTitle.isEmpty { return [] }
        return uniqueTitles.filter {
            let suggestLower = $0.lowercased(with: Locale(identifier: "tr_TR"))
            return suggestLower.contains(trimmedTitle) && suggestLower != trimmedTitle
        }
        .prefix(8)
        .map { $0 }
    }
    
    var body: some View {
        NavigationView {
            Form {
                // 1. Tarih Seçme ve İki Tarih Arası Seçme
                Section(header: Text("Tarih Aralığı")) {
                    Toggle("Tarih Filtresini Kullan", isOn: $isDateFilterEnabled)
                    
                    if isDateFilterEnabled {
                        // Fast preset date range buttons
                        HStack(spacing: 8) {
                            Button(action: {
                                filterStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                                filterEndDate = Date()
                            }) {
                                Text("1 Hafta")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: {
                                filterStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                                filterEndDate = Date()
                            }) {
                                Text("1 Ay")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: {
                                let cal = Calendar.current
                                filterStartDate = cal.date(from: cal.dateComponents([.year], from: Date())) ?? Date()
                                filterEndDate = Date()
                            }) {
                                Text("Bu Yıl")
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.vertical, 4)
                        
                        DatePicker("Başlangıç Tarihi", selection: $filterStartDate, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "tr_TR"))
                        DatePicker("Bitiş Tarihi", selection: $filterEndDate, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "tr_TR"))
                    }
                }
                
                // 2. İşlem Adına Göre Getirme (contains, is not contains) & Otomatik Doldurma
                Section(header: Text("İşlem Adı")) {
                    Picker("Arama Tipi", selection: $filterTitleOp) {
                        Text("İçerir").tag("contains")
                        Text("İçermez").tag("notContains")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("İşlem adında ara...", text: $filterTitleText)
                            if !filterTitleText.isEmpty {
                                Button(action: { filterTitleText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        
                        if !filteredSuggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(filteredSuggestions, id: \.self) { suggestion in
                                        Button(action: {
                                            filterTitleText = suggestion
                                        }) {
                                            Text(suggestion)
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.blue.opacity(0.08))
                                                .foregroundColor(.blue)
                                                .cornerRadius(8)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                
                // 3. Hızlı İşlemlere Göre Getirme (Collapsible, Default: Closed)
                Section {
                    Button(action: {
                        withAnimation { isQuickActionsExpanded.toggle() }
                    }) {
                        HStack {
                            Text("Hızlı İşlemler")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            if !selectedQuickActionIds.isEmpty {
                                Text("(\(selectedQuickActionIds.count) seçili)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                            Spacer()
                            Image(systemName: isQuickActionsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.gray)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if isQuickActionsExpanded {
                        if quickActions.isEmpty {
                            Text("Kayıtlı hızlı işlem etiketi yok.")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        } else {
                            ForEach(quickActions) { qa in
                                Button(action: {
                                    if selectedQuickActionIds.contains(qa.id) {
                                        selectedQuickActionIds.remove(qa.id)
                                    } else {
                                        selectedQuickActionIds.insert(qa.id)
                                    }
                                }) {
                                    HStack {
                                        Circle()
                                            .fill(Color(hex: tagColorToHex(qa.color)))
                                            .frame(width: 10, height: 10)
                                        Text(qa.name)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if selectedQuickActionIds.contains(qa.id) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
                
                // 4. İşlem Türüne Göre Getirme (Collapsible, Default: Closed)
                Section {
                    Button(action: {
                        withAnimation { isTypesExpanded.toggle() }
                    }) {
                        HStack {
                            Text("İşlem Türü")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            if !selectedTypeIds.isEmpty {
                                Text("(\(selectedTypeIds.count) seçili)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                            Spacer()
                            Image(systemName: isTypesExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.gray)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if isTypesExpanded {
                        if types.isEmpty {
                            Text("Kayıtlı işlem türü yok.")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        } else {
                            ForEach(types) { t in
                                Button(action: {
                                    if selectedTypeIds.contains(t.id) {
                                        selectedTypeIds.remove(t.id)
                                    } else {
                                        selectedTypeIds.insert(t.id)
                                    }
                                }) {
                                    HStack {
                                        Circle()
                                            .fill(Color(hex: tagColorToHex(t.color)))
                                            .frame(width: 10, height: 10)
                                        Text(t.name)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if selectedTypeIds.contains(t.id) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
                
                // 5. Banka İsmine Göre Getirme
                Section(header: Text("Banka İsmine Göre")) {
                    let visibleBanks = banks.filter { $0.visible }
                    if visibleBanks.isEmpty {
                        Text("Kayıtlı görünür banka yok.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    } else {
                        ForEach(visibleBanks) { b in
                            Button(action: {
                                if selectedBankIds.contains(b.id) {
                                    selectedBankIds.remove(b.id)
                                } else {
                                    selectedBankIds.insert(b.id)
                                }
                            }) {
                                HStack {
                                    if let logoName = getLocalLogoName(for: b.name) {
                                        Image(logoName)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 22, height: 22)
                                            .clipShape(Circle())
                                    } else {
                                        Image(systemName: "landmark.circle.fill")
                                            .foregroundColor(.gray)
                                            .frame(width: 22, height: 22)
                                    }
                                    Text(b.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedBankIds.contains(b.id) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .navigationTitle("İşlem Filtreleri")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        Text("\(matchingCount) İşlem")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        
                        if isAnyFilterActive {
                            Button(action: {
                                onReset()
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
    }
}
