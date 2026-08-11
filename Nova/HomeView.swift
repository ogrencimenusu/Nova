import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UniformTypeIdentifiers

enum HomeWidgetType: String, CaseIterable, Codable, Identifiable {
    case bank = "bank"
    case finance = "finance"
    case stock = "stock"
    case dictionary = "dictionary"
    case calendar = "calendar"
    
    var id: String { self.rawValue }
}

struct HomeView: View {
    // Ordering & Visibility States
    @AppStorage("home_widget_order_v2") private var widgetOrderJSON: String = "[\"bank\",\"finance\",\"stock\",\"dictionary\",\"calendar\"]"
    @AppStorage("home_widget_hidden_v2") private var widgetHiddenJSON: String = "[]"
    @State private var isCustomizeMode: Bool = false
    
    private var widgetOrder: [HomeWidgetType] {
        if let data = widgetOrderJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            let list = arr.compactMap { HomeWidgetType(rawValue: $0) }
            if !list.isEmpty { return list }
        }
        return [.bank, .finance, .stock, .dictionary, .calendar]
    }
    
    private var hiddenWidgets: Set<String> {
        if let data = widgetHiddenJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return Set(arr)
        }
        return []
    }
    
    private func saveWidgetOrder(_ order: [HomeWidgetType]) {
        let rawList = order.map { $0.rawValue }
        if let data = try? JSONEncoder().encode(rawList),
           let str = String(data: data, encoding: .utf8) {
            widgetOrderJSON = str
        }
    }
    
    private func toggleWidgetVisibility(_ id: String) {
        var set = hiddenWidgets
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        if let data = try? JSONEncoder().encode(Array(set)),
           let str = String(data: data, encoding: .utf8) {
            widgetHiddenJSON = str
        }
    }
    
    private func moveWidget(type: HomeWidgetType, direction: Int) {
        var current = widgetOrder
        guard let idx = current.firstIndex(of: type) else { return }
        let newIdx = idx + direction
        if newIdx >= 0 && newIdx < current.count {
            current.swapAt(idx, newIdx)
            saveWidgetOrder(current)
        }
    }
    
    private func getWidgetTitle(_ type: HomeWidgetType) -> String {
        switch type {
        case .bank: return "Hesap Özetleri"
        case .finance: return "Finans Özetleri"
        case .stock: return "Borsa Portföyüm"
        case .dictionary: return "Sözlük Özetleri"
        case .calendar: return "Ajanda & Notlar"
        }
    }
    
    // Data States
    @State private var banks: [WidgetBank] = []
    @State private var institutions: [WidgetInstitution] = []
    @State private var stocks: [WidgetStock] = []
    
    // Totals States
    @State private var totalBankPortfolio: Double = 0.0
    @State private var totalFinancePortfolio: Double = 0.0
    @State private var totalFinanceTax: Double = 0.0
    @State private var totalStockPortfolio: Double = 0.0
    @State private var totalStockTax: Double = 0.0
    
    // Streak & Quick Tests Widget States
    @State private var streakCount: Int = 0
    @State private var todayProgress: Int = 0
    @State private var isGoalReached: Bool = false
    @State private var monthCalendar: [CalendarDay] = []
    @State private var quickTests: [QuickTestTemplate] = []
    
    // Calendar/Note Widget States
    @State private var todayNotes: [WidgetNote] = []
    @State private var futureNotes: [WidgetNote] = []
    @State private var showNotesView: Bool = false
    @State private var targetNoteIdForDetail: String? = nil
    
    @State private var isLoggedIn: Bool = false
    @State private var isLoading: Bool = false
    @State private var hasLoadedOnce: Bool = false // Silence loading spinners on subsequent visits
    
    @State private var currentUser: FirebaseAuth.User? = Auth.auth().currentUser
    @State private var showSettingsSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ── USER PROFILE HEADER ──────────────────────────────
                userProfileHeader
                    .padding(.horizontal, 4)
                    .padding(.top, 6)



                if isCustomizeMode {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 14))
                        Text("Bölümlerin sırasını oklar ile değiştirebilir, göz butonuna basarak gizleyip gösterebilirsiniz.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.06))
                    .cornerRadius(14)
                }

                if !isLoggedIn {
                    Spacer().frame(height: 30)
                    Text("Lütfen giriş yapın.")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ForEach(widgetOrder) { type in
                        let isHidden = hiddenWidgets.contains(type.rawValue)
                        
                        if !isCustomizeMode && isHidden {
                            // Hidden in normal view mode
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                // Section Edit Toolbar in Customize Mode
                                if isCustomizeMode {
                                    HStack(spacing: 10) {
                                        Button(action: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                toggleWidgetVisibility(type.rawValue)
                                            }
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                                                    .font(.system(size: 12, weight: .bold))
                                                Text(isHidden ? "Gizli" : "Görünür")
                                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                            }
                                            .foregroundColor(isHidden ? .red : .green)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(isHidden ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                                            .cornerRadius(10)
                                        }
                                        
                                        Text(getWidgetTitle(type))
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                moveWidget(type: type, direction: -1)
                                            }
                                        }) {
                                            Image(systemName: "chevron.up.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(widgetOrder.first == type ? Color.gray.opacity(0.3) : Color.blue)
                                        }
                                        .disabled(widgetOrder.first == type)
                                        
                                        Button(action: {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                moveWidget(type: type, direction: 1)
                                            }
                                        }) {
                                            Image(systemName: "chevron.down.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(widgetOrder.last == type ? Color.gray.opacity(0.3) : Color.blue)
                                        }
                                        .disabled(widgetOrder.last == type)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.04))
                                    .cornerRadius(12)
                                }
                                
                                widgetView(for: type)
                                    .padding(14)
                                    .background(Color.white)
                                    .cornerRadius(20)
                                    .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 5)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(Color.black.opacity(0.03), lineWidth: 1)
                                    )
                                    .opacity(isCustomizeMode && isHidden ? 0.4 : 1.0)
                                    .disabled(isCustomizeMode && isHidden)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10) // Tightly fit status bar clearance
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                colors: [Color(hex: "f4f6fa"), Color(hex: "edf1f6")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onAppear {
            loadSavedOrder()
            loadAllData()
            currentUser = Auth.auth().currentUser

            // Cold-launch deep link: check if a note was pending from widget tap
            if let pendingId = UserDefaults.standard.string(forKey: "pendingDeepLinkNoteId"), !pendingId.isEmpty {
                // Wait for the splash screen animation to fully complete before switching tabs
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.notes)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NotificationCenter.default.post(name: Notification.Name("OpenNoteDetailInternal"), object: pendingId)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }

        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenNoteDetail"))) { notification in
            let noteId = notification.object as? String
            
            // Switch active tab to .notes natively
            NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.notes)
            
            // Send deep link directly to the active NotesView instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: Notification.Name("OpenNoteDetailInternal"), object: noteId)
            }
        }
    }

    // MARK: - User Profile Header

    private var userProfileHeader: some View {
        HStack(spacing: 14) {
            // Profile photo or initials
            ZStack {
                if let photoURL = currentUser?.photoURL {
                    AsyncImage(url: photoURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            initialsView
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                } else {
                    initialsView
                        .frame(width: 52, height: 52)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
            )

            // Name + email
            VStack(alignment: .leading, spacing: 3) {
                Text(currentUser?.displayName ?? "Kullanıcı")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(currentUser?.email ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Settings + Customize buttons
            HStack(spacing: 10) {
                // Customize toggle
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isCustomizeMode.toggle()
                    }
                }) {
                    Image(systemName: isCustomizeMode ? "checkmark.circle.fill" : "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(isCustomizeMode ? .white : .primary)
                        .frame(width: 36, height: 36)
                        .background(isCustomizeMode ? Color.blue : Color.clear)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                }

                // Settings
                Button(action: { showSettingsSheet = true }) {
                    Image(systemName: "gearshape.fill")
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
        )
    }

    private var initialsView: some View {
        let name = currentUser?.displayName ?? currentUser?.email ?? "?"
        let initials = name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .uppercased()
        return ZStack {
            LinearGradient(
                colors: [Color(hex: "667eea"), Color(hex: "764ba2")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .clipShape(Circle())
    }

    @ViewBuilder
    private func widgetView(for type: HomeWidgetType) -> some View {
        switch type {
        case .bank:
            // 1. Bank Accounts Widget Summary (Horizontal Scroll)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "creditcard.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: "0052cc"))
                        Text("Hesap Özetleri")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Text("Toplam: \(formatCurrency(totalBankPortfolio))")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "0052cc"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "0052cc").opacity(0.08))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 2)
                
                if banks.isEmpty {
                    Text("Görünür hesap bulunamadı.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(banks) { bank in
                                BankCardView(bank: bank)
                                    .frame(width: 108)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
        case .finance:
            // 2. Finance Summary Widget (Horizontal Scroll - 75% screen width)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: "2ecc71"))
                        Text("Finans Özetleri")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Portföy: \(formatCurrency(totalFinancePortfolio))")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "2ecc71"))
                        if totalFinanceTax > 0 {
                            Text("Stopaj: -\(formatCurrency(totalFinanceTax))")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "2ecc71").opacity(0.08))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 2)
                
                if institutions.isEmpty {
                    Text("Görünür kurum bulunamadı.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(institutions) { inst in
                                FinanceCardView(inst: inst, showTax: true)
                                    .frame(width: UIScreen.main.bounds.width * 0.75)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
        case .stock:
            // 3. Stock Summary Widget (Horizontal Scroll - 75% screen width)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: "0052cc"))
                        Text("Hisse Özetleri")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Portföy: \(formatCurrency(totalStockPortfolio))")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "0052cc"))
                        if totalStockTax > 0 {
                            Text("Stopaj: -\(formatCurrency(totalStockTax))")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "0052cc").opacity(0.08))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 2)
                
                if stocks.isEmpty {
                    Text("Portföyde hisse bulunamadı.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(stocks) { stock in
                                StockCardView(stock: stock, showTax: true)
                                    .frame(width: UIScreen.main.bounds.width * 0.75)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
        case .dictionary:
            // 4. Streak Widget (Sözlük) & Quick Tests
            StreakWidgetView(streakCount: streakCount, todayProgress: todayProgress, isGoalReached: isGoalReached, monthCalendar: monthCalendar, quickTests: quickTests)
            
        case .calendar:
            // 5. Calendar / Notes Widget
            CalendarWidgetView(
                todayNotes: todayNotes,
                futureNotes: futureNotes,
                onSelectNote: { note in
                    targetNoteIdForDetail = note.id
                    showNotesView = true
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                targetNoteIdForDetail = nil
                showNotesView = true
            }
        }
    }
    
    private func loadSavedOrder() {
        // Migrate legacy UserDefaults "home_widget_order" if present and widgetOrderJSON is uninitialized
        if widgetOrderJSON == "[\"bank\",\"finance\",\"stock\",\"dictionary\",\"calendar\"]",
           let data = UserDefaults.standard.data(forKey: "home_widget_order"),
           let savedOrder = try? JSONDecoder().decode([HomeWidgetType].self, from: data) {
            let rawList = savedOrder.map { $0.rawValue }
            if let enc = try? JSONEncoder().encode(rawList),
               let str = String(data: enc, encoding: .utf8) {
                widgetOrderJSON = str
            }
        }
    }
    
    private func loadAllData() {
        guard let user = Auth.auth().currentUser else {
            self.isLoggedIn = false
            return
        }
        self.isLoggedIn = true
        
        if !hasLoadedOnce {
            self.isLoading = true
        }
        
        let db = Firestore.firestore()
        
        Task {
            do {
                // 1. Load Bank Data
                let banksSnap = try await db.collection("users").document(user.uid).collection("banks").getDocumentsSmart()
                let bankTransSnap = try await db.collection("users").document(user.uid).collection("bankTransactions").getDocumentsSmart()
                
                var allBanks: [WidgetBank] = []
                for doc in banksSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? ""
                    let logo = data["logo"] as? String ?? ""
                    let visible = (data["visible"] as? Bool ?? true) && (data["visible"] as? String != "false")
                    
                    var orderValue = 999
                    if let doubleVal = data["order"] as? Double {
                        orderValue = Int(doubleVal)
                    } else if let intVal = data["order"] as? Int {
                        orderValue = intVal
                    } else if let strVal = data["order"] as? String {
                        orderValue = Int(strVal) ?? 999
                    }
                    
                    let deleted = data["deleted"] as? Bool ?? false
                    
                    if !deleted {
                        allBanks.append(WidgetBank(id: id, name: name, logo: logo, visible: visible, order: orderValue, deleted: deleted, balance: 0.0))
                    }
                }
                
                for i in 0..<allBanks.count {
                    let bId = allBanks[i].id
                    let transactions = bankTransSnap.documents.filter { doc in
                        let tData = doc.data()
                        let bankId = tData["bankId"] as? String ?? ""
                        
                        var tDeleted = false
                        if let boolVal = tData["deleted"] as? Bool {
                            tDeleted = boolVal
                        } else if let intVal = tData["deleted"] as? Int {
                            tDeleted = (intVal == 1)
                        } else if let strVal = tData["deleted"] as? String {
                            tDeleted = (strVal.lowercased() == "true" || strVal == "1")
                        }
                        
                        let tType = tData["type"] as? String ?? ""
                        return bankId == bId && !tDeleted && tType != "Eyv0oZlOuCPWJbmRkv0h"
                    }
                    
                    let balance = transactions.reduce(0.0) { sum, doc in
                        let amountVal = doc.data()["amount"]
                        return sum + parseAmount(amountVal)
                    }
                    allBanks[i].balance = balance
                }
                
                let visibleBanks = allBanks.filter { $0.visible ?? true }
                var sortedBanks = visibleBanks
                sortedBanks.sort { ($0.order ?? 999) < ($1.order ?? 999) }
                
                self.banks = Array(sortedBanks.prefix(7))
                self.totalBankPortfolio = visibleBanks.reduce(0.0) { $0 + $1.balance }
                
                // Keep pre-calculated summary document in sync (Auto-migration & Cold Launch fallback)
                try? await AccountSummaryHelper.shared.summaryDocRef(uid: user.uid).setData([
                    "totalBankBalance": self.totalBankPortfolio,
                    "lastUpdated": FieldValue.serverTimestamp()
                ], merge: true)
                
                // 2. Load Finance & Stock Transactions
                let instsSnap = try await db.collection("users").document(user.uid).collection("institutions").getDocumentsSmart()
                let stocksSnap = try await db.collection("users").document(user.uid).collection("stocks").getDocumentsSmart()
                let financeTransSnap = try await db.collection("users").document(user.uid).collection("financeTransactions").getDocumentsSmart()
                
                // Parse Stocks Info
                var stocksDict: [String: (name: String, currentPrice: Double, dailyChange: Double, previousPrice: Double)] = [:]
                for doc in stocksSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? ""
                    let currentPrice = parseAmount(data["currentPrice"])
                    let dailyChange = parseAmount(data["dailyChange"])
                    let prevPrice = parseAmount(data["previousPrice"])
                    let deleted = data["deleted"] as? Bool ?? false
                    if !deleted && !name.isEmpty {
                        stocksDict[id] = (name, currentPrice, dailyChange, prevPrice)
                    }
                }
                
                // Parse Institution list
                var instList: [WidgetInstitution] = []
                for doc in instsSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? ""
                    let logo = data["logo"] as? String ?? ""
                    let visible = (data["visible"] as? Bool ?? true) && (data["visible"] as? String != "false")
                    
                    var orderValue = 999
                    if let doubleVal = data["order"] as? Double {
                        orderValue = Int(doubleVal)
                    } else if let intVal = data["order"] as? Int {
                        orderValue = intVal
                    } else if let strVal = data["order"] as? String {
                        orderValue = Int(strVal) ?? 999
                    }
                    
                    let deleted = data["deleted"] as? Bool ?? false
                    
                    if !deleted {
                        instList.append(WidgetInstitution(id: id, name: name, logo: logo, visible: visible, order: orderValue, deleted: deleted, netValue: 0.0, dailyGain: 0.0, taxValue: 0.0, dailyGainPercent: 0.0, totalGain: 0.0, totalGainPercent: 0.0, taxRate: 0.0, totalInvestment: 0.0, unrealizedGross: 0.0))
                    }
                }
                
                // Process Transactions
                struct TransactionRecord {
                    let stockId: String
                    let institutionId: String
                    let type: String
                    let quantity: Double
                    let price: Double
                    let taxRate: Double
                    let date: String
                    let createdAtSeconds: Int
                }
                
                var records: [TransactionRecord] = []
                for doc in financeTransSnap.documents {
                    let data = doc.data()
                    let deleted = data["deleted"] as? Bool ?? false
                    if deleted { continue }
                    
                    let instId = data["institutionId"] as? String ?? ""
                    let stockId = data["stockId"] as? String ?? ""
                    let type = data["type"] as? String ?? ""
                    let quantity = parseAmount(data["quantity"])
                    let price = parseAmount(data["price"])
                    let taxRate = parseAmount(data["taxRate"])
                    let date = data["date"] as? String ?? ""
                    
                    var seconds = 0
                    if let ts = data["createdAt"] as? Timestamp {
                        seconds = Int(ts.seconds)
                    } else if let dict = data["createdAt"] as? [String: Any], let sec = dict["seconds"] as? Int {
                        seconds = sec
                    }
                    
                    records.append(TransactionRecord(stockId: stockId, institutionId: instId, type: type, quantity: quantity, price: price, taxRate: taxRate, date: date, createdAtSeconds: seconds))
                }
                
                records.sort {
                    let dateCmp = $0.date.compare($1.date)
                    if dateCmp != .orderedSame {
                        return dateCmp == .orderedAscending
                    }
                    let isAlis0 = $0.type.uppercased().hasPrefix("AL")
                    let isAlis1 = $1.type.uppercased().hasPrefix("AL")
                    if isAlis0 != isAlis1 {
                        return isAlis0
                    }
                    return $0.createdAtSeconds < $1.createdAtSeconds
                }
                
                // Calculate FIFO lots
                var instLots: [String: [FinanceLot]] = [:] // Key: stockId_institutionId
                var stockLots: [String: [FinanceLot]] = [:] // Key: stockId
                
                for r in records {
                    let keyInst = "\(r.stockId)_\(r.institutionId)"
                    let keyStock = r.stockId
                    
                    if r.type.hasPrefix("AL") {
                        if instLots[keyInst] == nil { instLots[keyInst] = [] }
                        instLots[keyInst]?.append(FinanceLot(remaining: r.quantity, price: r.price, taxRate: r.taxRate, date: r.date))
                        
                        if stockLots[keyStock] == nil { stockLots[keyStock] = [] }
                        stockLots[keyStock]?.append(FinanceLot(remaining: r.quantity, price: r.price, taxRate: r.taxRate, date: r.date))
                    } else {
                        // Sell for Institution lots
                        var remainingToSellInst = r.quantity
                        if var lots = instLots[keyInst] {
                            for idx in 0..<lots.count {
                                if remainingToSellInst <= 0 { break }
                                if lots[idx].remaining <= 0 { continue }
                                let sellAmount = min(lots[idx].remaining, remainingToSellInst)
                                lots[idx].remaining -= sellAmount
                                remainingToSellInst -= sellAmount
                            }
                            instLots[keyInst] = lots
                        }
                        
                        // Sell for Stock lots
                        var remainingToSellStock = r.quantity
                        if var lots = stockLots[keyStock] {
                            for idx in 0..<lots.count {
                                if remainingToSellStock <= 0 { break }
                                if lots[idx].remaining <= 0 { continue }
                                let sellAmount = min(lots[idx].remaining, remainingToSellStock)
                                lots[idx].remaining -= sellAmount
                                remainingToSellStock -= sellAmount
                            }
                            stockLots[keyStock] = lots
                        }
                    }
                }
                
                // Aggregates for Institutions
                var instStats: [String: (totalInvestment: Double, unrealizedNet: Double, unrealizedGross: Double, dailyGain: Double)] = [:]
                for inst in instList {
                    instStats[inst.id] = (0.0, 0.0, 0.0, 0.0)
                }
                
                for (key, lots) in instLots {
                    let parts = key.split(separator: "_")
                    guard parts.count == 2 else { continue }
                    let stockId = String(parts[0])
                    let instId = String(parts[1])
                    
                    guard let stockInfo = stocksDict[stockId] else { continue }
                    
                    for lot in lots {
                        if lot.remaining > 0 {
                            let cost = lot.price * lot.remaining
                            let currentVal = stockInfo.currentPrice * lot.remaining
                            let uGross = currentVal - cost
                            let uTax = uGross > 0 ? (uGross * (lot.taxRate / 100)) : 0.0
                            
                            if var stats = instStats[instId] {
                                stats.totalInvestment += cost
                                stats.unrealizedNet += (uGross - uTax)
                                stats.unrealizedGross += uGross
                                
                                let dailyChangePrice = stockInfo.currentPrice - stockInfo.previousPrice
                                stats.dailyGain += lot.remaining * dailyChangePrice
                                
                                instStats[instId] = stats
                            }
                        }
                    }
                }
                
                for i in 0..<instList.count {
                    if let stats = instStats[instList[i].id] {
                        instList[i].totalInvestment = stats.totalInvestment
                        instList[i].unrealizedGross = stats.unrealizedGross
                        instList[i].netValue = stats.totalInvestment + stats.unrealizedNet
                        instList[i].dailyGain = stats.dailyGain
                        instList[i].taxValue = stats.unrealizedGross - stats.unrealizedNet
                        
                        let currentValue = stats.totalInvestment + stats.unrealizedGross
                        let denominator = currentValue - stats.dailyGain
                        instList[i].dailyGainPercent = (currentValue > 0 && denominator != 0) ? (stats.dailyGain / denominator * 100.0) : 0.0
                        
                        instList[i].totalGain = stats.unrealizedNet
                        instList[i].totalGainPercent = stats.totalInvestment > 0 ? (stats.unrealizedNet / stats.totalInvestment * 100.0) : 0.0
                        
                        instList[i].taxRate = stats.unrealizedGross > 0 ? (instList[i].taxValue / stats.unrealizedGross * 100.0) : 0.0
                    }
                }
                
                let visibleInsts = instList.filter { $0.visible ?? true }
                var sortedInsts = visibleInsts
                sortedInsts.sort { ($0.order ?? 999) < ($1.order ?? 999) }
                
                self.institutions = Array(sortedInsts.prefix(7))
                self.totalFinancePortfolio = visibleInsts.reduce(0.0) { $0 + $1.netValue }
                self.totalFinanceTax = visibleInsts.reduce(0.0) { $0 + $1.taxValue }
                
                // Aggregates for Stocks
                var stockStats: [String: (totalInvestment: Double, unrealizedNet: Double, unrealizedGross: Double, dailyGain: Double, quantity: Double)] = [:]
                for (stockId, _) in stocksDict {
                    stockStats[stockId] = (0.0, 0.0, 0.0, 0.0, 0.0)
                }
                
                for (stockId, lots) in stockLots {
                    guard let stockInfo = stocksDict[stockId] else { continue }
                    
                    for lot in lots {
                        if lot.remaining > 0 {
                            let cost = lot.price * lot.remaining
                            let currentVal = stockInfo.currentPrice * lot.remaining
                            let uGross = currentVal - cost
                            let uTax = uGross > 0 ? (uGross * (lot.taxRate / 100)) : 0.0
                            
                            if var stats = stockStats[stockId] {
                                stats.totalInvestment += cost
                                stats.unrealizedNet += (uGross - uTax)
                                stats.unrealizedGross += uGross
                                stats.quantity += lot.remaining
                                
                                let dailyChangePrice = stockInfo.currentPrice - stockInfo.previousPrice
                                stats.dailyGain += lot.remaining * dailyChangePrice
                                
                                stockStats[stockId] = stats
                            }
                        }
                    }
                }
                
                var stockList: [WidgetStock] = []
                for (stockId, stockInfo) in stocksDict {
                    if let stats = stockStats[stockId] {
                        let netValue = stats.totalInvestment + stats.unrealizedNet
                        if netValue > 0 {
                            let dailyGain = stats.dailyGain
                            let taxValue = stats.unrealizedGross - stats.unrealizedNet
                            
                            let currentValue = stats.totalInvestment + stats.unrealizedGross
                            let denominator = currentValue - stats.dailyGain
                            let dailyGainPercent = (currentValue > 0 && denominator != 0) ? (stats.dailyGain / denominator * 100.0) : 0.0
                            
                            let totalGain = stats.unrealizedNet
                            let totalGainPercent = stats.totalInvestment > 0 ? (stats.unrealizedNet / stats.totalInvestment * 100.0) : 0.0
                            let taxRate = stats.unrealizedGross > 0 ? (taxValue / stats.unrealizedGross * 100.0) : 0.0
                            let uGrossPercent = stats.totalInvestment > 0 ? (stats.unrealizedGross / stats.totalInvestment * 100.0) : 0.0
                            
                            // Calculate institution breakdown for this stock
                            var breakdown: [String: Double] = [:]
                            for inst in instList {
                                let keyInst = "\(stockId)_\(inst.id)"
                                if let lots = instLots[keyInst] {
                                    let remainingSum = lots.reduce(0.0) { $0 + $1.remaining }
                                    if remainingSum > 0 {
                                        breakdown[inst.name ?? inst.id] = remainingSum
                                    }
                                }
                            }
                            
                            stockList.append(WidgetStock(id: stockId, name: stockInfo.name, netValue: netValue, dailyGain: dailyGain, taxValue: taxValue, dailyGainPercent: dailyGainPercent, totalGain: totalGain, totalGainPercent: totalGainPercent, taxRate: taxRate, quantity: stats.quantity, totalInvestment: stats.totalInvestment, unrealizedGross: stats.unrealizedGross, unrealizedGrossPercent: uGrossPercent, institutionBreakdown: breakdown))
                        }
                    }
                }
                
                var sortedStocks = stockList
                sortedStocks.sort { $0.netValue > $1.netValue }
                
                self.stocks = Array(sortedStocks.prefix(7))
                self.totalStockPortfolio = stockList.reduce(0.0) { $0 + $1.netValue }
                self.totalStockTax = stockList.reduce(0.0) { $0 + $1.taxValue }
                
                // 3. Load Word logs for Dictionary Streak count
                let statsSnap = try await db.collection("users").document(user.uid).collection("daily_stats").getDocumentsSmart()
                var dailyStatsDict: [String: Int] = [:]
                for doc in statsSnap.documents {
                    let data = doc.data()
                    let dateStr = doc.documentID
                    if let count = (data["correctCount"] as? NSNumber)?.intValue ?? (data["correctCount"] as? Int) {
                        dailyStatsDict[dateStr] = count
                    }
                }
                
                var streak = 0
                var d = Date()
                let todayStr = getLocalDateStr(d)
                let todayCount = dailyStatsDict[todayStr] ?? 0
                let isGoalReachedFlag = todayCount >= 100
                if isGoalReachedFlag { streak += 1 }
                
                d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
                while true {
                    let pastStr = getLocalDateStr(d)
                    let pastCount = dailyStatsDict[pastStr] ?? 0
                    if pastCount >= 100 {
                        streak += 1
                        d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
                    } else {
                        break
                    }
                }
                
                var monthCal: [CalendarDay] = []
                var cal = Calendar.current
                cal.firstWeekday = 2 // Monday
                
                let comps = cal.dateComponents([.year, .month], from: Date())
                let startOfMonth = cal.date(from: comps)!
                if let range = cal.range(of: .day, in: .month, for: Date()) {
                    let numDays = range.count
                    let weekday = cal.component(.weekday, from: startOfMonth)
                    let emptyPrefix = (weekday + 5) % 7
                    
                    for _ in 0..<emptyPrefix {
                        monthCal.append(CalendarDay(dateStr: "", dayNum: 0, isSuccess: false, isToday: false))
                    }
                    
                    for i in 0..<numDays {
                        if let dayDate = cal.date(byAdding: .day, value: i, to: startOfMonth) {
                            let dayStr = getLocalDateStr(dayDate)
                            let dayCount = dailyStatsDict[dayStr] ?? 0
                            let success = (dayCount >= 100)
                            let isTodayFlag = (dayStr == todayStr)
                            monthCal.append(CalendarDay(dateStr: dayStr, dayNum: i + 1, isSuccess: success, isToday: isTodayFlag))
                        }
                    }
                }
                
                self.streakCount = streak
                self.todayProgress = todayCount
                self.isGoalReached = isGoalReachedFlag
                self.monthCalendar = monthCal
                
                // Fetch user's words to compute accurate quick test question counts
                var dictWordsList: [(id: String, starred: Bool, lang: String, stage: Int)] = []
                if let wordsSnap = try? await db.collection("users").document(user.uid).collection("words").getDocumentsSmart() {
                    for doc in wordsSnap.documents {
                        let d = doc.data()
                        let wid = doc.documentID
                        let st = d["isStarred"] as? Bool ?? false
                        let lg = d["language"] as? String ?? d["lang"] as? String ?? "english"
                        let sg = d["learningStage"] as? Int ?? 0
                        dictWordsList.append((id: wid, starred: st, lang: lg, stage: sg))
                    }
                }
                
                func countMatchingWords(onlyStarred: Bool, excludeStarred: Bool, lang: String, sYeni: Bool, sOgreniyor: Bool, sOgrendi: Bool) -> Int {
                    var pool = dictWordsList
                    if onlyStarred { pool = pool.filter { $0.starred } }
                    if excludeStarred { pool = pool.filter { !$0.starred } }
                    if lang != "all" && !lang.isEmpty { pool = pool.filter { $0.lang.lowercased() == lang.lowercased() } }
                    let statusFilters: [String] = [
                        sYeni ? "Yeni" : "",
                        sOgreniyor ? "Öğreniyor" : "",
                        sOgrendi ? "Öğrendi" : ""
                    ].filter { !$0.isEmpty }
                    if !statusFilters.isEmpty {
                        pool = pool.filter { w in
                            let wordStatus = w.stage == 0 ? "Yeni" : (w.stage >= 5 ? "Öğrendi" : "Öğreniyor")
                            return statusFilters.contains(wordStatus)
                        }
                    }
                    return pool.count
                }

                // Fetch Quick Tests for Home Page Widget
                if let qtSnap = try? await db.collection("users").document(user.uid).collection("quick_tests").getDocumentsSmart() {
                    var fetchedQT: [QuickTestTemplate] = []
                    for doc in qtSnap.documents {
                        let d = doc.data()
                        let name = d["name"] as? String ?? ""
                        let rawQCount = d["questionCount"] as? Int ?? (d["questionCount"] as? Double != nil ? Int(d["questionCount"] as! Double) : 15)
                        let qFormat = d["questionFormat"] as? String ?? "mixed"
                        let lang = d["selectedLanguage"] as? String ?? "all"
                        let mcq = d["typeMCQ"] as? Bool ?? true
                        let tf = d["typeTF"] as? Bool ?? true
                        let flash = d["typeFlashcard"] as? Bool ?? true
                        let written = d["typeWritten"] as? Bool ?? false
                        let sYeni = d["statusYeni"] as? Bool ?? true
                        let sOgreniyor = d["statusOgreniyor"] as? Bool ?? true
                        let sOgrendi = d["statusOgrendi"] as? Bool ?? true
                        let oStarred = d["onlyStarred"] as? Bool ?? false
                        let eStarred = d["excludeStarred"] as? Bool ?? false
                        let eSolvedToday = d["excludeSolvedToday"] as? Bool ?? false
                        let shuffleP = d["shufflePool"] as? Bool ?? true
                        let fillBlanks = d["modeFillInTheBlanks"] as? Bool ?? false
                        let smart = d["smartDistractors"] as? Bool ?? true
                        let missingL = d["modeMissingLetters"] as? Bool ?? false
                        let singleM = d["modeSingleMeaning"] as? Bool ?? false
                        let comboS = d["modeComboStreak"] as? Bool ?? false
                        let progH = d["modeProgressiveHint"] as? Bool ?? false
                        let createdAtVal = parseFirestoreDate(d["createdAt"])
                        
                        let matchingCount = countMatchingWords(onlyStarred: oStarred, excludeStarred: eStarred, lang: lang, sYeni: sYeni, sOgreniyor: sOgreniyor, sOgrendi: sOgrendi)
                        let actualQCount = matchingCount > 0 ? min(rawQCount, matchingCount) : rawQCount
                        
                        fetchedQT.append(QuickTestTemplate(
                            id: doc.documentID,
                            name: name.isEmpty ? "Hızlı Test" : name,
                            questionCount: actualQCount,
                            questionFormat: qFormat,
                            selectedLanguage: lang,
                            typeMCQ: mcq,
                            typeTF: tf,
                            typeFlashcard: flash,
                            typeWritten: written,
                            statusYeni: sYeni,
                            statusOgreniyor: sOgreniyor,
                            statusOgrendi: sOgrendi,
                            onlyStarred: oStarred,
                            excludeStarred: eStarred,
                            excludeSolvedToday: eSolvedToday,
                            shufflePool: shuffleP,
                            modeFillInTheBlanks: fillBlanks,
                            smartDistractors: smart,
                            modeMissingLetters: missingL,
                            modeSingleMeaning: singleM,
                            modeComboStreak: comboS,
                            modeProgressiveHint: progH,
                            createdAt: createdAtVal
                        ))
                    }
                    fetchedQT.sort(by: { $0.createdAt > $1.createdAt })
                    self.quickTests = fetchedQT
                }
                
                // 4. Load Notes View Data
                let notesSnap = try await db.collection("users").document(user.uid).collection("notes")
                    .whereField("date", isGreaterThanOrEqualTo: "2000-01-01")
                    .getDocumentsSmart()
                
                var allNotes: [WidgetNote] = []
                for doc in notesSnap.documents {
                    do {
                        let note = try doc.data(as: WidgetNote.self)
                        if note.deleted != true {
                            allNotes.append(note)
                        }
                    } catch {
                        print("Error decoding note: \(error)")
                    }
                }
                
                allNotes.sort { ($0.createdAt ?? Date.distantPast) > ($1.createdAt ?? Date.distantPast) }
                self.todayNotes = allNotes.filter { Calendar.current.isDateInToday($0.parsedDate) }
                self.futureNotes = allNotes.filter { $0.parsedDate > Date() && !Calendar.current.isDateInToday($0.parsedDate) }
                
                self.isLoading = false
                self.hasLoadedOnce = true // Silently loads in background next time
            } catch {
                print("Dashboard load error: \(error)")
                self.isLoading = false
            }
        }
    }
    
    private func getLocalDateStr(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }
}

// MARK: - Drop Delegate for Drag & Drop Reordering

struct WidgetDropDelegate: DropDelegate {
    let item: HomeWidgetType
    @Binding var items: [HomeWidgetType]
    @Binding var draggedItem: HomeWidgetType?
    
    func performDrop(info: DropInfo) -> Bool {
        self.draggedItem = nil
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "home_widget_order")
        }
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem else { return }
        if draggedItem != item {
            let from = items.firstIndex(of: draggedItem)!
            let to = items.firstIndex(of: item)!
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

// MARK: - Reusable View Models for App Membership

struct WidgetBank: Codable, Identifiable {
    var id: String
    var name: String?
    var logo: String?
    var visible: Bool?
    var order: Int?
    var deleted: Bool?
    var balance: Double = 0.0
}

struct WidgetInstitution: Codable, Identifiable {
    var id: String
    var name: String?
    var logo: String?
    var visible: Bool?
    var order: Int?
    var deleted: Bool?
    var netValue: Double = 0.0
    var dailyGain: Double = 0.0
    var taxValue: Double = 0.0
    var dailyGainPercent: Double = 0.0
    var totalGain: Double = 0.0
    var totalGainPercent: Double = 0.0
    var taxRate: Double = 0.0
    var totalInvestment: Double = 0.0
    var unrealizedGross: Double = 0.0
}

struct WidgetStock: Codable, Identifiable {
    var id: String
    var name: String? // Symbol like THY, EREGL
    var netValue: Double = 0.0
    var dailyGain: Double = 0.0
    var taxValue: Double = 0.0
    var dailyGainPercent: Double = 0.0
    var totalGain: Double = 0.0
    var totalGainPercent: Double = 0.0
    var taxRate: Double = 0.0
    var quantity: Double = 0.0 // Lot count
    var totalInvestment: Double = 0.0
    var unrealizedGross: Double = 0.0
    var unrealizedGrossPercent: Double = 0.0
    var institutionBreakdown: [String: Double] = [:] // Institution breakdown (Name: Lot)
}

struct FinanceLot {
    var remaining: Double
    var price: Double
    var taxRate: Double
    var date: String
}

struct CalendarDay: Hashable {
    var dateStr: String
    var dayNum: Int
    var isSuccess: Bool
    var isToday: Bool
}

struct WidgetNote: Codable, Identifiable {
    @DocumentID var id: String?
    var title: String?
    var date: String?
    var color: String?
    var deleted: Bool?
    var createdAt: Date?
    var tags: [String]?
    var itemType: String?
    
    var parsedDate: Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date ?? "") ?? Date()
    }
    
    var colorHex: String {
        switch (color ?? "").lowercased() {
        case "red": return "#ff4d4d"
        case "green": return "#2ecc71"
        case "yellow": return "#f1c40f"
        default: return "#3498db"
        }
    }
}

// MARK: - Reusable Helper Components & Views

struct BankCardView: View {
    let bank: WidgetBank
    
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white))
                
                if let logoName = getLocalLogoName(for: bank.name ?? "") {
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
                Text(bank.name ?? "")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Text(formatCurrency(bank.balance))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(bank.balance < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f8fafc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct FinanceCardView: View {
    let inst: WidgetInstitution
    let showTax: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Logo + Name
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white))
                    
                    if let logoName = getInstitutionLogo(for: inst.name ?? "") {
                        Image(logoName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "dollarsign.circle.fill")
                            .resizable()
                            .foregroundColor(.gray.opacity(0.5))
                            .frame(width: 22, height: 22)
                    }
                }
                
                Text(inst.name ?? "")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Spacer()
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // Detailed Stats rows from Web Project
            Group {
                // Brüt Kar/Zarar
                HStack {
                    Text("Brüt Kar/Zarar:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatProfitLoss(inst.unrealizedGross))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(inst.unrealizedGross >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                }
                
                // Stopaj Kesintisi
                HStack {
                    Text("Stopaj Kesintisi:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("-\(formatCurrency(inst.taxValue)) (\(formatSimplePercent(inst.taxRate)))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.8))
                }
                
                // Net Kar/Zarar
                HStack(alignment: .firstTextBaseline) {
                    Text("Net Kar/Zarar:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatProfitLoss(inst.totalGain))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(inst.totalGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                        Text(formatPercent(inst.totalGainPercent))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(inst.totalGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                            .opacity(0.8)
                    }
                }
                
                // Günlük Kazanç
                HStack(alignment: .firstTextBaseline) {
                    Text("Günlük Kazanç:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatProfitLoss(inst.dailyGain))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(inst.dailyGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                        Text(formatPercent(inst.dailyGainPercent))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(inst.dailyGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                            .opacity(0.8)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.black.opacity(0.02))
                .cornerRadius(4)
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // Portföy Değerleri
            Group {
                HStack {
                    Text("PORTFÖY DEĞERİ:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatCurrency(inst.totalInvestment))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                }
                
                HStack {
                    Text("BRÜT DEĞER:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatCurrency(inst.totalInvestment + inst.unrealizedGross))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor((inst.unrealizedGross) >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                }
                
                HStack {
                    Text("NET DEĞER:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatCurrency(inst.netValue))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor((inst.totalGain) >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
    }
}

struct StockCardView: View {
    let stock: WidgetStock
    let showTax: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Symbol Name + Lot count & Institution Breakdown
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white))
                    
                    Text(stock.name ?? "")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.black.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                
                Text(stock.name ?? "")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.8))
                    .padding(.top, 6)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(formatLot(stock.quantity)) Lot")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.04))
                        .cornerRadius(4)
                    
                    if !stock.institutionBreakdown.isEmpty {
                        VStack(alignment: .trailing, spacing: 1) {
                            ForEach(stock.institutionBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { key, value in
                                Text("\(key): \(formatLot(value))")
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                        }
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // Detailed Stats rows from Web Project
            Group {
                // Günlük Kazanç
                HStack(alignment: .firstTextBaseline) {
                    Text("Günlük Kazanç:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatProfitLoss(stock.dailyGain))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(stock.dailyGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                        Text(formatPercent(stock.dailyGainPercent))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(stock.dailyGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                            .opacity(0.8)
                    }
                }
                
                // Toplam Değer
                HStack {
                    Text("Toplam Değer:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatCurrency(stock.netValue))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                }
                
                // Brüt Kazanç
                HStack(alignment: .firstTextBaseline) {
                    Text("Brüt Kazanç:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatProfitLoss(stock.unrealizedGross))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(stock.unrealizedGross >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                        Text(formatPercent(stock.unrealizedGrossPercent))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(stock.unrealizedGross >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                            .opacity(0.8)
                    }
                }
                
                // Stopaj Kesintisi
                HStack {
                    Text("Stopaj Kesintisi:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("-\(formatCurrency(stock.taxValue)) (\(formatSimplePercent(stock.taxRate)))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.8))
                }
                
                // Net Kazanç
                HStack(alignment: .firstTextBaseline) {
                    Text("Net Kazanç:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatProfitLoss(stock.totalGain))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(stock.totalGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                        Text(formatPercent(stock.totalGainPercent))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(stock.totalGain >= 0 ? Color(hex: "2ecc71") : Color(hex: "d9534f"))
                            .opacity(0.8)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.black.opacity(0.02))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Streak & Calendar Medium Widgets

struct StreakWidgetView: View {
    let streakCount: Int
    let todayProgress: Int
    let isGoalReached: Bool
    let monthCalendar: [CalendarDay]
    var quickTests: [QuickTestTemplate] = []
    
    let dayInitials = ["P", "S", "Ç", "P", "C", "C", "P"]
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                // Sol Taraf
                VStack(alignment: .leading, spacing: 10) {
                    Text("SÖZLÜK")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(isGoalReached ? .orange : .gray.opacity(0.3))
                            .font(.system(size: 28))
                        
                        Text("\(streakCount)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bugün")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        Text("\(todayProgress) / 100")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(isGoalReached ? .green : .primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                
                Divider()
                    .padding(.horizontal, 10)
                
                // Sağ Taraf
                VStack(alignment: .center, spacing: 6) {
                    Text("BU AY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 5) {
                        ForEach(0..<7, id: \.self) { i in
                            Text(dayInitials[i])
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                        }
                    }
                    
                    let columns = Array(repeating: GridItem(.fixed(20), spacing: 5), count: 7)
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(0..<monthCalendar.count, id: \.self) { i in
                            let day = monthCalendar[i]
                            if day.dayNum == 0 {
                                Color.clear.frame(width: 20, height: 20)
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(day.isSuccess ? Color.orange : Color.gray.opacity(0.15))
                                        .frame(width: 20, height: 20)
                                    
                                    if day.isSuccess {
                                        Image(systemName: "flame.fill")
                                            .resizable()
                                            .scaledToFit()
                                            .foregroundColor(.white)
                                            .padding(4)
                                    } else {
                                        Text("\(day.dayNum)")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .overlay(
                                    Circle()
                                        .stroke(day.isToday ? Color.blue : Color.clear, lineWidth: 1.5)
                                        .padding(-2)
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.dictionary)
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // Hızlı Testler Row
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "lightning.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.orange)
                    Text("HIZLI TEST BAŞLAT")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                let listToDisplay = quickTests.isEmpty ? [
                    QuickTestTemplate(id: "default_ogrendiklerim", name: "Öğrendiklerimi Test Et", questionCount: 15, questionFormat: "mixed", selectedLanguage: "all", typeMCQ: true, typeTF: true, typeFlashcard: false, typeWritten: false, statusYeni: false, statusOgreniyor: true, statusOgrendi: true, onlyStarred: false, excludeStarred: false, excludeSolvedToday: false, shufflePool: true, modeFillInTheBlanks: false, smartDistractors: true, modeMissingLetters: false, modeSingleMeaning: false, modeComboStreak: false, modeProgressiveHint: false),
                    QuickTestTemplate(id: "default_yildizli", name: "Yıldızlı Kelimeler", questionCount: 15, questionFormat: "mixed", selectedLanguage: "all", typeMCQ: true, typeTF: true, typeFlashcard: false, typeWritten: false, statusYeni: true, statusOgreniyor: true, statusOgrendi: true, onlyStarred: true, excludeStarred: false, excludeSolvedToday: false, shufflePool: true, modeFillInTheBlanks: false, smartDistractors: true, modeMissingLetters: false, modeSingleMeaning: false, modeComboStreak: false, modeProgressiveHint: false),
                    QuickTestTemplate(id: "default_tum", name: "Tüm Kelimeler", questionCount: 20, questionFormat: "mixed", selectedLanguage: "all", typeMCQ: true, typeTF: true, typeFlashcard: false, typeWritten: false, statusYeni: true, statusOgreniyor: true, statusOgrendi: true, onlyStarred: false, excludeStarred: false, excludeSolvedToday: false, shufflePool: true, modeFillInTheBlanks: false, smartDistractors: true, modeMissingLetters: false, modeSingleMeaning: false, modeComboStreak: false, modeProgressiveHint: false)
                ] : quickTests
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(listToDisplay) { test in
                            Button(action: {
                                NotificationCenter.default.post(name: Notification.Name("SwitchTab"), object: MenuOption.dictionary)
                                NotificationCenter.default.post(name: Notification.Name("SelectDictionarySection"), object: "pratik")
                                NotificationCenter.default.post(name: Notification.Name("StartQuickTest"), object: test.id)
                            }) {
                                let isStarred = test.onlyStarred || test.id.contains("yildiz")
                                let isLearning = test.id.contains("ogrendik")
                                let accentColor: Color = isStarred ? .orange : (isLearning ? .green : .blue)
                                let iconName: String = isStarred ? "star.fill" : (isLearning ? "checkmark.seal.fill" : "lightning.fill")
                                
                                let formatTypes = [
                                    test.typeMCQ ? "Çoktan Seçmeli" : "",
                                    test.typeTF ? "D/Y" : "",
                                    test.typeFlashcard ? "Kartlar" : "",
                                    test.typeWritten ? "Yazma" : ""
                                ].filter { !$0.isEmpty }
                                
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(accentColor.opacity(0.12))
                                            .frame(width: 32, height: 32)
                                        Image(systemName: iconName)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(accentColor)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(test.name)
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        
                                        HStack(spacing: 6) {
                                            Text("\(test.questionCount) Soru")
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundColor(accentColor)
                                            
                                            if !formatTypes.isEmpty {
                                                Text("• " + formatTypes.prefix(2).joined(separator: ", "))
                                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(accentColor)
                                        .padding(.leading, 4)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .cornerRadius(14)
                                .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(accentColor.opacity(0.18), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CalendarWidgetView: View {
    let todayNotes: [WidgetNote]
    let futureNotes: [WidgetNote]
    var onSelectNote: ((WidgetNote) -> Void)? = nil
    
    var dayNameFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter
    }
    
    var dayNumberFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }
    
    var customDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM EEEE"
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // Left Side: Today
            VStack(alignment: .leading, spacing: 6) {
                Text(dayNameFormatter.string(from: Date()).uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.red)
                
                Text(dayNumberFormatter.string(from: Date()))
                    .font(.system(size: 38, weight: .regular, design: .rounded))
                    .foregroundColor(.primary)
                    .padding(.bottom, 6)
                
                VStack(alignment: .leading, spacing: 6) {
                    if todayNotes.isEmpty {
                        Text("Not yok")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.gray)
                    } else {
                        ForEach(todayNotes.prefix(2)) { note in
                            NoteRowView(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectNote?(note)
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            
            Divider()
            
            // Right Side: Future
            VStack(alignment: .leading, spacing: 6) {
                let remainingToday = Array(todayNotes.dropFirst(2))
                let groupedFuture = Dictionary(grouping: futureNotes, by: { $0.date ?? "" })
                let sortedDates = groupedFuture.keys.sorted()
                
                let tomorrowString: String = {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    return formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                }()
                
                if !remainingToday.isEmpty {
                    ForEach(remainingToday.prefix(3)) { note in
                        NoteRowView(note: note)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectNote?(note)
                            }
                    }
                } else if let firstDateStr = sortedDates.first, let firstNotes = groupedFuture[firstDateStr] {
                    let isTomorrow = (firstDateStr == tomorrowString)
                    Text(isTomorrow ? "YARIN" : customDateFormatter.string(from: firstNotes.first!.parsedDate).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.gray)
                    
                    if firstNotes.count >= 2 {
                        ForEach(firstNotes.prefix(2)) { note in
                            NoteRowView(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectNote?(note)
                                }
                        }
                    } else {
                        NoteRowView(note: firstNotes.first!)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectNote?(firstNotes.first!)
                            }
                        
                        if sortedDates.count > 1 {
                            let secondDateStr = sortedDates[1]
                            let secondNotes = groupedFuture[secondDateStr]!
                            let isSecondTomorrow = (secondDateStr == tomorrowString)
                            Text(isSecondTomorrow ? "YARIN" : customDateFormatter.string(from: secondNotes.first!.parsedDate).uppercased())
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.gray)
                                .padding(.top, 2)
                            
                            NoteRowView(note: secondNotes.first!)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectNote?(secondNotes.first!)
                                }
                        }
                    }
                } else {
                    Text("İleriki günlerde not yok.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 4)
    }
}

struct NoteRowView: View {
    let note: WidgetNote
    
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(hex: note.colorHex))
                .frame(width: 4)
            
            Text(note.title ?? "Başlıksız")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(hex: note.colorHex).opacity(0.15))
        .cornerRadius(6)
    }
}

// MARK: - Logo Name Resolvers

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

fileprivate func getInstitutionLogo(for instName: String) -> String? {
    let lowerName = instName.lowercased(with: Locale(identifier: "tr_TR"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "ş", with: "s")
        .replacingOccurrences(of: "ç", with: "c")
        .replacingOccurrences(of: "ğ", with: "g")
        .replacingOccurrences(of: "ü", with: "u")
        .replacingOccurrences(of: "ö", with: "o")
        .replacingOccurrences(of: "i̇", with: "i")
    
    let cleanName = lowerName.replacingOccurrences(of: " ", with: "")
    if cleanName.contains("midasf") {
        return "midasf"
    } else if cleanName.contains("midas") {
        return "midas"
    }
    
    let knownBanks = ["akbank", "denizbank", "enpara", "garanti", "halkbank", "isbank", "vakifbank", "ziraat"]
    for kb in knownBanks {
        if lowerName.contains(kb) {
            return kb
        }
    }
    return nil
}

// MARK: - Amount and String Parsing Helpers

func parseAmount(_ val: Any?) -> Double {
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

fileprivate func formatCurrency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        return "\(formatted) ₺"
    }
    return String(format: "%.2f ₺", value)
}

fileprivate func formatProfitLoss(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        let prefix = value >= 0 ? "+" : ""
        return "\(prefix)\(formatted) ₺"
    }
    let prefix = value >= 0 ? "+" : ""
    return String(format: "\(prefix)%.2f ₺", value)
}

fileprivate func formatDailyGain(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        let prefix = value >= 0 ? "+" : ""
        return "\(prefix)\(formatted) ₺"
    }
    let prefix = value >= 0 ? "+" : ""
    return String(format: "\(prefix)%.2f ₺", value)
}

fileprivate func formatPercent(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        let prefix = value >= 0 ? "+" : ""
        return "(\(prefix)\(formatted)%)"
    }
    let prefix = value >= 0 ? "+" : ""
    return String(format: "(\(prefix)%.2f%%)", value)
}

fileprivate func formatSimplePercent(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        return "(%\(formatted))"
    }
    return String(format: "(%%%.0f)", value)
}

fileprivate func formatLot(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 3
    formatter.locale = Locale(identifier: "tr_TR")
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.3f", value)
}

// MARK: - Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
