import SwiftUI
import FirebaseFirestore
import FirebaseAuth

private let yyyyMMddFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let trDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "dd.MM.yyyy HH:mm"
    f.locale = Locale(identifier: "tr_TR")
    return f
}()

// MARK: - Finance Models (Moved to FinanceModels.swift)

// MARK: - Helpers

private func parseDoubleField(_ val: Any?) -> Double {
    guard let val = val else { return 0.0 }
    if let d = val as? Double { return d }
    if let num = val as? NSNumber { return num.doubleValue }
    if let i = val as? Int { return Double(i) }
    if let s = val as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
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

private func dateFromString(_ s: String) -> Date? {
    return yyyyMMddFormatter.date(from: s)
}

private func formatTL(_ val: Double, decimals: Int = 2) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    return (formatter.string(from: NSNumber(value: val)) ?? "0") + " TL"
}

private func formatPct(_ val: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "%" + (formatter.string(from: NSNumber(value: val)) ?? "0,00")
}

private func formatPctNoSymbol(_ val: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "tr_TR")
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
}

private func formatQty(_ val: Double) -> String {
    if val == 0 { return "0" }
    let rounded = val.rounded()
    if abs(val - rounded) < 0.0001 {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Int(rounded))) ?? "\(Int(rounded))"
    } else {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
    }
}

private func fmtDate(_ s: String) -> String {
    guard let d = dateFromString(s) else { return s }
    let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f.string(from: d)
}

private func fmtDateShort(_ s: String) -> String {
    guard let d = dateFromString(s) else { return s }
    let f = DateFormatter(); f.dateFormat = "dd/MM/yy"; return f.string(from: d)
}

private let chartColors: [Color] = [
    Color(red: 0.24, green: 0.46, blue: 0.96),
    Color(red: 0.13, green: 0.75, blue: 0.56),
    Color(red: 0.96, green: 0.62, blue: 0.15),
    Color(red: 0.85, green: 0.25, blue: 0.35),
    Color(red: 0.58, green: 0.35, blue: 0.93),
    Color(red: 0.08, green: 0.68, blue: 0.80),
    Color(red: 0.96, green: 0.38, blue: 0.48),
    Color(red: 0.40, green: 0.76, blue: 0.28),
    Color(red: 0.95, green: 0.50, blue: 0.20),
    Color(red: 0.52, green: 0.60, blue: 0.80)
]

// MARK: - FinanceOperationsViewModel

class FinanceOperationsViewModel: ObservableObject {
    static let shared = FinanceOperationsViewModel()

    @Published var institutions: [FinanceInstitutionItem] = []
    @Published var stocks: [FinanceStockItem] = []
    @Published var transactions: [FinanceTransactionItem] = []
    @Published var isLoading: Bool = true

    @Published var lots: [ProcessedFinanceLot] = []
    @Published var instStats: [String: InstitutionStats] = [:]
    @Published var portfolio: [PortfolioItem] = []

    private var listeners: [ListenerRegistration] = []
    private var hasStarted: Bool = false

    private func recalculateAll() {
        let computedLots = processedLots()
        let computedStats = computeInstitutionStats(processed: computedLots)
        let computedPortfolio = computePortfolio(processed: computedLots)
        
        DispatchQueue.main.async {
            self.lots = computedLots
            self.instStats = computedStats
            self.portfolio = computedPortfolio
            if let user = Auth.auth().currentUser {
                AccountSummaryHelper.shared.resyncAllFinanceSummaries(uid: user.uid, institutions: self.institutions, stocks: self.stocks, transactions: self.transactions)
            }
        }
    }

    func startListeningIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        loadAllData()
    }

    func loadAllData() {
        guard let user = Auth.auth().currentUser else { return }
        removeListeners()
        DispatchQueue.main.async { self.isLoading = true }
        let db = Firestore.firestore()
        let userDoc = db.collection("users").document(user.uid)

        let instListener = userDoc.collection("institutions").addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            var list: [FinanceInstitutionItem] = []
            for doc in docs {
                let data = doc.data()
                if data["deleted"] as? Bool == true { continue }
                var order = 999
                if let v = data["order"] as? Int { order = v }
                else if let v = data["order"] as? Double { order = Int(v) }
                list.append(FinanceInstitutionItem(
                    id: doc.documentID,
                    name: data["name"] as? String ?? "",
                    logo: data["logo"] as? String ?? "",
                    visible: data["visible"] as? Bool ?? true,
                    order: order,
                    deleted: false
                ))
            }
            list.sort { $0.order < $1.order }
            DispatchQueue.main.async {
                self.institutions = list
                self.recalculateAll()
            }
        }

        let stockListener = userDoc.collection("stocks").addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            var list: [FinanceStockItem] = []
            for doc in docs {
                let data = doc.data()
                if data["deleted"] as? Bool == true { continue }
                list.append(FinanceStockItem(
                    id: doc.documentID,
                    name: data["name"] as? String ?? "",
                    currentPrice: parseDoubleField(data["currentPrice"]),
                    previousPrice: parseDoubleField(data["previousPrice"]),
                    dailyChange: parseDoubleField(data["dailyChange"]),
                    updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue(),
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
                ))
            }
            DispatchQueue.main.async {
                self.stocks = list
                self.isLoading = false
                self.recalculateAll()
            }
        }

        let transListener = userDoc.collection("financeTransactions").addSnapshotListener { snap, _ in
            guard let docs = snap?.documents else { return }
            var list: [FinanceTransactionItem] = []
            for doc in docs {
                let data = doc.data()
                if data["deleted"] as? Bool == true { continue }
                list.append(FinanceTransactionItem(
                    id: doc.documentID,
                    institutionId: data["institutionId"] as? String ?? "",
                    stockId: data["stockId"] as? String ?? "",
                    type: ((data["type"] as? String ?? "ALIŞ").uppercased().hasPrefix("AL")) ? "ALIŞ" : "SATIŞ",
                    quantity: parseDoubleField(data["quantity"]),
                    price: parseDoubleField(data["price"]),
                    taxRate: parseDoubleField(data["taxRate"]),
                    date: data["date"] as? String ?? "",
                    remainingQuantity: parseDoubleField(data["remainingQuantity"]),
                    deleted: false,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
                ))
            }
            DispatchQueue.main.async {
                self.transactions = list
                self.recalculateAll()
            }
        }

        self.listeners = [instListener, stockListener, transListener]
    }

    private func removeListeners() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
        hasStarted = false
    }

    func toggleInstitutionVisibility(instId: String, currentVisible: Bool) {
        guard let user = Auth.auth().currentUser else { return }
        Firestore.firestore().collection("users").document(user.uid)
            .collection("institutions").document(instId)
            .updateData(["visible": !currentVisible])
    }

    func reorderInstitutions(ordered: [FinanceInstitutionItem]) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let batch = db.batch()
        for (i, inst) in ordered.enumerated() {
            let ref = db.collection("users").document(user.uid).collection("institutions").document(inst.id)
            batch.updateData(["order": i], forDocument: ref)
        }
        batch.commit { _ in }
    }

    func addTransaction(institutionId: String, stockId: String, type: String,
                        quantity: Double, price: Double, taxRate: Double, date: String) {
        guard let user = Auth.auth().currentUser else { return }
        let normalizedType = type.uppercased().hasPrefix("AL") ? "ALIŞ" : "SATIŞ"
        Firestore.firestore().collection("users").document(user.uid)
            .collection("financeTransactions")
            .addDocument(data: [
                "institutionId": institutionId, "stockId": stockId, "type": normalizedType,
                "quantity": quantity, "price": price, "taxRate": taxRate, "date": date,
                "remainingQuantity": normalizedType.hasPrefix("AL") ? quantity : 0,
                "createdAt": FieldValue.serverTimestamp(), "deleted": false
            ])
            
        let isAlis = normalizedType.hasPrefix("AL")
        let amount = quantity * price
        let portfolioDelta = isAlis ? amount : -amount
        AccountSummaryHelper.shared.updateStockPortfolioSummary(uid: user.uid, portfolioDelta: portfolioDelta, taxDelta: 0)
    }

    func updateTransaction(id: String, institutionId: String, stockId: String, type: String,
                           quantity: Double, price: Double, taxRate: Double, date: String) {
        guard let user = Auth.auth().currentUser else { return }
        let normalizedType = type.uppercased().hasPrefix("AL") ? "ALIŞ" : "SATIŞ"
        let oldTrans = transactions.first(where: { $0.id == id })
        let oldIsAlis = (oldTrans?.type ?? "ALIŞ").uppercased().hasPrefix("AL")
        let oldAmount = (oldTrans?.quantity ?? 0) * (oldTrans?.price ?? 0)
        let oldDelta = oldIsAlis ? oldAmount : -oldAmount
        
        let newIsAlis = normalizedType.hasPrefix("AL")
        let newAmount = quantity * price
        let newDelta = newIsAlis ? newAmount : -newAmount
        
        let netDelta = newDelta - oldDelta
        
        Firestore.firestore().collection("users").document(user.uid)
            .collection("financeTransactions").document(id)
            .updateData(["institutionId": institutionId, "stockId": stockId, "type": normalizedType,
                         "quantity": quantity, "price": price, "taxRate": taxRate, "date": date])
                         
        if netDelta != 0 {
            AccountSummaryHelper.shared.updateStockPortfolioSummary(uid: user.uid, portfolioDelta: netDelta, taxDelta: 0)
        }
    }

    func deleteTransaction(id: String) {
        guard let user = Auth.auth().currentUser else { return }
        let oldTrans = transactions.first(where: { $0.id == id })
        let oldIsAlis = (oldTrans?.type ?? "AL").hasPrefix("AL")
        let oldAmount = (oldTrans?.quantity ?? 0) * (oldTrans?.price ?? 0)
        let oldDelta = oldIsAlis ? oldAmount : -oldAmount
        
        Firestore.firestore().collection("users").document(user.uid)
            .collection("financeTransactions").document(id)
            .updateData(["deleted": true])
            
        if oldDelta != 0 {
            AccountSummaryHelper.shared.updateStockPortfolioSummary(uid: user.uid, portfolioDelta: -oldDelta, taxDelta: 0)
        }
    }

    @discardableResult
    func ensureStockExists(symbolOrName: String, price: Double = 0) -> String {
        guard let user = Auth.auth().currentUser else { return symbolOrName }
        let clean = symbolOrName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else { return "" }
        
        if let existing = stocks.first(where: { $0.id.uppercased() == clean || $0.name.uppercased() == clean }) {
            return existing.id
        }
        
        let db = Firestore.firestore()
        let stockRef = db.collection("users").document(user.uid).collection("stocks").document(clean)
        stockRef.setData([
            "name": clean,
            "currentPrice": price,
            "previousPrice": price,
            "dailyChange": 0.0,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
        
        return clean
    }

    func updateStockPrice(id: String, name: String, newPrice: Double, oldPrice: Double) {
        guard let user = Auth.auth().currentUser else { return }
        let dailyChange = oldPrice > 0 ? ((newPrice - oldPrice) / oldPrice) * 100 : 0.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        let newPriceStr = formatter.string(from: NSNumber(value: newPrice)) ?? "\(newPrice)"
        let oldPriceStr = formatter.string(from: NSNumber(value: oldPrice)) ?? "\(oldPrice)"

        Firestore.firestore().collection("users").document(user.uid)
            .collection("stocks").document(id)
            .updateData([
                "name": name.uppercased(),
                "currentPrice": newPriceStr,
                "previousPrice": oldPriceStr,
                "dailyChange": dailyChange,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - FIFO Lot Calculation
    func processedLots() -> [ProcessedFinanceLot] {
        let sorted = transactions.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let isAlis0 = $0.type.uppercased().hasPrefix("AL")
            let isAlis1 = $1.type.uppercased().hasPrefix("AL")
            if isAlis0 != isAlis1 { return isAlis0 }
            return ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast)
        }

        struct BuyLot { var remaining: Double; var price: Double; var taxRate: Double; var date: String; var index: Int }

        var buyLots: [String: [BuyLot]] = [:]
        var runningBalances: [String: Double] = [:]
        var results: [ProcessedFinanceLot] = []

        for t in sorted {
            let key = "\(t.stockId)_\(t.institutionId)"
            if runningBalances[key] == nil { runningBalances[key] = 0 }
            if buyLots[key] == nil { buyLots[key] = [] }
            let isAlis = t.type.uppercased().hasPrefix("AL")

            if isAlis {
                let idx = buyLots[key]!.count
                buyLots[key]!.append(BuyLot(remaining: t.quantity, price: t.price, taxRate: t.taxRate, date: t.date, index: idx))
                runningBalances[key]! += t.quantity
                results.append(ProcessedFinanceLot(
                    id: t.id, institutionId: t.institutionId, stockId: t.stockId,
                    type: t.type, quantity: t.quantity, price: t.price, taxRate: t.taxRate,
                    date: t.date, runningBalance: runningBalances[key]!,
                    calculatedRemaining: t.quantity, calculatedTaxDeduction: 0,
                    totalBuyAmount: t.quantity * t.price, totalSaleAmount: 0,
                    grossProfit: 0, totalProfit: 0, costBasis: 0, profitPercentage: 0,
                    holdingDurationDays: 0, avgBuyPrice: t.price, createdAt: t.createdAt
                ))
            } else {
                var remaining = t.quantity
                var taxDeduction = 0.0, grossProfit = 0.0, weightedDays = 0.0, totalSold = 0.0
                for i in 0..<(buyLots[key]?.count ?? 0) {
                    if remaining <= 0 { break }
                    guard (buyLots[key]?[i].remaining ?? 0) > 0 else { continue }
                    let sell = min(buyLots[key]![i].remaining, remaining)
                    let profit = (t.price - buyLots[key]![i].price) * sell
                    grossProfit += profit
                    if profit > 0 && buyLots[key]![i].taxRate > 0 {
                        taxDeduction += profit * (buyLots[key]![i].taxRate / 100)
                    }
                    if let startDate = dateFromString(buyLots[key]![i].date), let endDate = dateFromString(t.date) {
                        let days = max(0, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0)
                        weightedDays += Double(days) * sell; totalSold += sell
                    }
                    buyLots[key]![i].remaining -= sell; remaining -= sell
                }
                let dur = totalSold > 0 ? Int(weightedDays / totalSold) : 0
                let totalSale = t.quantity * t.price
                let costBasis = totalSale - grossProfit
                let netProfit = grossProfit - taxDeduction
                let profitPerc = costBasis > 0 ? (netProfit / costBasis) * 100 : 0
                runningBalances[key] = max(0, (runningBalances[key] ?? 0) - t.quantity)
                results.append(ProcessedFinanceLot(
                    id: t.id, institutionId: t.institutionId, stockId: t.stockId,
                    type: t.type, quantity: t.quantity, price: t.price, taxRate: t.taxRate,
                    date: t.date, runningBalance: runningBalances[key]!,
                    calculatedRemaining: 0, calculatedTaxDeduction: taxDeduction,
                    totalBuyAmount: 0, totalSaleAmount: totalSale,
                    grossProfit: grossProfit, totalProfit: netProfit, costBasis: costBasis,
                    profitPercentage: profitPerc, holdingDurationDays: dur,
                    avgBuyPrice: t.quantity > 0 ? costBasis / t.quantity : 0, createdAt: t.createdAt
                ))
            }
        }

        var alisIdx: [String: Int] = [:]
        return results.map { lot in
            if lot.type.hasPrefix("AL") {
                let key = "\(lot.stockId)_\(lot.institutionId)"
                let idx = alisIdx[key] ?? 0; alisIdx[key] = idx + 1
                let rem = idx < (buyLots[key]?.count ?? 0) ? (buyLots[key]?[idx].remaining ?? 0) : 0
                var updated = lot; updated.calculatedRemaining = rem; return updated
            }
            return lot
        }
    }

    func computeInstitutionStats(processed: [ProcessedFinanceLot]) -> [String: InstitutionStats] {
        var stats: [String: InstitutionStats] = [:]
        for inst in institutions { stats[inst.id] = InstitutionStats() }
        for lot in processed {
            let instId = lot.institutionId
            if stats[instId] == nil { stats[instId] = InstitutionStats() }
            let stock = stocks.first(where: { $0.id == lot.stockId })
            if !lot.type.hasPrefix("AL") {
                stats[instId]!.realizedGross += lot.grossProfit
                stats[instId]!.realizedNet += lot.totalProfit
            } else if lot.calculatedRemaining > 0 {
                let cp = stock?.currentPrice ?? 0
                let cost = lot.price * lot.calculatedRemaining
                let currentVal = cp * lot.calculatedRemaining
                let uGross = currentVal - cost
                let uTax = uGross > 0 && lot.taxRate > 0 ? uGross * (lot.taxRate / 100) : 0.0
                stats[instId]!.unrealizedGross += uGross
                stats[instId]!.unrealizedNet += (uGross - uTax)
                stats[instId]!.totalInvestment += cost
                stats[instId]!.currentValue += currentVal
                let dChange = stock?.dailyChange ?? 0
                if abs(100 + dChange) > 0.001 {
                    stats[instId]!.dailyGain += currentVal * (dChange / (100 + dChange))
                }
            }
        }
        return stats
    }

    func computePortfolio(processed: [ProcessedFinanceLot]) -> [PortfolioItem] {
        var portfolio: [String: (quantity: Double, totalCost: Double, breakdown: [String: Double], firstDate: String?)] = [:]
        for lot in processed where lot.type.hasPrefix("AL") && lot.calculatedRemaining > 0 {
            let sid = lot.stockId
            if portfolio[sid] == nil { portfolio[sid] = (0, 0, [:], nil) }
            portfolio[sid]!.quantity += lot.calculatedRemaining
            portfolio[sid]!.totalCost += lot.calculatedRemaining * lot.price
            portfolio[sid]!.breakdown[lot.institutionId, default: 0] += lot.calculatedRemaining
            if let first = portfolio[sid]!.firstDate { if lot.date < first { portfolio[sid]!.firstDate = lot.date } }
            else { portfolio[sid]!.firstDate = lot.date }
        }
        let today = Date()
        return portfolio.compactMap { (sid, data) -> PortfolioItem? in
            guard data.quantity > 0 else { return nil }
            let stock = stocks.first(where: { $0.id == sid })
            let cp = stock?.currentPrice ?? 0
            let avgPrice = data.quantity > 0 ? data.totalCost / data.quantity : 0
            let grossProfit = (cp - avgPrice) * data.quantity
            var potentialTax = 0.0
            for lot in processed where lot.stockId == sid && lot.type.hasPrefix("AL") && lot.calculatedRemaining > 0 {
                let lotProfit = (cp - lot.price) * lot.calculatedRemaining
                if lotProfit > 0 && lot.taxRate > 0 { potentialTax += lotProfit * (lot.taxRate / 100) }
            }
            let netProfit = grossProfit - potentialTax
            let profPerc = data.totalCost > 0 ? (netProfit / data.totalCost) * 100 : 0
            var duration = 0
            if let firstStr = data.firstDate, let firstDate = dateFromString(firstStr) {
                duration = max(0, Calendar.current.dateComponents([.day], from: firstDate, to: today).day ?? 0)
            }
            let dChange = stock?.dailyChange ?? 0
            let dailyGain: Double = abs(100 + dChange) > 0.001 ? (data.quantity * cp) * (dChange / (100 + dChange)) : 0
            return PortfolioItem(
                id: sid, name: stock?.name ?? "?",
                currentPrice: cp, previousPrice: stock?.previousPrice ?? 0,
                dailyChange: dChange, quantity: data.quantity, totalCost: data.totalCost,
                avgPrice: avgPrice, totalGrossProfit: grossProfit, totalTaxDeduction: potentialTax,
                totalProfit: netProfit, profitPercentage: profPerc,
                holdingDurationDays: duration, dailyGain: dailyGain,
                institutionBreakdown: data.breakdown, updatedAt: stock?.updatedAt
            )
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - Root Main View

struct FinanceOperationsView: View {
    @ObservedObject private var viewModel = FinanceOperationsViewModel.shared
    @State private var stockViewLayout: String = "gallery"
    @State private var filterInstitutionId: String = "all"
    @State private var limitCount: Int = 10
    @State private var showVisibilitySheet: Bool = false
    @State private var showAddSheet: Bool = false
    @State private var editingTransaction: FinanceTransactionItem? = nil
    @State private var editingStock: FinanceStockItem? = nil
    @State private var selectedInstitution: FinanceInstitutionItem? = nil

    private var lots: [ProcessedFinanceLot] { viewModel.lots }
    private var instStats: [String: InstitutionStats] { viewModel.instStats }
    private var portfolio: [PortfolioItem] { viewModel.portfolio }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea()

                if viewModel.isLoading {
                    ProgressView("Yükleniyor...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    FinanceMainDashboardView(
                        viewModel: viewModel,
                        showAddSheet: $showAddSheet,
                        showVisibilitySheet: $showVisibilitySheet,
                        editingTransaction: $editingTransaction,
                        editingStock: $editingStock,
                        selectedInstitution: $selectedInstitution,
                        stockViewLayout: $stockViewLayout,
                        filterInstitutionId: $filterInstitutionId,
                        limitCount: $limitCount
                    )
                }
            }
            .navigationBarHidden(true)
            .onAppear { viewModel.startListeningIfNeeded() }
            .sheet(isPresented: $showVisibilitySheet) { FinanceVisibilitySheet(viewModel: viewModel) }
            .sheet(isPresented: $showAddSheet) {
                FinanceAddEditSheet(viewModel: viewModel, transaction: nil, institutions: viewModel.institutions, stocks: viewModel.stocks, portfolio: portfolio, allTransactions: viewModel.transactions) { instId, stockId, type, qty, price, tax, date in
                    viewModel.addTransaction(institutionId: instId, stockId: stockId, type: type, quantity: qty, price: price, taxRate: tax, date: date)
                }
            }
            .sheet(item: $editingTransaction) { trans in
                FinanceAddEditSheet(viewModel: viewModel, transaction: trans, institutions: viewModel.institutions, stocks: viewModel.stocks, portfolio: portfolio, allTransactions: viewModel.transactions) { instId, stockId, type, qty, price, tax, date in
                    viewModel.updateTransaction(id: trans.id, institutionId: instId, stockId: stockId, type: type, quantity: qty, price: price, taxRate: tax, date: date)
                }
            }
            .sheet(item: $editingStock) { stock in
                FinanceStockPriceEditSheet(stock: stock) { newPrice in
                    viewModel.updateStockPrice(id: stock.id, name: stock.name, newPrice: newPrice, oldPrice: stock.currentPrice)
                }
            }
            .sheet(item: $selectedInstitution) { inst in
                FinanceInstitutionDetailSheet(
                    institution: inst,
                    viewModel: viewModel,
                    stats: instStats[inst.id] ?? InstitutionStats()
                )
            }
        }
    }
}

// MARK: - Premium Main Dashboard (Hub View)

struct FinanceMainDashboardView: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Binding var showAddSheet: Bool
    @Binding var showVisibilitySheet: Bool
    @Binding var editingTransaction: FinanceTransactionItem?
    @Binding var editingStock: FinanceStockItem?
    @Binding var selectedInstitution: FinanceInstitutionItem?
    @Binding var stockViewLayout: String
    @Binding var filterInstitutionId: String
    @Binding var limitCount: Int

    private var portfolio: [PortfolioItem] { viewModel.portfolio }
    private var lots: [ProcessedFinanceLot] { viewModel.lots }
    private var instStats: [String: InstitutionStats] { viewModel.instStats }

    private var totalCost: Double { portfolio.reduce(0) { $0 + $1.totalCost } }
    private var totalCurrentValue: Double { portfolio.reduce(0) { $0 + ($1.currentPrice * $1.quantity) } }
    private var totalNetProfit: Double { portfolio.reduce(0) { $0 + $1.totalProfit } }
    private var totalTax: Double { portfolio.reduce(0) { $0 + $1.totalTaxDeduction } }
    private var totalDailyGain: Double { portfolio.reduce(0) { $0 + $1.dailyGain } }
    private var profitPercentage: Double { totalCost > 0 ? (totalNetProfit / totalCost) * 100 : 0 }

    private var visibleInstitutions: [FinanceInstitutionItem] { viewModel.institutions.filter { $0.visible } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Header Bar
                headerBar

                // Executive Hero Card
                heroCard

                // Subpages Category Section
                subPageSection

                Spacer().frame(height: 30)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    // Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finans Yönetimi")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("Portföy, Yatırımlar ve Analizler")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Yeni İşlem")
                        .font(.system(size: 13, weight: .bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.72, blue: 0.98), Color(red: 0.12, green: 0.48, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(20)
                .shadow(color: Color.blue.opacity(0.25), radius: 6, x: 0, y: 3)
            }
        }
    }

    // Hero Overview Card (White - Grey - Light Blue Glassmorphism)
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOPLAM PORTFÖY DEĞERİ")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .tracking(0.8)
                    Text(formatTL(totalCurrentValue))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                }
                Spacer()
                
                // Profit Badge Pill
                HStack(spacing: 4) {
                    Image(systemName: totalNetProfit >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                    Text((totalNetProfit >= 0 ? "+" : "") + formatPct(profitPercentage))
                        .font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(totalNetProfit >= 0 ? Color.green.opacity(0.14) : Color.red.opacity(0.14))
                .foregroundColor(totalNetProfit >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(totalNetProfit >= 0 ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                )
            }

            Rectangle()
                .fill(Color.gray.opacity(0.12))
                .frame(height: 1)

            // Metrics Row 1: Net Kar/Zarar & Günlük Kazanç
            HStack(spacing: 12) {
                metricColumn(
                    title: "Net Kar/Zarar",
                    value: (totalNetProfit >= 0 ? "+" : "") + formatTL(totalNetProfit),
                    valColor: totalNetProfit >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2)
                )
                
                Divider()
                    .background(Color.gray.opacity(0.15))
                    .frame(height: 32)
                
                metricColumn(
                    title: "Günlük Kazanç",
                    value: (totalDailyGain >= 0 ? "+" : "") + formatTL(totalDailyGain),
                    valColor: totalDailyGain >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2)
                )
            }

            Rectangle()
                .fill(Color.gray.opacity(0.12))
                .frame(height: 1)

            // Metrics Row 2: Toplam Yatırım & Tahmini Stopaj
            HStack(spacing: 12) {
                metricColumn(
                    title: "Toplam Yatırım",
                    value: formatTL(totalCost),
                    valColor: Color(red: 0.15, green: 0.18, blue: 0.25)
                )
                
                Divider()
                    .background(Color.gray.opacity(0.15))
                    .frame(height: 32)
                
                metricColumn(
                    title: "Tahmini Stopaj",
                    value: "-" + formatTL(totalTax, decimals: 2),
                    valColor: Color(red: 0.85, green: 0.2, blue: 0.2)
                )
            }
        }
        .padding(20)
        .background(
            ZStack {
                // White-Grey-Light Blue Blended Linear Gradient
                LinearGradient(
                    colors: [
                        Color.white,
                        Color(red: 0.96, green: 0.98, blue: 1.0),
                        Color(red: 0.88, green: 0.94, blue: 0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // Light Blue Glow Blur Circle Accent (Top Right)
                Circle()
                    .fill(Color(red: 0.25, green: 0.65, blue: 0.98).opacity(0.2))
                    .blur(radius: 45)
                    .offset(x: 90, y: -40)

                // Soft Sky-Blue Blur Accent (Bottom Left)
                Circle()
                    .fill(Color(red: 0.45, green: 0.8, blue: 0.98).opacity(0.15))
                    .blur(radius: 40)
                    .offset(x: -80, y: 50)
            }
        )
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.35, green: 0.72, blue: 0.98).opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .shadow(color: Color.blue.opacity(0.12), radius: 14, x: 0, y: 6)
    }

    private func metricColumn(title: String, value: String, valColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(valColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Sub-Page Category Navigation Cards Grid
    private var subPageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ALT SAYFALAR")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
                .tracking(0.8)

            VStack(spacing: 14) {
                // Card 1: Kurumlar
                NavigationLink(destination: FinanceInstitutionsSubView(
                    viewModel: viewModel,
                    showVisibilitySheet: $showVisibilitySheet,
                    selectedInstitution: $selectedInstitution
                )) {
                    subPageCard(
                        title: "Kurumlar & Bankalar",
                        subtitle: "\(visibleInstitutions.count) Aktif Kurum Hesabı",
                        icon: "building.columns.fill",
                        iconColor: Color.blue,
                        bgGradient: LinearGradient(colors: [Color.blue.opacity(0.12), Color.blue.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        badgeText: "Detaylar & Görünüm"
                    )
                }

                // Card 2: Mevcut Hisseler
                NavigationLink(destination: FinanceStocksSubView(
                    viewModel: viewModel,
                    stockViewLayout: $stockViewLayout,
                    editingStock: $editingStock
                )) {
                    subPageCard(
                        title: "Mevcut Hisseler & Fonlar",
                        subtitle: "\(portfolio.count) Aktif Varlık Pozisyonu",
                        icon: "chart.line.uptrend.xyaxis",
                        iconColor: Color.green,
                        bgGradient: LinearGradient(colors: [Color.green.opacity(0.12), Color.green.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        badgeText: "Galeri / Tablo / Özel"
                    )
                }

                // Card 3: Portföy Analizi
                NavigationLink(destination: FinancePortfolioAnalysisSubView(
                    viewModel: viewModel,
                    editingStock: $editingStock
                )) {
                    subPageCard(
                        title: "Portföy Analizi & Dağılım",
                        subtitle: "Hisse & Kurum Bazlı Grafikler ve Kar/Zarar",
                        icon: "chart.pie.fill",
                        iconColor: Color.purple,
                        bgGradient: LinearGradient(colors: [Color.purple.opacity(0.12), Color.purple.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        badgeText: "Pasta Grafikleri & Raporlar"
                    )
                }

                // Card 4: Finans İşlemleri
                NavigationLink(destination: FinanceTransactionsSubView(
                    viewModel: viewModel,
                    filterInstitutionId: $filterInstitutionId,
                    limitCount: $limitCount,
                    showAddSheet: $showAddSheet,
                    editingTransaction: $editingTransaction
                )) {
                    subPageCard(
                        title: "Finans İşlemleri Kayıtları",
                        subtitle: "\(viewModel.transactions.count) Alış / Satış İşlem Kaydı",
                        icon: "arrow.left.arrow.right.circle.fill",
                        iconColor: Color.orange,
                        bgGradient: LinearGradient(colors: [Color.orange.opacity(0.12), Color.orange.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        badgeText: "İşlem Geçmişi & Filtreler"
                    )
                }
            }
        }
    }

    private func subPageCard(title: String, subtitle: String, icon: String, iconColor: Color, bgGradient: LinearGradient, badgeText: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(bgGradient)
                    .frame(width: 50, height: 50)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                
                Text(badgeText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(iconColor)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.gray.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Sub-Page 1: Kurumlar & Bankalar

struct FinanceInstitutionsSubView: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Binding var showVisibilitySheet: Bool
    @Binding var selectedInstitution: FinanceInstitutionItem?

    private var totalPortfolioValue: Double {
        viewModel.portfolio.reduce(0) { $0 + ($1.currentPrice * $1.quantity) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Institutions Gallery View Component
                FinanceInstitutionsSectionView(
                    institutions: viewModel.institutions.filter { $0.visible },
                    instStats: viewModel.instStats,
                    portfolio: viewModel.portfolio,
                    totalPortfolioValue: totalPortfolioValue,
                    onVisibility: { showVisibilitySheet = true },
                    onSelectInstitution: { inst in
                        selectedInstitution = inst
                    }
                )

                Spacer().frame(height: 30)
            }
            .padding(.top, 16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Kurumlar & Bankalar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showVisibilitySheet = true }) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

// MARK: - Sub-Page 2: Mevcut Hisseler & Fonlar

struct FinanceStocksSubView: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Binding var stockViewLayout: String
    @Binding var editingStock: FinanceStockItem?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Main Stocks Component
                FinanceStocksSectionView(
                    portfolio: viewModel.portfolio,
                    processedLots: viewModel.lots,
                    stocks: viewModel.stocks,
                    institutions: viewModel.institutions,
                    stockViewLayout: $stockViewLayout,
                    onSelectStock: { stock in
                        editingStock = stock
                    }
                )

                Spacer().frame(height: 30)
            }
            .padding(.top, 16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Mevcut Hisseler")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sub-Page 3: Portföy Analizi & Dağılım

struct FinancePortfolioAnalysisSubView: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Binding var editingStock: FinanceStockItem?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                FinancePortfolioAnalysisSection(
                    portfolio: viewModel.portfolio,
                    institutions: viewModel.institutions,
                    instStats: viewModel.instStats,
                    processedLots: viewModel.lots,
                    onSelectStock: { stock in
                        editingStock = stock
                    }
                )

                Spacer().frame(height: 30)
            }
            .padding(.top, 16)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Portföy Analizi")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sub-Page 4: Finans İşlemleri Kayıtları

struct FinanceTransactionsSubView: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Binding var filterInstitutionId: String
    @Binding var limitCount: Int
    @Binding var showAddSheet: Bool
    @Binding var editingTransaction: FinanceTransactionItem?
    @State private var searchText: String = ""
    @State private var filterStockId: String = "all"
    @State private var filterTxType: String = "all"
    @State private var sortOrder: String = "newest"
    @State private var showFilterSheet: Bool = false
    @State private var lotToDelete: ProcessedFinanceLot? = nil

    private var hasActiveFilters: Bool {
        filterInstitutionId != "all" || filterStockId != "all" || filterTxType != "all" || sortOrder != "newest"
    }

    private var filteredLots: [ProcessedFinanceLot] {
        var result = viewModel.lots as [ProcessedFinanceLot]
        
        // Sorting Order (default newest first)
        if sortOrder != "oldest" {
            result = result.reversed()
        }

        // Institution Filter
        if filterInstitutionId != "all" {
            result = result.filter { $0.institutionId == filterInstitutionId }
        }

        // Stock Filter
        if filterStockId != "all" {
            result = result.filter { $0.stockId == filterStockId }
        }

        // Tx Type Filter
        if filterTxType != "all" {
            result = result.filter { $0.type.uppercased().hasPrefix(filterTxType.uppercased().prefix(2)) }
        }

        // Search Text Filter
        if !searchText.isEmpty {
            result = result.filter { lot in
                let sn = viewModel.stocks.first(where: { $0.id == lot.stockId })?.name ?? ""
                let inn = viewModel.institutions.first(where: { $0.id == lot.institutionId })?.name ?? ""
                return sn.localizedCaseInsensitiveContains(searchText) ||
                       inn.localizedCaseInsensitiveContains(searchText) ||
                       lot.date.contains(searchText) ||
                       lot.type.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    private var visibleLots: [ProcessedFinanceLot] { Array(filteredLots.prefix(limitCount)) }

    var body: some View {
        VStack(spacing: 12) {
            // Search Bar & Filter Icon Row
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Hisse, Kurum veya İşlem Ara...", text: $searchText)
                        .font(.system(size: 14))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.12), lineWidth: 1))

                // Filter Icon Button
                Button(action: { showFilterSheet = true }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(hasActiveFilters ? Color.blue : Color.white)
                            .frame(width: 42, height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(hasActiveFilters ? Color.blue : Color.gray.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
                        
                        Image(systemName: hasActiveFilters ? "slider.horizontal.3" : "slider.horizontal.3")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(hasActiveFilters ? .white : .blue)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill("all", "Tümü")
                    ForEach(viewModel.institutions) { inst in filterPill(inst.id, inst.name) }
                }
                .padding(.horizontal, 16)
            }

            // Limit Buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("LİMİT:").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    ForEach([5, 10, 20, 50, 100], id: \.self) { v in limitBtn(v, "\(v)") }
                    limitBtn(filteredLots.count, "Hepsi (\(filteredLots.count))")
                }
                .padding(.horizontal, 16)
            }

            if visibleLots.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("İşlem bulunamadı.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(visibleLots) { lot in
                        TxRow(
                            lot: lot,
                            institution: viewModel.institutions.first(where: { $0.id == lot.institutionId }),
                            stock: viewModel.stocks.first(where: { $0.id == lot.stockId })
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.white)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                lotToDelete = lot
                            } label: {
                                Label("Sil", systemImage: "trash")
                            }
                            
                            Button {
                                onEdit(lot)
                            } label: {
                                Label("Düzenle", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
                .alert("İşlemi Sil", isPresented: Binding(
                    get: { lotToDelete != nil },
                    set: { if !$0 { lotToDelete = nil } }
                )) {
                    Button("İptal", role: .cancel) { lotToDelete = nil }
                    Button("Sil", role: .destructive) {
                        if let lot = lotToDelete {
                            viewModel.deleteTransaction(id: lot.id)
                        }
                        lotToDelete = nil
                    }
                } message: {
                    Text("Bu işlemi silmek istediğinize emin misiniz?")
                }
            }
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Finans İşlemleri")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FinanceFilterSheet(
                filterInstId: $filterInstitutionId,
                filterStockId: $filterStockId,
                filterTxType: $filterTxType,
                sortOrder: $sortOrder,
                institutions: viewModel.institutions,
                stocks: viewModel.stocks,
                portfolio: viewModel.portfolio
            )
        }
    }

    private func onEdit(_ lot: ProcessedFinanceLot) {
        if let t = viewModel.transactions.first(where: { $0.id == lot.id }) {
            editingTransaction = t
        }
    }

    private func filterPill(_ id: String, _ name: String) -> some View {
        Button(action: { filterInstitutionId = id }) {
            Text(name)
                .font(.system(size: 13, weight: filterInstitutionId == id ? .bold : .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(filterInstitutionId == id ? Color.blue : Color.white)
                .foregroundColor(filterInstitutionId == id ? .white : .secondary)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        }
    }

    private func limitBtn(_ val: Int, _ label: String) -> some View {
        Button(action: { limitCount = val }) {
            Text(label)
                .font(.system(size: 10, weight: limitCount == val ? .bold : .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(limitCount == val ? Color.blue.opacity(0.12) : Color.clear)
                .foregroundColor(limitCount == val ? .blue : .secondary).cornerRadius(5)
        }
    }
}

// MARK: - Section 1: Kurumlar Gallery

struct FinanceInstitutionsSectionView: View {
    let institutions: [FinanceInstitutionItem]
    let instStats: [String: InstitutionStats]
    let portfolio: [PortfolioItem]
    let totalPortfolioValue: Double
    let onVisibility: () -> Void
    let onSelectInstitution: (FinanceInstitutionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 14) {
                ForEach(institutions) { inst in
                    InstCard(
                        institution: inst,
                        stats: instStats[inst.id] ?? InstitutionStats(),
                        portfolio: portfolio,
                        totalPortfolioValue: totalPortfolioValue
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectInstitution(inst)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - FlowLayout for Wrapping Chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []

        init(in maxLineWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxLineWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                points.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            size = CGSize(width: maxLineWidth, height: currentY + lineHeight)
        }
    }
}

struct InstCard: View {
    let institution: FinanceInstitutionItem
    let stats: InstitutionStats
    let portfolio: [PortfolioItem]
    let totalPortfolioValue: Double

    private var heldItems: [PortfolioItem] {
        portfolio.filter { ($0.institutionBreakdown[institution.id] ?? 0) > 0 }
    }

    private var sharePct: Double {
        totalPortfolioValue > 0 ? (stats.currentValue / totalPortfolioValue) * 100 : 0
    }

    private var profitPct: Double {
        stats.totalInvestment > 0 ? (stats.unrealizedNet / stats.totalInvestment) * 100 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Logo, Name, Share Badge
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.08)).frame(width: 42, height: 42)
                    if !institution.logo.isEmpty, let url = URL(string: institution.logo) {
                        AsyncImage(url: url) { img in img.resizable().scaledToFit() }
                            placeholder: { Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 18)) }
                        .frame(width: 28, height: 28).clipShape(Circle())
                    } else {
                        Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 18))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(institution.name)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("\(heldItems.count) Aktif Varlık Pozisyonu")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if sharePct > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("%" + formatPctNoSymbol(sharePct))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                        Text("Portföy Payı")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(10)
                }
            }

            // Portfolio Share Progress Bar
            if sharePct > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.12)).frame(height: 5)
                        Capsule().fill(LinearGradient(colors: [Color.blue, Color(red: 0.35, green: 0.72, blue: 0.98)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * CGFloat(min(1.0, sharePct / 100.0))), height: 5)
                    }
                }
                .frame(height: 5)
            }

            Divider().background(Color.gray.opacity(0.12))

            // Main Portfolio Value Row (BRÜT DEĞER)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MEVCUT PORTFÖY DEĞERİ (BRÜT)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    Text(formatTL(stats.currentValue))
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                }
                Spacer()

                // Net Profit Pill
                if stats.totalInvestment > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: stats.unrealizedNet >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text((stats.unrealizedNet >= 0 ? "+" : "") + formatPct(profitPct))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(stats.unrealizedNet >= 0 ? Color.green.opacity(0.14) : Color.red.opacity(0.14))
                    .foregroundColor(stats.unrealizedNet >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                    .cornerRadius(8)
                }
            }

            // Detailed Metrics Grid (2 Columns)
            VStack(spacing: 8) {
                HStack {
                    detailMetric("Toplam Yatırım", formatTL(stats.totalInvestment), valColor: .primary)
                    Spacer()
                    detailMetric("Net Kar/Zarar", (stats.unrealizedNet >= 0 ? "+" : "") + formatTL(stats.unrealizedNet), valColor: stats.unrealizedNet >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                }

                HStack {
                    detailMetric("Brüt Kar/Zarar", (stats.unrealizedGross >= 0 ? "+" : "") + formatTL(stats.unrealizedGross), valColor: stats.unrealizedGross >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                    Spacer()
                    let tax = stats.unrealizedGross > stats.unrealizedNet ? stats.unrealizedGross - stats.unrealizedNet : 0
                    detailMetric("Tahmini Stopaj", "-" + formatTL(tax, decimals: 2), valColor: Color(red: 0.85, green: 0.2, blue: 0.2))
                }

                HStack {
                    detailMetric("Günlük Kazanç", (stats.dailyGain >= 0 ? "+" : "") + formatTL(stats.dailyGain), valColor: stats.dailyGain >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                    Spacer()
                    if stats.realizedNet != 0 {
                        detailMetric("Realize Kar", (stats.realizedNet >= 0 ? "+" : "") + formatTL(stats.realizedNet), valColor: stats.realizedNet >= 0 ? Color(red: 0.08, green: 0.6, blue: 0.25) : Color(red: 0.85, green: 0.2, blue: 0.2))
                    } else {
                        detailMetric("Net Değer", formatTL(stats.totalInvestment + stats.unrealizedNet), valColor: .primary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))

            // Active Stocks Badges (Wrapping Flow Layout)
            if !heldItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PORTFÖYDEKİ VARLIKLAR:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    FlowLayout(spacing: 6) {
                        ForEach(heldItems) { item in
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.blue)
                                let qty = item.institutionBreakdown[institution.id] ?? 0
                                Text("\(formatQty(qty)) adet")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.08))
                            .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.gray.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    private func detailMetric(_ title: String, _ value: String, valColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(valColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Visibility Sheet

struct FinanceVisibilitySheet: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    @Environment(\.dismiss) var dismiss
    @State private var localInst: [FinanceInstitutionItem] = []

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Surukleyerek siralay\u{131}n, goz ikonuna dokunarak gizleyin.")
                    .font(.system(size: 12)).foregroundColor(.secondary).padding()

                List {
                    ForEach($localInst) { $inst in
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Color.blue.opacity(0.08)).frame(width: 32, height: 32)
                                if !inst.logo.isEmpty, let url = URL(string: inst.logo) {
                                    AsyncImage(url: url) { img in img.resizable().scaledToFit() }
                                        placeholder: { Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 13)) }
                                    .frame(width: 20, height: 20).clipShape(Circle())
                                } else {
                                    Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 13))
                                }
                            }

                            Text(inst.name).font(.system(size: 15, weight: .medium))
                                .foregroundColor(inst.visible ? .primary : .secondary)
                            
                            Spacer()

                            Button(action: {
                                viewModel.toggleInstitutionVisibility(instId: inst.id, currentVisible: inst.visible)
                                inst.visible.toggle()
                            }) {
                                Image(systemName: inst.visible ? "eye.fill" : "eye.slash.fill")
                                    .foregroundColor(inst.visible ? .blue : .gray.opacity(0.4))
                                    .font(.system(size: 17))
                            }.buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .onMove { from, to in
                        localInst.move(fromOffsets: from, toOffset: to)
                        viewModel.reorderInstitutions(ordered: localInst)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Kurum Gorunurlugu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Bitti") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { localInst = viewModel.institutions }
    }
}

// MARK: - Institution Detail Sheet

struct FinanceInstitutionDetailSheet: View {
    let institution: FinanceInstitutionItem
    @ObservedObject var viewModel: FinanceOperationsViewModel
    let stats: InstitutionStats
    @Environment(\.dismiss) var dismiss

    @State private var stockViewLayout: String = "gallery"
    @State private var editingStock: FinanceStockItem? = nil

    private var instLots: [ProcessedFinanceLot] {
        viewModel.lots.filter { $0.institutionId == institution.id }
    }

    private var instPortfolio: [PortfolioItem] {
        viewModel.computePortfolio(processed: instLots)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Card for Institution Stats
                    InstitutionHeaderCard(institution: institution, stats: stats)
                        .padding(.horizontal, 16)

                    // Stocks Section header & Layout Buttons
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            Text("Hisse ve Fonlar (\(instPortfolio.count))")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                            HStack(spacing: 4) {
                                layoutBtn("Galeri", icon: "square.grid.2x2.fill", layout: "gallery")
                                layoutBtn("Tablo", icon: "list.bullet", layout: "table")
                                layoutBtn("Ozel", icon: "tablecells.fill", layout: "special")
                            }
                        }
                        .padding(.horizontal, 16)

                        if instPortfolio.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 10) {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                        .font(.system(size: 36))
                                        .foregroundColor(.gray.opacity(0.4))
                                    Text("Bu kurumda aktif hisse/fon bulunamadı.")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 32)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
                            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                            .padding(.horizontal, 16)
                        } else {
                            switch stockViewLayout {
                            case "table":
                                StocksTableView(portfolio: instPortfolio, onSelectStock: { s in editingStock = s })
                            case "special":
                                StocksSpecialView(processedLots: instLots, stocks: viewModel.stocks, institutions: [institution], onSelectStock: { s in editingStock = s })
                            default:
                                StocksGalleryView(portfolio: instPortfolio, onSelectStock: { s in editingStock = s })
                            }
                        }
                    }

                    Spacer().frame(height: 20)
                }
                .padding(.top, 16)
            }
            .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
            .navigationTitle(institution.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $editingStock) { stock in
                FinanceStockPriceEditSheet(stock: stock) { newPrice in
                    viewModel.updateStockPrice(id: stock.id, name: stock.name, newPrice: newPrice, oldPrice: stock.currentPrice)
                }
            }
        }
    }

    private func layoutBtn(_ title: String, icon: String, layout: String) -> some View {
        Button(action: { stockViewLayout = layout }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(stockViewLayout == layout ? Color.blue.opacity(0.12) : Color.clear)
            .foregroundColor(stockViewLayout == layout ? .blue : .secondary)
            .cornerRadius(8)
        }
    }
}

struct InstitutionHeaderCard: View {
    let institution: FinanceInstitutionItem
    let stats: InstitutionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.08)).frame(width: 44, height: 44)
                    if !institution.logo.isEmpty, let url = URL(string: institution.logo) {
                        AsyncImage(url: url) { img in img.resizable().scaledToFit() }
                            placeholder: { Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 18)) }
                        .frame(width: 30, height: 30).clipShape(Circle())
                    } else {
                        Image(systemName: "building.columns").foregroundColor(.blue).font(.system(size: 18))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(institution.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Kurum Portföy Özeti")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1)

            VStack(spacing: 6) {
                instRow("Net Kar/Zarar", stats.unrealizedNet, colored: true)
                instRow("Brut Kar/Zarar", stats.unrealizedGross, colored: true)
                instRow("Gunluk Kazanc", stats.dailyGain, colored: true)

                Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1).padding(.vertical, 4)

                instRow("Portfoy Degeri", stats.totalInvestment, colored: false)
                instRow("Brut Deger", stats.totalInvestment + stats.unrealizedGross, colored: true)
                instRow("Net Deger", stats.totalInvestment + stats.unrealizedNet, colored: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.gray.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 3)
    }

    private func instRow(_ label: String, _ value: Double, colored: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Text((colored && value > 0 ? "+" : "") + formatTL(value))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(colored ? (value > 0 ? .green : value < 0 ? .red : .secondary) : .primary)
        }
    }
}

// MARK: - Section 2: Mevcut Hisseler

struct FinanceStocksSectionView: View {
    let portfolio: [PortfolioItem]
    let processedLots: [ProcessedFinanceLot]
    let stocks: [FinanceStockItem]
    let institutions: [FinanceInstitutionItem]
    @Binding var stockViewLayout: String
    let onSelectStock: (FinanceStockItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 4) {
                    layoutBtn("Galeri", icon: "square.grid.2x2.fill", layout: "gallery")
                    layoutBtn("Tablo", icon: "list.bullet", layout: "table")
                    layoutBtn("Özel", icon: "tablecells.fill", layout: "special")
                }
            }.padding(.horizontal, 16)

            if portfolio.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 32)).foregroundColor(.gray.opacity(0.4))
                        Text("Aktif portföy bulunamadı.").font(.system(size: 14)).foregroundColor(.secondary)
                    }.padding(.vertical, 24)
                    Spacer()
                }
            } else {
                switch stockViewLayout {
                case "table": StocksTableView(portfolio: portfolio, onSelectStock: onSelectStock)
                case "special": StocksSpecialView(processedLots: processedLots, stocks: stocks, institutions: institutions, onSelectStock: onSelectStock)
                default: StocksGalleryView(portfolio: portfolio, onSelectStock: onSelectStock)
                }
            }
        }
    }

    private func layoutBtn(_ title: String, icon: String, layout: String) -> some View {
        Button(action: { stockViewLayout = layout }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(stockViewLayout == layout ? Color.blue.opacity(0.12) : Color.clear)
            .foregroundColor(stockViewLayout == layout ? .blue : .secondary)
            .cornerRadius(8)
        }
    }
}

struct StocksGalleryView: View {
    let portfolio: [PortfolioItem]
    let onSelectStock: (FinanceStockItem) -> Void

    var body: some View {
        VStack(spacing: 14) {
            ForEach(portfolio) { item in
                let sItem = FinanceStockItem(id: item.id, name: item.name, currentPrice: item.currentPrice, previousPrice: item.previousPrice, dailyChange: item.dailyChange, updatedAt: item.updatedAt, createdAt: nil)
                StockGalleryCard(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectStock(sItem)
                    }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct StockGalleryCard: View {
    let item: PortfolioItem
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(item.name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(.blue)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: item.dailyChange >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 9))
                    Text(formatPct(item.dailyChange)).font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(item.dailyChange >= 0 ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                .foregroundColor(item.dailyChange >= 0 ? .green : .red).cornerRadius(8)
            }.padding(.bottom, 12)

            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1).padding(.bottom, 10)

            sRow("Adet", formatQty(item.quantity))
            sRow("Ort. Fiyat", formatTL(item.avgPrice, decimals: 4))
            sRow("Mevcut Fiyat", formatTL(item.currentPrice, decimals: 4))

            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1).padding(.vertical, 10)

            profitRow("Brut Kazanc", gross: item.totalGrossProfit,
                      perc: item.totalCost > 0 ? item.totalGrossProfit / item.totalCost * 100 : 0)
            taxRow("Stopaj Kesintisi", item.totalTaxDeduction)
            profitRow("Net Kazanc", gross: item.totalProfit, perc: item.profitPercentage, bold: true)
            dailyRow("Gunluk Kazanc", item.dailyGain, item.dailyChange)

            Rectangle().fill(Color.gray.opacity(0.1)).frame(height: 1).padding(.vertical, 10)

            sRow("Yatirim", formatTL(item.totalCost))
            if item.holdingDurationDays > 0 { sRow("Elde Tutma", "\(item.holdingDurationDays) gun") }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    private func sRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold))
        }.padding(.vertical, 3)
    }

    private func profitRow(_ label: String, gross: Double, perc: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text((gross >= 0 ? "+" : "") + formatTL(gross))
                    .font(.system(size: bold ? 13 : 12, weight: bold ? .bold : .semibold))
                    .foregroundColor(gross >= 0 ? .green : .red)
                Text(formatPct(perc)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private func taxRow(_ label: String, _ val: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Text("-" + formatTL(val, decimals: 2)).font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
        }.padding(.vertical, 3)
    }

    private func dailyRow(_ label: String, _ val: Double, _ pct: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text((val >= 0 ? "+" : "") + formatTL(val))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(val >= 0 ? .green : .red)
                Text(formatPct(pct)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

struct StocksTableView: View {
    let portfolio: [PortfolioItem]
    let onSelectStock: (FinanceStockItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Hisse").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    .frame(minWidth: 70, alignment: .leading).padding(.leading, 16)
                Spacer()
                Text("Fiyat").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).frame(width: 86, alignment: .trailing)
                Text("G%").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                Text("Net K/Z").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).frame(width: 96, alignment: .trailing).padding(.trailing, 16)
            }
            .padding(.vertical, 10).background(Color.gray.opacity(0.06))

            LazyVStack(spacing: 0) {
                ForEach(Array(portfolio.enumerated()), id: \.1.id) { idx, item in
                    let sItem = FinanceStockItem(id: item.id, name: item.name, currentPrice: item.currentPrice, previousPrice: item.previousPrice, dailyChange: item.dailyChange, updatedAt: item.updatedAt, createdAt: nil)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 14, weight: .bold)).foregroundColor(.blue)
                            Text(formatQty(item.quantity) + " lot").font(.system(size: 11)).foregroundColor(.secondary)
                        }.frame(minWidth: 70, alignment: .leading).padding(.leading, 16)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatTL(item.currentPrice, decimals: 4)).font(.system(size: 12, weight: .bold))
                            Text("Ort: " + formatTL(item.avgPrice, decimals: 4)).font(.system(size: 10)).foregroundColor(.secondary)
                        }.frame(width: 86, alignment: .trailing)
                        HStack(spacing: 2) {
                            Image(systemName: item.dailyChange >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 7))
                            Text(formatPct(item.dailyChange)).font(.system(size: 11, weight: .bold))
                        }.foregroundColor(item.dailyChange >= 0 ? .green : .red).frame(width: 60, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text((item.totalProfit >= 0 ? "+" : "") + formatTL(item.totalProfit))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(item.totalProfit >= 0 ? .green : .red)
                            Text(formatPct(item.profitPercentage)).font(.system(size: 10)).foregroundColor(.secondary)
                        }.frame(width: 96, alignment: .trailing).padding(.trailing, 16)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectStock(sItem)
                    }
                    if idx < portfolio.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
}

struct StocksSpecialView: View {
    let processedLots: [ProcessedFinanceLot]
    let stocks: [FinanceStockItem]
    let institutions: [FinanceInstitutionItem]
    let onSelectStock: (FinanceStockItem) -> Void

    private var groupedLots: [(institutionId: String, name: String, lots: [ProcessedFinanceLot])] {
        let active = processedLots.filter { $0.type.hasPrefix("AL") && $0.calculatedRemaining > 0 }
        let groups = Dictionary(grouping: active, by: { $0.institutionId })
        return groups.map { key, value in
            let inst = institutions.first(where: { $0.id == key })
            let name = inst?.name ?? "Bilinmeyen Kurum"
            let order = inst?.order ?? 999
            let sortedLots = value.sorted { lot1, lot2 in
                let stock1 = stocks.first(where: { $0.id == lot1.stockId })?.name ?? lot1.stockId
                let stock2 = stocks.first(where: { $0.id == lot2.stockId })?.name ?? lot2.stockId
                let comp = stock1.localizedCaseInsensitiveCompare(stock2)
                if comp == .orderedSame {
                    return lot1.date < lot2.date
                }
                return comp == .orderedAscending
            }
            return (institutionId: key, name: name, order: order, lots: sortedLots)
        }.sorted { g1, g2 in
            if g1.order != g2.order {
                return g1.order < g2.order
            }
            return g1.name.localizedCaseInsensitiveCompare(g2.name) == .orderedAscending
        }.map { (institutionId: $0.institutionId, name: $0.name, lots: $0.lots) }
    }

    private var allActiveLots: [ProcessedFinanceLot] {
        processedLots.filter { $0.type.hasPrefix("AL") && $0.calculatedRemaining > 0 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    spHLeading("HISSE", 80)
                    spH("T%", 52); spH("G%", 52); spH("G.KAZANC", 88)
                    spH("YATIRILAN", 96); spH("NET KAZANC", 96)
                    spH("GIRIS TAR.", 90); spH("GUN", 52)
                    spH("ADET", 72); spH("GIRIS KURU", 86); spH("MEVCUT FY.", 94)
                }
                .background(Color(red: 0.96, green: 0.96, blue: 0.97))

                ForEach(groupedLots, id: \.institutionId) { group in
                    HStack {
                        Text(group.name.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.vertical, 8)
                            .padding(.leading, 12)
                        Spacer()
                    }
                    .background(Color.blue.opacity(0.04))

                    ForEach(group.lots) { lot in
                        let stock = stocks.first(where: { $0.id == lot.stockId })
                        let sItem = stock ?? FinanceStockItem(id: lot.stockId, name: lot.stockId, currentPrice: lot.price, previousPrice: 0, dailyChange: 0, updatedAt: nil, createdAt: nil)
                        specialLotRow(lot)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectStock(sItem)
                            }
                        Divider()
                    }

                    // Group Summary Row
                    specialGroupSummaryRow(group.lots)
                    Divider()

                    Spacer().frame(height: 12)
                }

                // Global Grand Total Row
                if !allActiveLots.isEmpty {
                    specialGrandTotalRow(allActiveLots)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func specialLotRow(_ lot: ProcessedFinanceLot) -> some View {
        let stock = stocks.first(where: { $0.id == lot.stockId })
        let cp = stock?.currentPrice ?? 0
        let pp = stock?.previousPrice ?? 0
        let dailyChangePrice = cp - pp
        let qty = lot.calculatedRemaining
        let invested = qty * lot.price
        let grossP = qty * (cp - lot.price)
        let taxD = grossP > 0 ? (grossP * lot.taxRate / 100) : 0.0
        let netP = grossP - taxD
        let tPerc = lot.price > 0 ? ((cp - lot.price) / lot.price) * 100 : 0.0
        let gPerc = pp > 0 ? ((cp - pp) / pp) * 100 : 0.0
        let dailyP = qty * dailyChangePrice
        let dur = dateFromString(lot.date).map { max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0) } ?? 0
        let stockName = stock?.name ?? lot.stockId

        return HStack(spacing: 0) {
            spTxtLeading(stockName, 80)
            spPct(tPerc, 52); spPct(gPerc, 52)
            spCur(dailyP, 88, col: true)
            spCur(invested, 96, col: false)
            spCurWithTax(netP, taxD, 96)
            spTxt(fmtDateShort(lot.date), 90)
            spTxt("\(dur)", 52)
            spTxt(formatQty(qty), 72)
            spCur(lot.price, 86, col: false)
            spCur(cp, 94, col: false)
        }
        .padding(.vertical, 1)
    }

    private func calculateLotMetrics(_ lots: [ProcessedFinanceLot]) -> (dailyProfit: Double, invested: Double, netProfit: Double, taxDeduction: Double, totalDays: Int, totalQty: Double, avgTPerc: Double, avgGPerc: Double) {
        var dailyProfit = 0.0
        var invested = 0.0
        var netProfit = 0.0
        var taxDeduction = 0.0
        var totalDays = 0
        var totalQty = 0.0
        var totalTPerc = 0.0
        var totalGPerc = 0.0

        for lot in lots {
            let stock = stocks.first(where: { $0.id == lot.stockId })
            let cp = stock?.currentPrice ?? 0
            let pp = stock?.previousPrice ?? 0
            let dChange = stock?.dailyChange ?? 0
            let dailyChangePrice = cp - pp
            let qty = lot.calculatedRemaining
            let inv = qty * lot.price
            let grossP = qty * (cp - lot.price)
            let taxD = grossP > 0 ? (grossP * lot.taxRate / 100) : 0.0
            let netP = grossP - taxD
            let tPerc = lot.price > 0 ? ((cp - lot.price) / lot.price) * 100 : 0.0
            let dailyP = qty * dailyChangePrice
            let dur = dateFromString(lot.date).map { max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0) } ?? 0

            dailyProfit += dailyP
            invested += inv
            netProfit += netP
            taxDeduction += taxD
            totalDays += dur
            totalQty += qty
            totalTPerc += tPerc
            totalGPerc += dChange
        }

        let avgTPerc = lots.count > 0 ? (totalTPerc / Double(lots.count)) : 0.0
        let avgGPerc = lots.count > 0 ? (totalGPerc / Double(lots.count)) : 0.0

        return (dailyProfit, invested, netProfit, taxDeduction, totalDays, totalQty, avgTPerc, avgGPerc)
    }

    @ViewBuilder
    private func specialGroupSummaryRow(_ groupLots: [ProcessedFinanceLot]) -> some View {
        let (gDailyProfit, gInvested, gNetProfit, gTaxDeduction, gTotalDays, gTotalQty, gAvgTPerc, gAvgGPerc) = calculateLotMetrics(groupLots)
        let gAvgDays = groupLots.count > 0 ? Int(round(Double(gTotalDays) / Double(groupLots.count))) : 0

        HStack(spacing: 0) {
            Text("")
                .frame(width: 80, alignment: .leading)
            
            spPctBold(gAvgTPerc, 52)
            spPctBold(gAvgGPerc, 52)

            VStack(alignment: .trailing, spacing: 1) {
                Text("G. KAZANÇ")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.6))
                Text((gDailyProfit >= 0 ? "+" : "") + formatTL(gDailyProfit))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(gDailyProfit >= 0 ? .green : .red)
            }
            .frame(width: 88, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("YATIRILAN")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.6))
                Text(formatTL(gInvested))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
            }
            .frame(width: 96, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("NET KAZANÇ")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.6))
                Text((gNetProfit >= 0 ? "+" : "") + formatTL(gNetProfit))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(gNetProfit >= 0 ? .green : .red)
                if gTaxDeduction > 0 {
                    Text("Stopaj: -" + formatTL(gTaxDeduction))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                }
            }
            .frame(width: 96, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)

            Text("")
                .frame(width: 90)

            HStack(spacing: 2) {
                Text("\(gAvgDays)")
                    .font(.system(size: 11, weight: .bold))
                Text("ort.")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.secondary)
            }
            .frame(width: 52, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)

            Text(formatQty(gTotalQty))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 72, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)

            Text("")
                .frame(width: 86)
            Text("")
                .frame(width: 94)
        }
        .background(Color.gray.opacity(0.08))
    }

    @ViewBuilder
    private func specialGrandTotalRow(_ activeLots: [ProcessedFinanceLot]) -> some View {
        let (totalDailyProfit, totalInvested, totalNetProfit, totalTaxDeduction, totalDaysCount, totalQty, _, _) = calculateLotMetrics(activeLots)
        let globalAvgDays = activeLots.count > 0 ? Int(round(Double(totalDaysCount) / Double(activeLots.count))) : 0

        HStack(spacing: 0) {
            HStack {
                Spacer()
                Text("TOPLAM:")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .frame(width: 132, alignment: .trailing).padding(.trailing, 6)

            Text("")
                .frame(width: 52)

            Text((totalDailyProfit >= 0 ? "+" : "") + formatTL(totalDailyProfit))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(totalDailyProfit >= 0 ? .green : .red)
                .frame(width: 88, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 8)

            Text(formatTL(totalInvested))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 96, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text((totalNetProfit >= 0 ? "+" : "") + formatTL(totalNetProfit))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(totalNetProfit >= 0 ? .green : .red)
                if totalTaxDeduction > 0 {
                    Text("Stopaj: -" + formatTL(totalTaxDeduction))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                }
            }
            .frame(width: 96, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 8)

            Text("")
                .frame(width: 90)

            HStack(spacing: 2) {
                Text("\(globalAvgDays)")
                    .font(.system(size: 11, weight: .bold))
                Text("ort.")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.secondary)
            }
            .frame(width: 52, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 8)

            Text(formatQty(totalQty))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.primary)
                .frame(width: 72, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 8)

            Text("")
                .frame(width: 86)
            Text("")
                .frame(width: 94)
        }
        .background(Color.gray.opacity(0.14))
    }

    private func spHLeading(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            .frame(width: w, alignment: .leading).padding(.vertical, 8).padding(.leading, 12)
    }
    private func spTxtLeading(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).foregroundColor(.blue)
            .frame(width: w, alignment: .leading).padding(.leading, 12).padding(.vertical, 9).lineLimit(1)
    }

    private func spH(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            .frame(width: w, alignment: .trailing).padding(.vertical, 8).padding(.trailing, 6)
    }
    private func spPct(_ v: Double, _ w: CGFloat) -> some View {
        Text(formatPct(v)).font(.system(size: 11, weight: .bold))
            .foregroundColor(v >= 0 ? .green : .red)
            .frame(width: w, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 9)
    }
    private func spPctBold(_ v: Double, _ w: CGFloat) -> some View {
        Text(formatPct(v)).font(.system(size: 11, weight: .bold))
            .foregroundColor(v >= 0 ? .green : .red)
            .frame(width: w, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 6)
    }
    private func spCur(_ v: Double, _ w: CGFloat, col: Bool) -> some View {
        Text((col && v > 0 ? "+" : "") + formatTL(v)).font(.system(size: 11, weight: .bold))
            .foregroundColor(col ? (v >= 0 ? .green : .red) : .primary)
            .frame(width: w, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 9)
    }
    private func spCurWithTax(_ netP: Double, _ taxD: Double, _ w: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text((netP >= 0 ? "+" : "") + formatTL(netP))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(netP >= 0 ? .green : .red)
            if taxD > 0 {
                Text("Stopaj: -" + formatTL(taxD))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))
            }
        }
        .frame(width: w, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 4)
    }
    private func spTxt(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 11)).foregroundColor(.primary)
            .frame(width: w, alignment: .trailing).padding(.trailing, 6).padding(.vertical, 9).lineLimit(1)
    }
}

enum AnalysisLayout: String, CaseIterable {
    case hisseMevcut = "hisse_mevcut"
    case hisseGenel  = "hisse_genel"
    case kurumMevcut = "kurum_mevcut"
    case kurumGenel  = "kurum_genel"

    var title: String {
        switch self {
        case .hisseMevcut: return "Hisse Dagilimi"
        case .hisseGenel: return "Hisse Genel"
        case .kurumMevcut: return "Kurum Dagilimi"
        case .kurumGenel: return "Kurum Genel"
        }
    }
    var isHisse: Bool { self == .hisseMevcut || self == .hisseGenel }
}

struct FinancePortfolioAnalysisSection: View {
    let portfolio: [PortfolioItem]
    let institutions: [FinanceInstitutionItem]
    let instStats: [String: InstitutionStats]
    let processedLots: [ProcessedFinanceLot]
    let onSelectStock: (FinanceStockItem) -> Void

    @State private var layout: AnalysisLayout = .hisseMevcut
    @State private var hoveredIdx: Int? = nil
    @State private var showAll: Bool = false

    private var analysisItems: [AnalysisItem] {
        switch layout {
        case .hisseMevcut:
            return portfolio.enumerated().map { (i, p) in
                AnalysisItem(id: p.id, name: p.name, logo: "",
                             value: p.currentPrice * p.quantity, cost: p.totalCost,
                             profit: p.totalProfit, tax: p.totalTaxDeduction,
                             quantity: p.quantity, dailyGain: p.dailyGain,
                             percentage: 0, isActive: true, color: chartColors[i % chartColors.count])
            }.filter { $0.value > 0 }.sorted { $0.value > $1.value }

        case .hisseGenel:
            let uniqueIds = Array(Set(processedLots.map { $0.stockId })).filter { !$0.isEmpty }
            return uniqueIds.enumerated().compactMap { (i, sid) -> AnalysisItem? in
                let pItem = portfolio.first(where: { $0.id == sid })
                let saleLots = processedLots.filter { $0.stockId == sid && !$0.type.hasPrefix("AL") }
                let realizedProfit = saleLots.reduce(0.0) { $0 + $1.totalProfit }
                let realizedTax = saleLots.reduce(0.0) { $0 + $1.calculatedTaxDeduction }
                let totalProfit = realizedProfit + (pItem?.totalProfit ?? 0)
                let totalTax = realizedTax + (pItem?.totalTaxDeduction ?? 0)
                let qty = pItem?.quantity ?? 0
                let val = (pItem?.currentPrice ?? 0) * qty
                return AnalysisItem(id: sid,
                    name: FinanceOperationsViewModel.shared.stocks.first(where: { $0.id == sid })?.name ?? sid,
                    logo: "", value: val, cost: pItem?.totalCost ?? 0,
                    profit: totalProfit, tax: totalTax, quantity: qty,
                    dailyGain: pItem?.dailyGain ?? 0, percentage: 0,
                    isActive: qty > 0, color: chartColors[i % chartColors.count])
            }.sorted { item1, item2 in
                if item1.isActive != item2.isActive {
                    return item1.isActive
                }
                if item1.isActive {
                    return item1.value > item2.value
                } else {
                    let date1 = processedLots.filter { $0.stockId == item1.id && !$0.type.hasPrefix("AL") }.map { $0.date }.max() ?? ""
                    let date2 = processedLots.filter { $0.stockId == item2.id && !$0.type.hasPrefix("AL") }.map { $0.date }.max() ?? ""
                    return date1 > date2
                }
            }

        case .kurumMevcut, .kurumGenel:
            let isGenel = layout == .kurumGenel
            return institutions.enumerated().compactMap { (i, inst) -> AnalysisItem? in
                let stats = instStats[inst.id] ?? InstitutionStats()
                let profit = isGenel ? (stats.unrealizedNet + stats.realizedNet) : stats.unrealizedNet
                let tax = isGenel
                    ? ((stats.unrealizedGross - stats.unrealizedNet) + (stats.realizedGross - stats.realizedNet))
                    : (stats.unrealizedGross - stats.unrealizedNet)
                guard stats.currentValue > 0 || stats.totalInvestment > 0 || (isGenel && abs(profit) > 0) else { return nil }
                return AnalysisItem(id: inst.id, name: inst.name, logo: inst.logo,
                                     value: stats.currentValue, cost: stats.totalInvestment,
                                     profit: profit, tax: tax, quantity: 0,
                                     dailyGain: stats.dailyGain, percentage: 0,
                                     isActive: stats.currentValue > 0, color: chartColors[i % chartColors.count])
            }.sorted { $0.value > $1.value }
        }
    }

    private var totalValue: Double { analysisItems.reduce(0) { $0 + $1.value } }
    private var totalCost: Double { analysisItems.reduce(0) { $0 + $1.cost } }
    private var totalProfit: Double { analysisItems.reduce(0) { $0 + $1.profit } }
    private var totalTax: Double { analysisItems.reduce(0) { $0 + $1.tax } }
    private var profitPct: Double { totalCost > 0 ? (totalProfit / totalCost) * 100 : 0 }

    private var itemsWithPct: [AnalysisItem] {
        let total = analysisItems.filter { $0.value > 0 }.reduce(0.0) { $0 + $1.value }
        return analysisItems.map { item in
            var copy = item
            copy.percentage = total > 0 ? (item.value / total) * 100 : 0
            return copy
        }
    }

    private var displayedItems: [AnalysisItem] {
        let items = itemsWithPct
        if layout == .hisseGenel && !showAll { return Array(items.prefix(10)) }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portfoy Analizi").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Mevcut hisse dagilimlar\u{131} ve kurum bazl\u{131} finansal ozetler")
                    .font(.system(size: 13)).foregroundColor(.secondary)
            }.padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AnalysisLayout.allCases, id: \.rawValue) { l in
                        Button(action: { layout = l; hoveredIdx = nil }) {
                            Text(l.title).font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(layout == l ? Color.blue : Color.white)
                                .foregroundColor(layout == l ? .white : .secondary)
                                .cornerRadius(20)
                                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
                        }
                    }
                }.padding(.horizontal, 16)
            }

            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Text(layout.isHisse ? (layout == .hisseMevcut ? "HISSE DAGILIMI (MEVCUT)" : "HISSE DAGILIMI (GENEL)") :
                         (layout == .kurumMevcut ? "KURUMSAL DAGILIM (MEVCUT)" : "KURUMSAL DAGILIM (GENEL)"))
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if itemsWithPct.filter({ $0.value > 0 }).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.pie").font(.system(size: 28)).foregroundColor(.gray.opacity(0.3))
                            Text("Veri bulunamad\u{131}").font(.system(size: 12)).foregroundColor(.secondary)
                        }.frame(height: 150)
                    } else {
                        DonutChartView(items: itemsWithPct.filter { $0.value > 0 },
                                       totalValue: totalValue, totalProfit: totalProfit,
                                       totalTax: totalTax, profitPct: profitPct,
                                       hoveredIdx: $hoveredIdx)
                        .frame(height: 160)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(layout.isHisse ? (layout == .hisseMevcut ? "HISSE DETAYLARI (MEVCUT)" : "HISSE DETAYLARI (GENEL)") :
                             (layout == .kurumMevcut ? "KURUMSAL OZETLER (MEVCUT)" : "KURUMSAL OZETLER (GENEL)"))
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        Spacer()
                        Text("\(analysisItems.count)")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.blue).cornerRadius(10)
                    }

                    if displayedItems.isEmpty {
                        Text("Veri bulunamad\u{131}.").font(.system(size: 13)).foregroundColor(.secondary).padding(.vertical, 12)
                    } else {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Text(layout.isHisse ? "HISSE" : "KURUM").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                if layout.isHisse {
                                    Text("ADET").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 58, alignment: .trailing)
                                } else {
                                    Text("GUNLUK").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 58, alignment: .trailing)
                                }
                                Text("PAY").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 44, alignment: .trailing)
                                Text("NET K/Z").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).frame(width: 105, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .padding(.bottom, 2)
                            Divider()

                            ForEach(Array(displayedItems.enumerated()), id: \.1.id) { i, item in
                                analysisRow(item, idx: i)
                                    .contentShape(Rectangle())
                            }

                            if layout == .hisseGenel && itemsWithPct.count > 10 {
                                Button(action: { showAll.toggle() }) {
                                    Text(showAll ? "Daha Az Goster" : "Devamini Gor (\(itemsWithPct.count - 10) daha)")
                                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)
                                        .padding(.top, 8)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                summaryTile("TOPLAM YATIRIM", formatTL(totalCost), Color.secondary, .primary)
                summaryTile("PORTFOY DEGERI", formatTL(totalValue - totalTax), Color.blue, .blue)
                summaryTile(
                    "NET KAR/ZARAR",
                    (totalProfit >= 0 ? "+" : "") + formatTL(totalProfit),
                    totalProfit >= 0 ? Color.green : Color.red,
                    totalProfit >= 0 ? .green : .red,
                    sub: "Stopaj: -" + formatTL(totalTax, decimals: 2)
                )
            }
            .padding(.horizontal, 16)
        }
    }

    private func analysisRow(_ item: AnalysisItem, idx: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 10, height: 10)
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !item.isActive {
                    Text("SATILDI").font(.system(size: 8, weight: .bold)).foregroundColor(.orange)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12)).cornerRadius(3)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if layout.isHisse {
                Text(item.quantity > 0 ? formatQty(item.quantity) + " lot" : "-")
                    .font(.system(size: 10)).foregroundColor(.secondary).frame(width: 58, alignment: .trailing)
            } else {
                Text((item.dailyGain >= 0 ? "+" : "") + formatTL(item.dailyGain))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(item.dailyGain >= 0 ? .green : .red)
                    .frame(width: 58, alignment: .trailing)
            }

            Text(String(format: "%.1f%%", item.percentage))
                .font(.system(size: 10, weight: .medium)).foregroundColor(.secondary).frame(width: 44, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text((item.profit >= 0 ? "+" : "") + formatTL(item.profit))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(item.profit >= 0 ? .green : .red)
                    .lineLimit(1)
                Text("Stopaj: -" + formatTL(item.tax, decimals: 2)).font(.system(size: 8)).foregroundColor(.red.opacity(0.7))
            }.frame(width: 105, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .background(hoveredIdx == idx ? Color.blue.opacity(0.04) : Color.clear)
    }

    private func summaryTile(_ label: String, _ value: String, _ accent: Color, _ valColor: Color, sub: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .bold)).foregroundColor(valColor).lineLimit(1).minimumScaleFactor(0.7)
            if let sub = sub {
                Text(sub).font(.system(size: 8)).foregroundColor(.red.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
    }
}

// MARK: - Donut Chart View

struct DonutChartView: View {
    let items: [AnalysisItem]
    let totalValue: Double
    let totalProfit: Double
    let totalTax: Double
    let profitPct: Double
    @Binding var hoveredIdx: Int?

    var body: some View {
        ZStack {
            ForEach(Array(buildSegments().enumerated()), id: \.0) { i, seg in
                Circle()
                    .trim(from: seg.start, to: seg.end)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: hoveredIdx == i ? 20 : 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: hoveredIdx)
                    .onTapGesture { hoveredIdx = hoveredIdx == i ? nil : i }
            }

            VStack(spacing: 2) {
                if let idx = hoveredIdx, idx < items.count {
                    let item = items[idx]
                    Text(item.name).font(.system(size: 10, weight: .bold)).lineLimit(1).multilineTextAlignment(.center)
                    Text(String(format: "%.1f%%", item.percentage)).font(.system(size: 9)).foregroundColor(.secondary)
                    Text(formatTL(item.value)).font(.system(size: 11, weight: .bold)).foregroundColor(.blue).lineLimit(1).minimumScaleFactor(0.7)
                    Text("-" + formatTL(item.tax, decimals: 2)).font(.system(size: 8)).foregroundColor(.red.opacity(0.8))
                } else {
                    Text("TOPLAM DEGER").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                    Text(formatTL(totalValue - totalTax)).font(.system(size: 11, weight: .bold)).foregroundColor(.primary).lineLimit(1).minimumScaleFactor(0.7)
                    Text((totalProfit >= 0 ? "+" : "") + formatPct(profitPct))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(totalProfit >= 0 ? .green : .red)
                    Text("-" + formatTL(totalTax, decimals: 2)).font(.system(size: 8)).foregroundColor(.red.opacity(0.8))
                }
            }
            .frame(width: 120)
            .padding(4)
        }
    }

    struct Segment { var start: CGFloat; var end: CGFloat; var color: Color }

    private func buildSegments() -> [Segment] {
        let total = items.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [] }
        var offset: CGFloat = 0
        return items.map { item in
            let frac = CGFloat(item.value / total)
            let seg = Segment(start: offset, end: offset + frac, color: item.color)
            offset += frac
            return seg
        }
    }
}

// MARK: - Section 4: Finans Islemleri

struct FinanceTransactionsSectionView: View {
    let filteredLots: [ProcessedFinanceLot]
    let institutions: [FinanceInstitutionItem]
    let stocks: [FinanceStockItem]
    @Binding var filterInstitutionId: String
    @Binding var limitCount: Int
    let onAdd: () -> Void
    let onEdit: (ProcessedFinanceLot) -> Void
    let onDelete: (ProcessedFinanceLot) -> Void

    @State private var lotToDelete: ProcessedFinanceLot? = nil

    private var visibleLots: [ProcessedFinanceLot] { Array(filteredLots.prefix(limitCount)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Finans Islemleri").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onAdd) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Yeni").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.blue).foregroundColor(.white).cornerRadius(10)
                }
            }.padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill("all", "Tumu")
                    ForEach(institutions) { inst in filterPill(inst.id, inst.name) }
                }.padding(.horizontal, 16)
            }

            if visibleLots.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundColor(.gray.opacity(0.3))
                        Text("Islem bulunamad\u{131}.").font(.system(size: 14)).foregroundColor(.secondary)
                    }.padding(.vertical, 24)
                    Spacer()
                }
            } else {
                List {
                    ForEach(visibleLots) { lot in
                        TxRow(lot: lot,
                               institution: institutions.first(where: { $0.id == lot.institutionId }),
                               stock: stocks.first(where: { $0.id == lot.stockId }))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.white)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                lotToDelete = lot
                            } label: {
                                Label("Sil", systemImage: "trash")
                            }
                            
                            Button {
                                onEdit(lot)
                            } label: {
                                Label("Duzenle", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: CGFloat(visibleLots.count * 64))
                .background(Color.white)
                .cornerRadius(14)
                .alert("Islemi Sil", isPresented: Binding(
                    get: { lotToDelete != nil },
                    set: { if !$0 { lotToDelete = nil } }
                )) {
                    Button("Iptal", role: .cancel) { lotToDelete = nil }
                    Button("Sil", role: .destructive) {
                        if let lot = lotToDelete {
                            onDelete(lot)
                        }
                        lotToDelete = nil
                    }
                } message: {
                    Text("Bu islemi silmek istediginize emin misiniz?")
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("LIMIT:").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        ForEach([5, 10, 20, 50, 100], id: \.self) { v in limitBtn(v, "\(v)") }
                        limitBtn(filteredLots.count, "Hepsi (\(filteredLots.count))")
                    }.padding(.horizontal, 16)
                }.padding(.top, 4)
            }
        }
    }

    private func filterPill(_ id: String, _ name: String) -> some View {
        Button(action: { filterInstitutionId = id }) {
            Text(name)
                .font(.system(size: 13, weight: filterInstitutionId == id ? .bold : .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(filterInstitutionId == id ? Color.blue : Color.white)
                .foregroundColor(filterInstitutionId == id ? .white : .secondary)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        }
    }

    private func limitBtn(_ val: Int, _ label: String) -> some View {
        Button(action: { limitCount = val }) {
            Text(label)
                .font(.system(size: 10, weight: limitCount == val ? .bold : .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(limitCount == val ? Color.blue.opacity(0.12) : Color.clear)
                .foregroundColor(limitCount == val ? .blue : .secondary).cornerRadius(5)
        }
    }
}

struct TxRow: View {
    let lot: ProcessedFinanceLot
    let institution: FinanceInstitutionItem?
    let stock: FinanceStockItem?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                let isAlis = lot.type.hasPrefix("AL")
                Text(lot.type)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(isAlis ? Color.green.opacity(0.14) : Color.red.opacity(0.14))
                    .foregroundColor(isAlis ? .green : .red).cornerRadius(6)
                Text(fmtDate(lot.date)).font(.system(size: 11)).foregroundColor(.secondary)
            }.frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(stock?.name ?? "-").font(.system(size: 14, weight: .bold)).foregroundColor(.blue).lineLimit(1)
                Text(institution?.name ?? "-").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    Text(formatQty(lot.quantity) + " adet").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("@").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(formatTL(lot.price, decimals: 4)).font(.system(size: 12, weight: .semibold))
                }
                if lot.taxRate > 0 {
                    Text("Stopaj: %" + formatPctNoSymbol(lot.taxRate)).font(.system(size: 11)).foregroundColor(.orange)
                }
                if !lot.type.hasPrefix("AL") && lot.totalProfit != 0 {
                    Text((lot.totalProfit >= 0 ? "+" : "") + formatTL(lot.totalProfit))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(lot.totalProfit >= 0 ? .green : .red)
                } else if lot.type.hasPrefix("AL") && lot.calculatedRemaining != lot.quantity {
                    Text("Kalan: " + formatQty(lot.calculatedRemaining))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Add/Edit Sheet

struct FinanceAddEditSheet: View {
    @ObservedObject var viewModel: FinanceOperationsViewModel
    let transaction: FinanceTransactionItem?
    let institutions: [FinanceInstitutionItem]
    let stocks: [FinanceStockItem]
    let portfolio: [PortfolioItem]
    let allTransactions: [FinanceTransactionItem]
    let onSave: (String, String, String, Double, Double, Double, String) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var selectedInstId: String = ""
    @State private var selectedStockId: String = ""
    @State private var isAddingNewStock: Bool = false
    @State private var newStockSymbol: String = ""
    @State private var type: String = "ALIŞ"
    @State private var quantityStr: String = ""
    @State private var priceStr: String = ""
    @State private var taxRateStr: String = "0"
    @State private var date: Date = Date()
    @State private var showStockPrice: Bool = false

    private var isEditing: Bool { transaction != nil }
    private var selectedStock: FinanceStockItem? { stocks.first(where: { $0.id == selectedStockId }) }
    private var parsedQty: Double? { parseInput(quantityStr) }
    private var parsedPrice: Double? { parseInput(priceStr) }
    private var parsedTax: Double { parseInput(taxRateStr) ?? 0 }

    private var sortedStocks: [FinanceStockItem] {
        let activeIds = Set(portfolio.map { $0.id })
        let active = stocks.filter { activeIds.contains($0.id) }.sorted(by: { $0.name < $1.name })
        let others = stocks.filter { !activeIds.contains($0.id) }.sorted(by: { $0.name < $1.name })
        return active + others
    }

    private var maxSellableQuantity: Double {
        let targetId = isAddingNewStock ? newStockSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : selectedStockId
        guard !targetId.isEmpty, !selectedInstId.isEmpty else { return 0 }
        let editingId = transaction?.id
        let sortedTrans = allTransactions.filter { !$0.deleted && $0.id != editingId }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let isAlis0 = $0.type.uppercased().hasPrefix("AL")
            let isAlis1 = $1.type.uppercased().hasPrefix("AL")
            if isAlis0 != isAlis1 { return isAlis0 }
            return ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast)
        }
        
        var pool: Double = 0
        for t in sortedTrans {
            if t.stockId == targetId && t.institutionId == selectedInstId {
                if t.type.uppercased().hasPrefix("AL") {
                    pool += t.quantity
                } else {
                    pool = max(0, pool - t.quantity)
                }
            }
        }
        return pool
    }

    private func calculateSellTaxAndProfit(stockId: String, instId: String, qty: Double, price: Double, formTaxRate: Double) -> (tax: Double, profit: Double) {
        let editingId = transaction?.id
        let sortedTrans = allTransactions.filter { !$0.deleted && $0.id != editingId }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let isAlis0 = $0.type.uppercased().hasPrefix("AL")
            let isAlis1 = $1.type.uppercased().hasPrefix("AL")
            if isAlis0 != isAlis1 { return isAlis0 }
            return ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast)
        }
        
        struct TempLot { var remaining: Double; var price: Double; var taxRate: Double }
        var buyLots: [TempLot] = []
        
        for t in sortedTrans {
            if t.stockId == stockId && (instId.isEmpty || t.institutionId == instId) {
                if t.type.uppercased().hasPrefix("AL") {
                    buyLots.append(TempLot(remaining: t.quantity, price: t.price, taxRate: t.taxRate))
                } else {
                    var rem = t.quantity
                    for i in 0..<buyLots.count {
                        if rem <= 0 { break }
                        if buyLots[i].remaining <= 0 { continue }
                        let sell = min(buyLots[i].remaining, rem)
                        buyLots[i].remaining -= sell
                        rem -= sell
                    }
                }
            }
        }
        
        var remainingToSell = qty
        var totalTax = 0.0
        var totalGrossProfit = 0.0
        
        for lot in buyLots {
            if remainingToSell <= 0 { break }
            if lot.remaining <= 0 { continue }
            let sellCount = min(lot.remaining, remainingToSell)
            let profit = (price - lot.price) * sellCount
            totalGrossProfit += profit
            if profit > 0 && lot.taxRate > 0 {
                totalTax += profit * (lot.taxRate / 100.0)
            }
            remainingToSell -= sellCount
        }
        
        if totalTax == 0 && formTaxRate > 0 {
            if totalGrossProfit > 0 {
                totalTax = totalGrossProfit * (formTaxRate / 100.0)
            } else {
                totalTax = (qty * price) * (formTaxRate / 100.0)
            }
        }
        
        return (tax: totalTax, profit: totalGrossProfit)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("İşlem Bilgileri") {
                    Picker("Aracı Kurum", selection: $selectedInstId) {
                        Text("Seçin...").tag("")
                        ForEach(institutions) { inst in Text(inst.name).tag(inst.id) }
                    }.pickerStyle(.menu)

                    if !isAddingNewStock {
                        Picker("Hisse", selection: $selectedStockId) {
                            Text("Seçin...").tag("")
                            ForEach(sortedStocks) { s in
                                let isMevcut = portfolio.contains(where: { $0.id == s.id })
                                Text(s.name + (isMevcut ? " (Mevcut)" : "")).tag(s.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedStockId) { newId in
                            if let s = stocks.first(where: { $0.id == newId }), s.currentPrice > 0 {
                                priceStr = fmtN(s.currentPrice, dec: 4)
                                showStockPrice = true
                            } else {
                                showStockPrice = false
                            }
                        }

                        Button(action: {
                            isAddingNewStock = true
                            selectedStockId = ""
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Yeni Hisse / Varlık Ekle")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.blue)
                        }
                        .padding(.vertical, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Yeni Hisse / Varlık Kodu")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    isAddingNewStock = false
                                    newStockSymbol = ""
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "list.bullet")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Listeden Seç")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                    .foregroundColor(.blue)
                                }
                            }
                            
                            TextField("Örn: THYAO, GARAN, FON...", text: $newStockSymbol)
                                .font(.system(size: 15, weight: .semibold))
                                .autocapitalization(.allCharacters)
                                .disableAutocorrection(true)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 2)
                    }

                    if let s = selectedStock, s.currentPrice > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Mevcut Fiyat")
                                    .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                                Spacer()
                                Text(formatTL(s.currentPrice, decimals: 4))
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(.blue)
                            }
                            if s.previousPrice > 0 {
                                let dailyChange = s.dailyChange
                                HStack(spacing: 4) {
                                    Image(systemName: dailyChange >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(dailyChange >= 0 ? .green : .red)
                                    Text(formatPct(dailyChange) + " günlük").font(.system(size: 11)).foregroundColor(dailyChange >= 0 ? .green : .red)
                                    Spacer()
                                    Button(action: { priceStr = fmtN(s.currentPrice, dec: 4) }) {
                                        Text("Fiyatı Kullan").font(.system(size: 11, weight: .semibold)).foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.blue.opacity(0.04))
                    }

                    Picker("İşlem Türü", selection: $type) {
                        Text("ALIŞ").tag("ALIŞ")
                        Text("SATIŞ").tag("SATIŞ")
                    }.pickerStyle(.segmented)

                    DatePicker("Tarih", selection: $date, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "tr_TR"))
                }

                Section("Miktar ve Fiyat") {
                    HStack(spacing: 8) {
                        Text("Adet").foregroundColor(.secondary)
                        Spacer()
                        if type.uppercased().hasPrefix("SAT") && maxSellableQuantity > 0 {
                            Button(action: {
                                let maxQty = maxSellableQuantity
                                if maxQty.truncatingRemainder(dividingBy: 1) == 0 {
                                    quantityStr = "\(Int(maxQty))"
                                } else {
                                    quantityStr = fmtN(maxQty, dec: 4)
                                }
                            }) {
                                HStack(spacing: 3) {
                                    Text("MAX")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("(\(formatQty(maxSellableQuantity)))")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("0", text: $quantityStr)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 60)
                    }
                    HStack {
                        Text("İşlem Fiyatı (TL)").foregroundColor(.secondary)
                        Spacer()
                        TextField("0,0000", text: $priceStr).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if type.uppercased().hasPrefix("AL") {
                        HStack {
                            Text("Stopaj (%)").foregroundColor(.secondary)
                            Spacer()
                            TextField("0", text: $taxRateStr).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                }

                if let qty = parsedQty, let prc = parsedPrice, qty > 0 && prc > 0 {
                    Section("Ozet") {
                        let isAlis = type.uppercased().hasPrefix("AL")
                        if isAlis {
                            HStack {
                                Text("Toplam Tutar")
                                Spacer()
                                Text(formatTL(qty * prc)).fontWeight(.bold)
                            }
                            if parsedTax > 0 {
                                HStack {
                                    Text("Gelecek Stopaj Oran\u{131}")
                                    Spacer()
                                    Text("%" + formatPctNoSymbol(parsedTax)).foregroundColor(.orange).fontWeight(.medium)
                                }
                            }
                            if let s = selectedStock, s.currentPrice > 0 && prc != s.currentPrice {
                                let diff = prc - s.currentPrice
                                HStack {
                                    Text("Piyasa Fark\u{131}").foregroundColor(.orange)
                                    Spacer()
                                    Text((diff >= 0 ? "+" : "") + formatTL(diff, decimals: 4)).foregroundColor(.orange)
                                }
                            }
                        } else {
                            let grossTotal = qty * prc
                            let (estimatedTax, estimatedProfit) = calculateSellTaxAndProfit(
                                stockId: selectedStockId,
                                instId: selectedInstId,
                                qty: qty,
                                price: prc,
                                formTaxRate: parsedTax
                            )
                            
                            HStack {
                                Text("Toplam Sat\u{131}\u{15F} Tutar\u{131}")
                                Spacer()
                                Text(formatTL(grossTotal)).fontWeight(.bold)
                            }
                            
                            if estimatedProfit > 0 {
                                HStack {
                                    Text("Tahmini Br\u{FC}t Kazanc\u{131}")
                                    Spacer()
                                    Text("+" + formatTL(estimatedProfit)).foregroundColor(.blue).fontWeight(.semibold)
                                }
                            }
                            
                            if estimatedTax > 0 {
                                HStack {
                                    Text("Stopaj Kesintisi")
                                    Spacer()
                                    Text("-" + formatTL(estimatedTax, decimals: 2)).foregroundColor(.red).fontWeight(.bold)
                                }
                            }
                            
                            let netAmount = grossTotal - estimatedTax
                            HStack {
                                Text("Net Elime Ge\u{E7}ecek Tutar")
                                Spacer()
                                Text(formatTL(netAmount)).fontWeight(.bold).foregroundColor(.green)
                            }
                            
                            if let s = selectedStock, s.currentPrice > 0 && prc != s.currentPrice {
                                let diff = prc - s.currentPrice
                                HStack {
                                    Text("Piyasa Fark\u{131}").foregroundColor(.orange)
                                    Spacer()
                                    Text((diff >= 0 ? "+" : "") + formatTL(diff, decimals: 4)).foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Islemi Duzenle" : "Yeni Islem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Iptal") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        guard !selectedInstId.isEmpty,
                              let qty = parsedQty, let prc = parsedPrice, qty > 0, prc > 0 else { return }
                        
                        let targetStockId: String
                        if isAddingNewStock {
                            let cleanSymbol = newStockSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            guard !cleanSymbol.isEmpty else { return }
                            targetStockId = viewModel.ensureStockExists(symbolOrName: cleanSymbol, price: prc)
                        } else {
                            guard !selectedStockId.isEmpty else { return }
                            targetStockId = selectedStockId
                        }

                        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                        onSave(selectedInstId, targetStockId, type, qty, prc, parsedTax, df.string(from: date))
                        dismiss()
                    }.fontWeight(.bold)
                }
            }
            .onAppear {
                if let t = transaction {
                    selectedInstId = t.institutionId; selectedStockId = t.stockId
                    type = t.type.uppercased().hasPrefix("AL") ? "ALIŞ" : "SATIŞ"
                    quantityStr = fmtN(t.quantity, dec: 4)
                    priceStr = fmtN(t.price, dec: 4); taxRateStr = fmtN(t.taxRate, dec: 2)
                    if let d = dateFromString(t.date) { date = d }
                } else if !institutions.isEmpty { selectedInstId = institutions[0].id }
            }
        }
    }

    private func parseInput(_ s: String) -> Double? {
        let clean = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        return Double(clean) ?? Double(s)
    }

    private func fmtN(_ v: Double, dec: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "tr_TR")
        f.minimumFractionDigits = 0; f.maximumFractionDigits = dec
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - Hisse Fiyatı Düzenleme Modalı

struct FinanceStockPriceEditSheet: View {
    let stock: FinanceStockItem
    let onSave: (Double) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var priceStr: String = ""

    private var changePercentage: Double? {
        let clean = priceStr.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        guard let newPrice = Double(clean) ?? Double(priceStr), stock.currentPrice > 0 else { return nil }
        return ((newPrice - stock.currentPrice) / stock.currentPrice) * 100
    }

    private func formatChangePct(_ val: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formatted = formatter.string(from: NSNumber(value: val)) ?? "0,00"
        return val >= 0 ? "+\(formatted)%" : "\(formatted)%"
    }

    private func formatTL(_ val: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return (formatter.string(from: NSNumber(value: val)) ?? "\(val)") + " TL"
    }

    private func pasteFromClipboard() {
        if let clipboardText = UIPasteboard.general.string {
            let clean = clipboardText.replacingOccurrences(of: "[^0-9,.]", with: "", options: .regularExpression)
            if !clean.isEmpty {
                priceStr = clean
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Hisse Kodu")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(stock.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        Text("Önceki Fiyat")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTL(stock.currentPrice))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 4)

                    if stock.previousPrice > 0 {
                        HStack {
                            Text("Önceki Gün Fiyatı")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTL(stock.previousPrice))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if let updatedAt = stock.updatedAt {
                        HStack {
                            Text("Son Güncelleme")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(trDateFormatter.string(from: updatedAt))
                                .font(.system(size: 14))
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section("GÜNCEL FİYAT") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Fiyat (TL)")
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("0,00", text: $priceStr)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        
                        if let pct = changePercentage {
                            HStack {
                                Text("Değişim Oranı")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: pct >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                        .font(.system(size: 10))
                                    Text(formatChangePct(pct))
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(pct >= 0 ? .green : .red)
                            }
                        }

                        Button(action: pasteFromClipboard) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Panodan Yapıştır")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Hisse Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        let clean = priceStr.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                        if let newPrice = Double(clean) ?? Double(priceStr), newPrice > 0 {
                            onSave(newPrice)
                            dismiss()
                        }
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                let f = NumberFormatter()
                f.numberStyle = .decimal
                f.locale = Locale(identifier: "tr_TR")
                f.minimumFractionDigits = 0
                f.maximumFractionDigits = 4
                priceStr = f.string(from: NSNumber(value: stock.currentPrice)) ?? "\(stock.currentPrice)"
            }
        }
    }
}

// MARK: - Finans İşlemleri Filtreleme ve Sıralama Modalı

struct FinanceFilterSheet: View {
    @Binding var filterInstId: String
    @Binding var filterStockId: String
    @Binding var filterTxType: String
    @Binding var sortOrder: String
    let institutions: [FinanceInstitutionItem]
    let stocks: [FinanceStockItem]
    let portfolio: [PortfolioItem]
    @Environment(\.dismiss) var dismiss

    private var activeStockIds: Set<String> {
        Set(portfolio.filter { $0.quantity > 0 }.map { $0.id })
    }

    private var activeStocks: [FinanceStockItem] {
        stocks.filter { activeStockIds.contains($0.id) }.sorted(by: { $0.name < $1.name })
    }

    private var otherStocks: [FinanceStockItem] {
        stocks.filter { !activeStockIds.contains($0.id) }.sorted(by: { $0.name < $1.name })
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Aracı Kurum Filtresi") {
                    Picker("Aracı Kurum", selection: $filterInstId) {
                        Text("Tüm Kurumlar").tag("all")
                        ForEach(institutions) { inst in
                            Text(inst.name).tag(inst.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Hisse / Varlık Filtresi") {
                    Picker("Hisse Seçin", selection: $filterStockId) {
                        Text("Tüm Hisseler").tag("all")
                        
                        if !activeStocks.isEmpty {
                            Section("★ MEVCUT PORTFÖYDEKİ HİSSELER") {
                                ForEach(activeStocks) { s in
                                    Text("★ \(s.name) (Mevcut)").tag(s.id)
                                }
                            }
                        }
                        
                        if !otherStocks.isEmpty {
                            Section("DİĞER HİSSELER") {
                                ForEach(otherStocks) { s in
                                    Text(s.name).tag(s.id)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("İşlem Türü") {
                    Picker("İşlem Türü", selection: $filterTxType) {
                        Text("Tümü").tag("all")
                        Text("ALIŞ").tag("ALIŞ")
                        Text("SATIŞ").tag("SATIŞ")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tarih Sıralaması") {
                    Picker("Sıralama", selection: $sortOrder) {
                        Text("Yeniden Eskiye (En Yeni Üstte)").tag("newest")
                        Text("Eskiden Yeniye (En Eski Üstte)").tag("oldest")
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Button(role: .destructive, action: {
                        filterInstId = "all"
                        filterStockId = "all"
                        filterTxType = "all"
                        sortOrder = "newest"
                    }) {
                        HStack {
                            Spacer()
                            Text("Filtreleri Sıfırla")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Filtrele & Sırala")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Uygula") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
