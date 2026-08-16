import WidgetKit
import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

// MARK: - Data Models
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

// Helper to get keychain group
func getKeychainGroup() -> String? {
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

import AppIntents

@available(iOS 16.0, *)
enum NoteColorOption: String, AppEnum {
    case all = "Tümü"
    case red = "Kırmızı"
    case green = "Yeşil"
    case yellow = "Sarı"
    case blue = "Mavi"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Renk Seçimi"
    static var caseDisplayRepresentations: [NoteColorOption: DisplayRepresentation] = [
        .all: "Tümü",
        .red: "Kırmızı",
        .green: "Yeşil",
        .yellow: "Sarı",
        .blue: "Mavi"
    ]
}

@available(iOS 16.0, *)
struct NoteTagEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Etiket"
    static var defaultQuery = NoteTagQuery()
    
    var id: String
    var title: String
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(stringLiteral: title)
    }
}

@available(iOS 16.0, *)
struct NoteTagQuery: EntityQuery {
    func entities(for identifiers: [NoteTagEntity.ID]) async throws -> [NoteTagEntity] {
        return identifiers.map { NoteTagEntity(id: $0, title: $0) }
    }
    
    func suggestedEntities() async throws -> [NoteTagEntity] {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        guard let user = Auth.auth().currentUser else { return [] }
        let db = Firestore.firestore()
        var allTags = Set<String>()
        do {
            let snapshot = try await db.collection("users").document(user.uid).collection("notes").getDocuments()
            for doc in snapshot.documents {
                if let tags = doc.data()["tags"] as? [String] {
                    tags.forEach { allTags.insert($0) }
                }
            }
        } catch {
            print("Tag query error: \(error)")
        }
        return allTags.sorted().map { NoteTagEntity(id: $0, title: $0) }
    }
}

@available(iOS 16.0, *)
struct NoteFilterIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Filtre Ayarları"
    static var description = IntentDescription("Araç takımında görünecek notları filtreleyin.")

    @Parameter(title: "Renkler", default: [.all])
    var selectedColors: [NoteColorOption]

    @Parameter(title: "Etiketler (Opsiyonel)", default: [])
    var selectedTags: [NoteTagEntity]

    @Parameter(title: "Tatil Günlerini Göster", default: true)
    var showHolidays: Bool
}

// MARK: - Provider
@available(iOS 16.0, *)
struct Provider: AppIntentTimelineProvider {
    
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), todayNotes: [], futureNotes: [], isLoggedIn: true, configuration: NoteFilterIntent())
    }

    func snapshot(for configuration: NoteFilterIntent, in context: Context) async -> SimpleEntry {
        return SimpleEntry(date: Date(), todayNotes: [], futureNotes: [], isLoggedIn: true, configuration: configuration)
    }

    func timeline(for configuration: NoteFilterIntent, in context: Context) async -> Timeline<SimpleEntry> {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        
        guard let user = Auth.auth().currentUser else {
            let entry = SimpleEntry(date: Date(), todayNotes: [], futureNotes: [], isLoggedIn: false, configuration: configuration)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
        
        let db = Firestore.firestore()
        do {
            let snapshot = try await db.collection("users").document(user.uid).collection("notes")
                .whereField("date", isGreaterThanOrEqualTo: "2000-01-01")
                .getDocuments(source: .server)
            return processSnapshot(snapshot, configuration: configuration)
        } catch {
            do {
                let cacheSnap = try await db.collection("users").document(user.uid).collection("notes")
                    .whereField("date", isGreaterThanOrEqualTo: "2000-01-01")
                    .getDocuments(source: .cache)
                return processSnapshot(cacheSnap, configuration: configuration)
            } catch {
                let entry = SimpleEntry(date: Date(), todayNotes: [], futureNotes: [], isLoggedIn: true, configuration: configuration)
                return Timeline(entries: [entry], policy: .after(nextUpdate))
            }
        }
    }
    
    private func processSnapshot(_ snapshot: QuerySnapshot?, configuration: NoteFilterIntent) -> Timeline<SimpleEntry> {
        var allNotes: [WidgetNote] = []
        
        if let docs = snapshot?.documents {
            for doc in docs {
                do {
                    let note = try doc.data(as: WidgetNote.self)
                    if note.deleted != true {
                        // Filter Holidays
                        if note.itemType == "holiday" && !configuration.showHolidays {
                            continue
                        }
                        
                        // Filter by Colors (Multiple)
                        let selectedColors = configuration.selectedColors
                        if !selectedColors.isEmpty && !selectedColors.contains(.all) {
                            let noteColor = (note.color ?? "").lowercased()
                            var matchesColor = false
                            for colorOption in selectedColors {
                                switch colorOption {
                                case .red: if noteColor == "red" { matchesColor = true }
                                case .green: if noteColor == "green" { matchesColor = true }
                                case .yellow: if noteColor == "yellow" { matchesColor = true }
                                case .blue: if noteColor == "blue" || noteColor == "" { matchesColor = true }
                                default: break
                                }
                            }
                            if !matchesColor { continue }
                        }
                        
                        // Filter by Tags (Multiple)
                        let selectedTags = configuration.selectedTags
                        if !selectedTags.isEmpty {
                            let noteTags = note.tags ?? []
                            let selectedTagIDs = selectedTags.map { $0.id }
                            let hasMatchingTag = noteTags.contains { selectedTagIDs.contains($0) }
                            if !hasMatchingTag { continue }
                        }
                        
                        allNotes.append(note)
                    }
                } catch {
                    print("Error decoding note: \(error)")
                }
            }
        }
        
        allNotes.sort { ($0.createdAt ?? Date.distantPast) > ($1.createdAt ?? Date.distantPast) }
        
        let todayNotes = allNotes.filter { Calendar.current.isDateInToday($0.parsedDate) }
        let futureNotes = allNotes.filter { $0.parsedDate > Date() && !Calendar.current.isDateInToday($0.parsedDate) }
        
        let entry = SimpleEntry(date: Date(), todayNotes: todayNotes, futureNotes: futureNotes, isLoggedIn: true, configuration: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
}

// MARK: - Entry
struct SimpleEntry: TimelineEntry {
    let date: Date
    let todayNotes: [WidgetNote]
    let futureNotes: [WidgetNote]
    let isLoggedIn: Bool
    let configuration: NoteFilterIntent
}

// MARK: - View Helpers
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

// MARK: - Widget UI
struct NovaWidgetEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

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
        formatter.dateFormat = "d MMM EEEE" // "21 TEM SALI" formatına yakın
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter
    }
    
    var body: some View {
        if !entry.isLoggedIn {
            Text("Lütfen Nova uygulamasına giriş yapın.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .bold))
                        Text("\(entry.todayNotes.count)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                }
                .widgetURL(URL(string: (entry.todayNotes.count == 1 && entry.todayNotes[0].id != nil) ? "nova://note?id=\(entry.todayNotes[0].id!)" : "nova://notes"))
            case .accessoryInline:
                Group {
                    if entry.todayNotes.isEmpty {
                        Label("Etkinlik yok", systemImage: "calendar")
                    } else if entry.todayNotes.count == 1 {
                        Label(entry.todayNotes[0].title ?? "Etkinlik", systemImage: "calendar")
                    } else {
                        Label("\(entry.todayNotes.count) Etkinlik", systemImage: "calendar")
                    }
                }
                .widgetURL(URL(string: (entry.todayNotes.count == 1 && entry.todayNotes[0].id != nil) ? "nova://note?id=\(entry.todayNotes[0].id!)" : "nova://notes"))
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .bold))
                        Text("Bugün")
                            .font(.system(size: 12, weight: .bold))
                    }
                    if entry.todayNotes.isEmpty {
                        Text("Etkinlik yok")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    } else if entry.todayNotes.count == 1 {
                        Text(entry.todayNotes[0].title ?? "Etkinlik")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(2)
                    } else {
                        Text("\(entry.todayNotes.count) Etkinlik")
                            .font(.system(size: 14, weight: .bold))
                        if let firstNoteTitle = entry.todayNotes.first?.title {
                            Text(firstNoteTitle)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .widgetURL(URL(string: (entry.todayNotes.count == 1 && entry.todayNotes[0].id != nil) ? "nova://note?id=\(entry.todayNotes[0].id!)" : "nova://notes"))
            default:
                HStack(alignment: .top, spacing: 16) {
                    // Left Side: Today
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayNameFormatter.string(from: entry.date).uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                        
                        Text(dayNumberFormatter.string(from: entry.date))
                            .font(.system(size: 32, weight: .regular))
                            .foregroundColor(.primary)
                            .padding(.bottom, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            if entry.todayNotes.isEmpty {
                                Text("Not yok")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            } else {
                                ForEach(entry.todayNotes.prefix(2)) { note in
                                    NoteRowView(note: note)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Divider
                    Divider()
                    // Right Side: Future & Overflow
                    VStack(alignment: .leading, spacing: 6) {
                        let remainingToday = Array(entry.todayNotes.dropFirst(2))
                        
                        let groupedFuture = Dictionary(grouping: entry.futureNotes, by: { $0.date ?? "" })
                        let sortedDates = groupedFuture.keys.sorted()
                        
                        let tomorrowString: String = {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            return formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                        }()
                        
                        if !remainingToday.isEmpty {
                            // Bugünün taşan notlarını sağda göster
                            ForEach(remainingToday.prefix(3)) { note in
                                NoteRowView(note: note)
                            }
                            
                            // Eğer sağda sadece 1 taşan not varsa, altına 1 tane de gelecek notu sığdırabiliriz
                            if remainingToday.count == 1, let firstDateStr = sortedDates.first, let firstNotes = groupedFuture[firstDateStr] {
                                let isTomorrow = (firstDateStr == tomorrowString)
                                Text(isTomorrow ? "YARIN" : customDateFormatter.string(from: firstNotes.first!.parsedDate).uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                    .padding(.top, 2)
                                
                                NoteRowView(note: firstNotes.first!)
                            }
                        } else if let firstDateStr = sortedDates.first, let firstNotes = groupedFuture[firstDateStr] {
                            let isTomorrow = (firstDateStr == tomorrowString)
                            
                            Text(isTomorrow ? "YARIN" : customDateFormatter.string(from: firstNotes.first!.parsedDate).uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.gray)
                            
                            if firstNotes.count >= 2 {
                                ForEach(firstNotes.prefix(2)) { note in
                                    NoteRowView(note: note)
                                }
                                if firstNotes.count > 2 {
                                    Text("+\(firstNotes.count - 2) adet daha etkinlik var")
                                        .font(.system(size: 9))
                                        .foregroundColor(.gray)
                                }
                            } else {
                                // Sadece 1 not var
                                NoteRowView(note: firstNotes.first!)
                                
                                // İkinci güne yer var
                                if sortedDates.count > 1 {
                                    let secondDateStr = sortedDates[1]
                                    let secondNotes = groupedFuture[secondDateStr]!
                                    let isSecondTomorrow = (secondDateStr == tomorrowString)
                                    
                                    Text(isSecondTomorrow ? "YARIN" : customDateFormatter.string(from: secondNotes.first!.parsedDate).uppercased())
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)
                                        .padding(.top, 2)
                                    
                                    NoteRowView(note: secondNotes.first!)
                                    
                                    if secondNotes.count > 1 {
                                        Text("+\(secondNotes.count - 1) adet daha etkinlik var")
                                            .font(.system(size: 9))
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        } else {
                            Text("İleriki günlerde not yok.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                                .padding(.top, 4)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct NoteRowView: View {
    let note: WidgetNote
    
    var body: some View {
        if let id = note.id, !id.isEmpty, let url = URL(string: "nova://note?id=\(id)") {
            Link(destination: url) {
                rowContent
            }
        } else {
            rowContent
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(hex: note.colorHex))
                .frame(width: 4)
            
            Text(note.title ?? "Başlıksız")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(UIColor.label))
                .lineLimit(1)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(hex: note.colorHex).opacity(0.15))
        .cornerRadius(4)
        .padding(.bottom, 2)
    }
}

// MARK: - Widget Setup
struct NovaWidget: Widget {
    let kind: String = "NovaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: NoteFilterIntent.self, provider: Provider()) { entry in
            NovaWidgetEntryView(entry: entry)
                .containerBackground(Color.white, for: .widget)
                .widgetURL(URL(string: "nova://notes"))
        }
        .supportedFamilies([.systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .configurationDisplayName("Nova Takvim")
        .description("Notlarınızı Apple Takvim formatında görün.")
    }
}

// MARK: - Streak Widget

struct CalendarDay: Hashable {
    let dateStr: String
    let dayNum: Int
    let isSuccess: Bool
    let isToday: Bool
}

struct StreakEntry: TimelineEntry {
    let date: Date
    let todayProgress: Int
    let streakCount: Int
    let isGoalReached: Bool
    let monthCalendar: [CalendarDay]
    let isLoggedIn: Bool
}

struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry {
        StreakEntry(date: Date(), todayProgress: 45, streakCount: 5, isGoalReached: false, monthCalendar: [], isLoggedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        let entry = StreakEntry(date: Date(), todayProgress: 120, streakCount: 12, isGoalReached: true, monthCalendar: [], isLoggedIn: true)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        guard let user = Auth.auth().currentUser else {
            let entry = StreakEntry(date: Date(), todayProgress: 0, streakCount: 0, isGoalReached: false, monthCalendar: [], isLoggedIn: false)
            completion(Timeline(entries: [entry], policy: .after(Calendar.current.date(byAdding: .minute, value: 5, to: Date())!)))
            return
        }

        let db = Firestore.firestore()
        db.collection("users").document(user.uid).collection("daily_stats")
            .getDocuments(source: .server) { snapshot, error in
                
                if error != nil {
                    db.collection("users").document(user.uid).collection("daily_stats")
                        .getDocuments { cacheSnap, _ in
                            self.processSnapshot(cacheSnap, completion: completion)
                        }
                    return
                }
                
                self.processSnapshot(snapshot, completion: completion)
            }
    }
    
    private func getLocalDateStr(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }
    
    private func processSnapshot(_ snapshot: QuerySnapshot?, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        var statsDict: [String: Int] = [:]
        
        if let docs = snapshot?.documents {
            for doc in docs {
                let data = doc.data()
                let dateStr = doc.documentID
                if let count = (data["correctCount"] as? NSNumber)?.intValue ?? (data["correctCount"] as? Int) {
                    statsDict[dateStr] = count
                }
            }
        }
        
        var streak = 0
        var d = Date()
        
        let todayStr = getLocalDateStr(d)
        let todayCount = statsDict[todayStr] ?? 0
        let isGoalReached = todayCount >= 100
        if isGoalReached { streak += 1 }
        
        d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
        while true {
            let pastStr = getLocalDateStr(d)
            let pastCount = statsDict[pastStr] ?? 0
            if pastCount >= 100 {
                streak += 1
                d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
            } else {
                break
            }
        }
        
        var monthCalendar: [CalendarDay] = []
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        
        let today = Date()
        let comps = cal.dateComponents([.year, .month], from: today)
        let startOfMonth = cal.date(from: comps)!
        if let range = cal.range(of: .day, in: .month, for: today) {
            let numDays = range.count
            let weekday = cal.component(.weekday, from: startOfMonth)
            let emptyPrefix = (weekday + 5) % 7
            
            for _ in 0..<emptyPrefix {
                monthCalendar.append(CalendarDay(dateStr: "", dayNum: 0, isSuccess: false, isToday: false))
            }
            
            for i in 0..<numDays {
                if let dayDate = cal.date(byAdding: .day, value: i, to: startOfMonth) {
                    let dayStr = getLocalDateStr(dayDate)
                    let dayCount = statsDict[dayStr] ?? 0
                    let success = (dayCount >= 100)
                    let isTodayFlag = (dayStr == todayStr)
                    monthCalendar.append(CalendarDay(dateStr: dayStr, dayNum: i + 1, isSuccess: success, isToday: isTodayFlag))
                }
            }
        }
        
        let entry = StreakEntry(
            date: Date(),
            todayProgress: todayCount,
            streakCount: streak,
            isGoalReached: isGoalReached,
            monthCalendar: monthCalendar,
            isLoggedIn: true
        )
        
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct StreakWidgetEntryView : View {
    var entry: StreakProvider.Entry
    @Environment(\.widgetFamily) var family
    
    let dayInitials = ["P", "S", "Ç", "P", "C", "C", "P"]
    
    @ViewBuilder
    var smallStreakWidgetView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row with optional completion badge
            if entry.isGoalReached {
                HStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Tamamlandı")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.14))
                    .cornerRadius(10)
                }
                .padding(.bottom, 2)
            }
            
            Spacer(minLength: 0)
            
            // Hero Center Section (Edge-to-Edge Hero)
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(entry.isGoalReached ? Color.orange.opacity(0.22) : Color.orange.opacity(0.12))
                        .frame(width: 52, height: 52)
                    
                    Image(systemName: "flame.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(entry.isGoalReached ? .orange : .gray.opacity(0.5))
                }
                
                VStack(alignment: .leading, spacing: -2) {
                    Text("\(entry.streakCount)")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    
                    Text("GÜN SERİ")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundColor(.secondary)
                        .tracking(0.6)
                }
            }
            .padding(.vertical, 2)
            
            Spacer(minLength: 0)
            
            // Bottom Progress Bar Section (Edge-to-Edge)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.isGoalReached ? "Hedef Tamam!" : "Bugünkü Hedef")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(entry.isGoalReached ? .green : .secondary)
                    
                    Spacer()
                    
                    Text("\(entry.todayProgress)/100")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(entry.isGoalReached ? .green : .primary)
                }
                
                GeometryReader { pGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.18))
                            .frame(height: 10)
                        
                        let progressRatio = min(1.0, max(0.0, Double(entry.todayProgress) / 100.0))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: entry.isGoalReached ? [.green, Color(red: 0.2, green: 0.8, blue: 0.4)] : [.orange, .yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(10, pGeo.size.width * CGFloat(progressRatio)), height: 10)
                    }
                }
                .frame(height: 10)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    @ViewBuilder
    var leftSideView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SÖZLÜK SERİSİ")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundColor(entry.isGoalReached ? .orange : .gray)
            
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(entry.isGoalReached ? Color.orange.opacity(0.18) : Color.gray.opacity(0.12))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(entry.isGoalReached ? .orange : .gray.opacity(0.4))
                }
                
                VStack(alignment: .leading, spacing: -2) {
                    Text("\(entry.streakCount)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    
                    Text("GÜN SERİ")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Bugün")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                
                Text("\(entry.todayProgress) / 100")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(entry.isGoalReached ? .green : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
    
    var body: some View {
        if !entry.isLoggedIn {
            Text("Lütfen giriş yapın.")
        } else {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(entry.isGoalReached ? .orange : .primary)
                        Text("\(entry.streakCount)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                }
                .widgetURL(URL(string: "nova://dictionary"))
            case .accessoryInline:
                ViewThatFits {
                    Label("\(entry.streakCount) Gün Seri", systemImage: "flame.fill")
                    Text("🔥 \(entry.streakCount) Gün Seri")
                }
                .widgetURL(URL(string: "nova://dictionary"))
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(entry.isGoalReached ? .orange : .primary)
                        Text("Sözlük Streak")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    Text("\(entry.streakCount) GÜN SERİ")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                    Text(entry.isGoalReached ? "Tamamlandı 🎉" : "Bugün: \(entry.todayProgress)/100")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .widgetURL(URL(string: "nova://dictionary"))
            case .systemSmall:
                smallStreakWidgetView
            default:
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        // Sol Taraf
                        leftSideView
                            .frame(width: geo.size.width * 0.40 - 4, alignment: .leading)
                    
                    Divider()
                        .padding(.horizontal, 4)
                
                    // Sağ Taraf
                    VStack(alignment: .center, spacing: 0) {
                        Text("BU AY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { i in
                                Text(dayInitials[i])
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 18)
                            }
                        }
                        
                        let columns = Array(repeating: GridItem(.fixed(18), spacing: 4), count: 7)
                        LazyVGrid(columns: columns, spacing: 1) {
                            ForEach(0..<entry.monthCalendar.count, id: \.self) { i in
                                let day = entry.monthCalendar[i]
                                if day.dayNum == 0 {
                                    Color.clear.frame(width: 18, height: 18)
                                } else {
                                    ZStack {
                                        Circle()
                                            .fill(day.isSuccess ? Color.orange : Color.gray.opacity(0.15))
                                            .frame(width: 18, height: 18)
                                        
                                        if day.isSuccess {
                                            Image(systemName: "flame.fill")
                                                .resizable()
                                                .scaledToFit()
                                                .foregroundColor(.white)
                                                .padding(3.5)
                                        } else {
                                            Text("\(day.dayNum)")
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .overlay(
                                        Circle()
                                            .stroke(day.isToday ? Color.blue : Color.clear, lineWidth: 1)
                                            .padding(-2)
                                    )
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: geo.size.width * 0.60 - 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            }
        }
    }
    
    private func getLocalDateStr(_ d: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }
}

struct StreakWidget: Widget {
    let kind: String = "StreakWidget"

    var body: some WidgetConfiguration {
        let config = StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            if #available(iOS 17.0, *) {
                StreakWidgetEntryView(entry: entry)
                    .containerBackground(for: .widget) {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            if entry.isGoalReached {
                                Color.orange.opacity(0.12)
                            }
                        }
                    }
                    .widgetURL(URL(string: "nova://dictionary"))
            } else {
                StreakWidgetEntryView(entry: entry)
                    .background(
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            if entry.isGoalReached {
                                Color.orange.opacity(0.12)
                            }
                        }
                    )
                    .widgetURL(URL(string: "nova://dictionary"))
            }
        }
        .configurationDisplayName("Sözlük Streak")
        .description("Sözlükteki günlük çalışma serinizi takip edin.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        
        if #available(iOS 17.0, *) {
            return config.contentMarginsDisabled()
        } else {
            return config
        }
    }
}

// MARK: - Bank Widget Models & Views

struct WidgetBank: Codable, Identifiable {
    var id: String
    var name: String?
    var logo: String?
    var visible: Bool?
    var order: Int?
    var deleted: Bool?
    var balance: Double = 0.0
}

struct BankEntry: TimelineEntry {
    let date: Date
    let banks: [WidgetBank]
    let totalBalance: Double
    let isLoggedIn: Bool
}

struct BankWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Banka Widget Ayarları"
    static var description = IntentDescription("Banka widget'ı ayarları.")
}

struct BankProvider: AppIntentTimelineProvider {
    typealias Entry = BankEntry
    typealias Intent = BankWidgetIntent
    
    func placeholder(in context: Context) -> BankEntry {
        BankEntry(date: Date(), banks: [
            WidgetBank(id: "1", name: "Vakıfbank", logo: "vakifbank", visible: true, order: 1, deleted: false, balance: 1282.75),
            WidgetBank(id: "2", name: "İşbank", logo: "isbank", visible: true, order: 2, deleted: false, balance: 0.0),
            WidgetBank(id: "3", name: "Enpara", logo: "enpara", visible: true, order: 3, deleted: false, balance: 0.0),
            WidgetBank(id: "4", name: "Akbank", logo: "akbank", visible: true, order: 4, deleted: false, balance: 0.51)
        ], totalBalance: 1283.26, isLoggedIn: true)
    }

    func snapshot(for configuration: BankWidgetIntent, in context: Context) async -> BankEntry {
        return placeholder(in: context)
    }

    func timeline(for configuration: BankWidgetIntent, in context: Context) async -> Timeline<BankEntry> {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        guard let user = Auth.auth().currentUser else {
            let entry = BankEntry(date: Date(), banks: [], totalBalance: 0.0, isLoggedIn: false)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
        
        let db = Firestore.firestore()
        do {
            let banksSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("banks"))
            let transSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("bankTransactions"))
            
            var allBanksForTotal: [WidgetBank] = []
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
                    allBanksForTotal.append(WidgetBank(id: id, name: name, logo: logo, visible: visible, order: orderValue, deleted: deleted, balance: 0.0))
                }
            }
            
            for i in 0..<allBanksForTotal.count {
                let bId = allBanksForTotal[i].id
                let transactions = transSnap.documents.filter { doc in
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
                allBanksForTotal[i].balance = balance
            }
            
            let visibleBanks = allBanksForTotal.filter { $0.visible ?? true }
            let total = visibleBanks.reduce(0.0) { $0 + $1.balance }
            
            var sortedVisibleBanks = visibleBanks
            sortedVisibleBanks.sort { ($0.order ?? 999) < ($1.order ?? 999) }
            
            let topBanks = Array(sortedVisibleBanks.prefix(7))
            
            let entry = BankEntry(date: Date(), banks: topBanks, totalBalance: total, isLoggedIn: true)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        } catch {
            print("Error loading bank data in Widget: \(error)")
            let entry = BankEntry(date: Date(), banks: [], totalBalance: 0.0, isLoggedIn: true)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
    }
}

fileprivate func getDocumentsServerFirst(_ query: Query) async throws -> QuerySnapshot {
    do {
        return try await query.getDocuments(source: .server)
    } catch {
        return try await query.getDocuments(source: .cache)
    }
}

fileprivate func parseAmount(_ val: Any?) -> Double {
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

fileprivate func getLocalLogoName(for bankName: String) -> String? {
    let lowerName = bankName.lowercased(with: Locale(identifier: "tr_TR"))
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "ş", with: "s")
        .replacingOccurrences(of: "ç", with: "c")
        .replacingOccurrences(of: "ğ", with: "g")
        .replacingOccurrences(of: "ü", with: "u")
        .replacingOccurrences(of: "ö", with: "o")
        .replacingOccurrences(of: "i̇", with: "i") // Remove combining dot if present
    
    let knownBanks = ["akbank", "denizbank", "enpara", "garanti", "halkbank", "isbank", "vakifbank", "ziraat"]
    for kb in knownBanks {
        if lowerName.contains(kb) {
            return kb
        }
    }
    return nil
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

struct BankWidgetEntryView: View {
    var entry: BankProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        VStack(spacing: 10) {
            // Header Row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "0052cc"))
                    Text("Hesap Özetleri")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Text("Toplam: \(formatCurrency(entry.totalBalance))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "0052cc"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "0052cc").opacity(0.08))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            if !entry.isLoggedIn {
                Spacer()
                Text("Lütfen giriş yapın.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else if entry.banks.isEmpty {
                Spacer()
                Text("Görünür hesap bulunamadı.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                if family == .systemLarge {
                    // Large widget: vertical list (up to 7 items)
                    VStack(spacing: 8) {
                        ForEach(entry.banks) { bank in
                            LargeBankRowView(bank: bank)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    // Medium widget: horizontal row (prefix 4 items)
                    HStack(spacing: 6) {
                        ForEach(entry.banks.prefix(4)) { bank in
                            BankCardView(bank: bank)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct BankCardView: View {
    let bank: WidgetBank
    
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            // Circle with Logo
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
                
                if let logoName = getLocalLogoName(for: bank.name ?? "") {
                    Image(logoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "landmark.circle.fill")
                        .resizable()
                        .foregroundColor(.gray.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
            }
            
            // Name and Balance vertically stacked
            VStack(spacing: 2) {
                Text(bank.name ?? "")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Text(formatCurrency(bank.balance))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(bank.balance < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
    }
}

struct LargeBankRowView: View {
    let bank: WidgetBank
    
    var body: some View {
        HStack(spacing: 12) {
            // Circle with Logo
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white))
                
                if let logoName = getLocalLogoName(for: bank.name ?? "") {
                    Image(logoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "landmark.circle.fill")
                        .resizable()
                        .foregroundColor(.gray.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
            }
            
            // Bank Name
            Text(bank.name ?? "")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.black.opacity(0.8))
                .lineLimit(1)
            
            Spacer()
            
            // Bank Balance
            Text(formatCurrency(bank.balance))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(bank.balance < 0 ? Color(hex: "d9534f") : Color(hex: "0052cc"))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct BankWidget: Widget {
    let kind: String = "BankWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: BankWidgetIntent.self, provider: BankProvider()) { entry in
            if #available(iOS 17.0, *) {
                BankWidgetEntryView(entry: entry)
                    .containerBackground(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ), for: .widget)
                    .widgetURL(URL(string: "nova://bank"))
            } else {
                BankWidgetEntryView(entry: entry)
                    .background(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .widgetURL(URL(string: "nova://bank"))
            }
        }
        .configurationDisplayName("Hesap Özetleri")
        .description("Bankadaki hesap özetlerini ve toplam bakiyeyi takip edin.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

#Preview(as: .systemLarge) {
    BankWidget()
} timeline: {
    BankEntry(date: Date(), banks: [
        WidgetBank(id: "1", name: "Vakıfbank", logo: "vakifbank", visible: true, order: 1, deleted: false, balance: 1282.75),
        WidgetBank(id: "2", name: "İşbank", logo: "isbank", visible: true, order: 2, deleted: false, balance: 0.0),
        WidgetBank(id: "3", name: "Enpara", logo: "enpara", visible: true, order: 3, deleted: false, balance: 0.0),
        WidgetBank(id: "4", name: "Akbank", logo: "akbank", visible: true, order: 4, deleted: false, balance: 0.51),
        WidgetBank(id: "5", name: "Garanti", logo: "garanti", visible: true, order: 5, deleted: false, balance: 0.0),
        WidgetBank(id: "6", name: "Ziraat", logo: "ziraat", visible: true, order: 6, deleted: false, balance: 0.0),
        WidgetBank(id: "7", name: "Denizbank", logo: "denizbank", visible: true, order: 7, deleted: false, balance: 0.0)
    ], totalBalance: 1283.26, isLoggedIn: true)
}

// MARK: - Finance Widget Models & Views

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
}

struct FinanceEntry: TimelineEntry {
    let date: Date
    let institutions: [WidgetInstitution]
    let totalPortfolio: Double
    let totalTax: Double
    let isLoggedIn: Bool
    let showTax: Bool
}

struct FinanceLot {
    var remaining: Double
    var price: Double
    var taxRate: Double
    var date: String
}

struct FinanceWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Finans Widget Ayarları"
    static var description = IntentDescription("Finans widget'ı ayarları.")
    
    @Parameter(title: "Stopaj Göster", default: false)
    var showTax: Bool
}

struct FinanceProvider: AppIntentTimelineProvider {
    typealias Entry = FinanceEntry
    typealias Intent = FinanceWidgetIntent
    
    func placeholder(in context: Context) -> FinanceEntry {
        FinanceEntry(date: Date(), institutions: [
            WidgetInstitution(id: "1", name: "Midas", logo: "", visible: true, order: 1, deleted: false, netValue: 2635752.98, dailyGain: -12036.11, taxValue: 28022.63, dailyGainPercent: -0.45, totalGain: 582555.86, totalGainPercent: 28.37, taxRate: 10.0),
            WidgetInstitution(id: "2", name: "Midas F", logo: "", visible: true, order: 2, deleted: false, netValue: 1459467.23, dailyGain: -3820.24, taxValue: 54790.33, dailyGainPercent: -0.25, totalGain: 438319.16, totalGainPercent: 42.92, taxRate: 10.0),
            WidgetInstitution(id: "3", name: "Akbank", logo: "akbank", visible: true, order: 3, deleted: false, netValue: 170925.89, dailyGain: 321.36, taxValue: 198.40, dailyGainPercent: 0.19, totalGain: 935.27, totalGainPercent: 0.55, taxRate: 10.0),
            WidgetInstitution(id: "4", name: "İşbank", logo: "isbank", visible: true, order: 4, deleted: false, netValue: 88999.94, dailyGain: -626.62, taxValue: 0.0, dailyGainPercent: -0.70, totalGain: 0.0, totalGainPercent: 0.0, taxRate: 0.0)
        ], totalPortfolio: 4355146.03, totalTax: 83011.36, isLoggedIn: true, showTax: true)
    }

    func snapshot(for configuration: FinanceWidgetIntent, in context: Context) async -> FinanceEntry {
        return placeholder(in: context)
    }

    func timeline(for configuration: FinanceWidgetIntent, in context: Context) async -> Timeline<FinanceEntry> {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        guard let user = Auth.auth().currentUser else {
            let entry = FinanceEntry(date: Date(), institutions: [], totalPortfolio: 0.0, totalTax: 0.0, isLoggedIn: false, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
        
        let db = Firestore.firestore()
        do {
            let instsSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("institutions"))
            let stocksSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("stocks"))
            let transSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("financeTransactions"))
            
            var stocksDict: [String: (currentPrice: Double, dailyChange: Double)] = [:]
            for doc in stocksSnap.documents {
                let data = doc.data()
                let id = doc.documentID
                let currentPrice = parseAmount(data["currentPrice"])
                let dailyChange = parseAmount(data["dailyChange"])
                stocksDict[id] = (currentPrice, dailyChange)
            }
            
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
                    instList.append(WidgetInstitution(id: id, name: name, logo: logo, visible: visible, order: orderValue, deleted: deleted, netValue: 0.0, dailyGain: 0.0, taxValue: 0.0, dailyGainPercent: 0.0, totalGain: 0.0, totalGainPercent: 0.0))
                }
            }
            
            struct TransactionRecord {
                let id: String
                let institutionId: String
                let stockId: String
                let type: String
                let quantity: Double
                let price: Double
                let taxRate: Double
                let date: String
                let createdAtSeconds: Int
            }
            
            var records: [TransactionRecord] = []
            for doc in transSnap.documents {
                let data = doc.data()
                let id = doc.documentID
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
                
                records.append(TransactionRecord(id: id, institutionId: instId, stockId: stockId, type: type, quantity: quantity, price: price, taxRate: taxRate, date: date, createdAtSeconds: seconds))
            }
            
            records.sort {
                let dateCmp = $0.date.compare($1.date)
                if dateCmp != .orderedSame {
                    return dateCmp == .orderedAscending
                }
                return $0.createdAtSeconds < $1.createdAtSeconds
            }
            
            var buyLots: [String: [FinanceLot]] = [:]
            
            for r in records {
                let key = "\(r.stockId)_\(r.institutionId)"
                if r.type.hasPrefix("AL") {
                    if buyLots[key] == nil {
                        buyLots[key] = []
                    }
                    buyLots[key]?.append(FinanceLot(remaining: r.quantity, price: r.price, taxRate: r.taxRate, date: r.date))
                } else {
                    var remainingToSell = r.quantity
                    if var lots = buyLots[key] {
                        for idx in 0..<lots.count {
                            if remainingToSell <= 0 { break }
                            if lots[idx].remaining <= 0 { continue }
                            let sellAmount = min(lots[idx].remaining, remainingToSell)
                            lots[idx].remaining -= sellAmount
                            remainingToSell -= sellAmount
                        }
                        buyLots[key] = lots
                    }
                }
            }
            
            var statsDict: [String: (totalInvestment: Double, unrealizedNet: Double, unrealizedGross: Double, dailyGain: Double)] = [:]
            for inst in instList {
                statsDict[inst.id] = (0.0, 0.0, 0.0, 0.0)
            }
            
            for (key, lots) in buyLots {
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
                        
                        if var stats = statsDict[instId] {
                            stats.totalInvestment += cost
                            stats.unrealizedNet += (uGross - uTax)
                            stats.unrealizedGross += uGross
                            stats.dailyGain += currentVal * (stockInfo.dailyChange / (100.0 + stockInfo.dailyChange))
                            statsDict[instId] = stats
                        }
                    }
                }
            }
            
            for i in 0..<instList.count {
                if let stats = statsDict[instList[i].id] {
                    instList[i].netValue = stats.totalInvestment + stats.unrealizedNet
                    instList[i].dailyGain = stats.dailyGain
                    instList[i].taxValue = stats.unrealizedGross - stats.unrealizedNet
                    
                    let currentValue = stats.totalInvestment + stats.unrealizedGross
                    let denominator = currentValue - stats.dailyGain
                    instList[i].dailyGainPercent = (currentValue > 0 && denominator != 0) ? (stats.dailyGain / denominator * 100.0) : 0.0
                    
                    instList[i].totalGain = stats.unrealizedNet
                    instList[i].totalGainPercent = stats.totalInvestment > 0 ? (stats.unrealizedNet / stats.totalInvestment * 100.0) : 0.0
                    
                    let instTax = stats.unrealizedGross - stats.unrealizedNet
                    instList[i].taxRate = stats.unrealizedGross > 0 ? (instTax / stats.unrealizedGross * 100.0) : 0.0
                }
            }
            
            let visibleInsts = instList.filter { $0.visible ?? true }
            let total = visibleInsts.reduce(0.0) { $0 + $1.netValue }
            let totalTax = visibleInsts.reduce(0.0) { $0 + $1.taxValue }
            
            var sortedInsts = visibleInsts
            sortedInsts.sort { ($0.order ?? 999) < ($1.order ?? 999) }
            
            let topInsts = Array(sortedInsts.prefix(7))
            
            let entry = FinanceEntry(date: Date(), institutions: topInsts, totalPortfolio: total, totalTax: totalTax, isLoggedIn: true, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        } catch {
            print("Error loading finance data in Widget: \(error)")
            let entry = FinanceEntry(date: Date(), institutions: [], totalPortfolio: 0.0, totalTax: 0.0, isLoggedIn: true, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
    }
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

fileprivate func formatDailyGain(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        let prefix = value > 0 ? "+" : ""
        return "\(prefix)\(formatted) ₺"
    }
    let prefix = value > 0 ? "+" : ""
    return String(format: "\(prefix)%.2f ₺", value)
}

fileprivate func formatPercent(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "tr_TR")
    if let formatted = formatter.string(from: NSNumber(value: value)) {
        let prefix = value > 0 ? "+" : ""
        return "(\(prefix)\(formatted)%)"
    }
    let prefix = value > 0 ? "+" : ""
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

struct FinanceWidgetEntryView: View {
    var entry: FinanceProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        VStack(spacing: 8) {
            // Header Row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "2ecc71"))
                    Text("Finans Özetleri")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Portföy: \(formatCurrency(entry.totalPortfolio))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "2ecc71"))
                    if entry.showTax && entry.totalTax > 0 {
                        Text("Stopaj: -\(formatCurrency(entry.totalTax))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "2ecc71").opacity(0.08))
                .cornerRadius(8)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            if !entry.isLoggedIn {
                Spacer()
                Text("Lütfen giriş yapın.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else if entry.institutions.isEmpty {
                Spacer()
                Text("Görünür kurum bulunamadı.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                if family == .systemLarge {
                    VStack(spacing: 8) {
                        ForEach(entry.institutions) { inst in
                            LargeFinanceRowView(inst: inst, showTax: entry.showTax)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            if entry.institutions.count > 0 {
                                FinanceCardView(inst: entry.institutions[0], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                            if entry.institutions.count > 1 {
                                FinanceCardView(inst: entry.institutions[1], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                        HStack(spacing: 6) {
                            if entry.institutions.count > 2 {
                                FinanceCardView(inst: entry.institutions[2], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                            if entry.institutions.count > 3 {
                                FinanceCardView(inst: entry.institutions[3], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct FinanceCardView: View {
    let inst: WidgetInstitution
    let showTax: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Left: Circle with Logo
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
                
                if let logoName = getInstitutionLogo(for: inst.name ?? "") {
                    Image(logoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "dollarsign.circle.fill")
                        .resizable()
                        .foregroundColor(.gray.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
            }
            
            // Right: Multi-row statistics
            VStack(alignment: .leading, spacing: 1) {
                // Row 1: Daily gain and daily gain percentage
                HStack(spacing: 2) {
                    Text(formatDailyGain(inst.dailyGain))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(inst.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                    
                    Text(formatPercent(inst.dailyGainPercent))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(inst.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                }
                
                // Row 2: Total gain
                HStack(spacing: 2) {
                    Text("Top:")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Text(formatDailyGain(inst.totalGain))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(inst.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                    
                    Text(formatPercent(inst.totalGainPercent))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(inst.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                }
                
                // Optional Row 3: Stopaj (if showTax is true)
                if showTax && inst.taxValue > 0 {
                    HStack(spacing: 2) {
                        Text("Stpj: -\(formatCurrency(inst.taxValue))")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(1)
                        
                        Text(formatSimplePercent(inst.taxRate))
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct LargeFinanceRowView: View {
    let inst: WidgetInstitution
    let showTax: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            // Row 1: Name, Daily % and Daily Gain
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white))
                    
                    if let logoName = getInstitutionLogo(for: inst.name ?? "") {
                        Image(logoName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "dollarsign.circle.fill")
                            .resizable()
                            .foregroundColor(.gray.opacity(0.6))
                            .frame(width: 16, height: 16)
                    }
                }
                
                Text(inst.name ?? "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Text(formatPercent(inst.dailyGainPercent))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(inst.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
                
                Spacer()
                
                Text(formatDailyGain(inst.dailyGain))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(inst.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
            }
            
            // Row 2: Total Label, Total % and Total Gain
            HStack(spacing: 8) {
                Text("Toplam")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 32)
                
                Text(formatPercent(inst.totalGainPercent))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(inst.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
                
                Spacer()
                
                Text(formatDailyGain(inst.totalGain))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(inst.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
            }
            
            // Row 3: Stopaj (only if showTax is true)
            if showTax && inst.taxValue > 0 {
                HStack(spacing: 8) {
                    Text("Stopaj")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 32)
                    
                    Spacer()
                    
                    Text("-\(formatCurrency(inst.taxValue))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct FinanceWidget: Widget {
    let kind: String = "FinanceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FinanceWidgetIntent.self, provider: FinanceProvider()) { entry in
            if #available(iOS 17.0, *) {
                FinanceWidgetEntryView(entry: entry)
                    .containerBackground(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ), for: .widget)
                    .widgetURL(URL(string: "nova://finance"))
            } else {
                FinanceWidgetEntryView(entry: entry)
                    .background(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .widgetURL(URL(string: "nova://finance"))
            }
        }
        .configurationDisplayName("Finans Özetleri")
        .description("Yatırım yaptığınız kurumların günlük getiri ve portföy değerlerini takip edin.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

#Preview(as: .systemLarge) {
    FinanceWidget()
} timeline: {
    FinanceEntry(date: Date(), institutions: [
        WidgetInstitution(id: "1", name: "Midas", logo: "", visible: true, order: 1, deleted: false, netValue: 2635752.98, dailyGain: -12036.11, taxValue: 28022.63, dailyGainPercent: -0.45, totalGain: 582555.86, totalGainPercent: 28.37),
        WidgetInstitution(id: "2", name: "Midas F", logo: "", visible: true, order: 2, deleted: false, netValue: 1459467.23, dailyGain: -3820.24, taxValue: 54790.33, dailyGainPercent: -0.25, totalGain: 438319.16, totalGainPercent: 42.92),
        WidgetInstitution(id: "3", name: "Akbank", logo: "akbank", visible: true, order: 3, deleted: false, netValue: 170925.89, dailyGain: 321.36, taxValue: 198.40, dailyGainPercent: 0.19, totalGain: 935.27, totalGainPercent: 0.55),
        WidgetInstitution(id: "4", name: "İşbank", logo: "isbank", visible: true, order: 4, deleted: false, netValue: 88999.94, dailyGain: -626.62, taxValue: 0.0, dailyGainPercent: -0.70, totalGain: 0.0, totalGainPercent: 0.0)
    ], totalPortfolio: 4355146.03, totalTax: 83011.36, isLoggedIn: true, showTax: true)
}

// MARK: - Stock Widget Models & Views

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
}

struct StockEntry: TimelineEntry {
    let date: Date
    let stocks: [WidgetStock]
    let totalPortfolio: Double
    let totalTax: Double
    let isLoggedIn: Bool
    let showTax: Bool
}

struct StockWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Hisseler Widget Ayarları"
    static var description = IntentDescription("Hisseler widget'ı ayarları.")
    
    @Parameter(title: "Stopaj Göster", default: false)
    var showTax: Bool
}

struct StockProvider: AppIntentTimelineProvider {
    typealias Entry = StockEntry
    typealias Intent = StockWidgetIntent
    
    func placeholder(in context: Context) -> StockEntry {
        StockEntry(date: Date(), stocks: [
            WidgetStock(id: "1", name: "THY", netValue: 120531.97, dailyGain: 1500.0, taxValue: 150.0, dailyGainPercent: 1.25, totalGain: 5500.0, totalGainPercent: 4.78, taxRate: 10.0),
            WidgetStock(id: "2", name: "EREGL", netValue: 82148.06, dailyGain: -382.24, taxValue: 0.0, dailyGainPercent: -0.46, totalGain: -4382.19, totalGainPercent: -5.06, taxRate: 0.0),
            WidgetStock(id: "3", name: "KCHOL", netValue: 69990.62, dailyGain: 321.36, taxValue: 198.40, dailyGainPercent: 0.46, totalGain: 935.27, totalGainPercent: 1.35, taxRate: 10.0),
            WidgetStock(id: "4", name: "SASA", netValue: 18999.94, dailyGain: -626.62, taxValue: 0.0, dailyGainPercent: -3.19, totalGain: -200.0, totalGainPercent: -1.04, taxRate: 0.0)
        ], totalPortfolio: 291670.59, totalTax: 348.40, isLoggedIn: true, showTax: true)
    }

    func snapshot(for configuration: StockWidgetIntent, in context: Context) async -> StockEntry {
        return placeholder(in: context)
    }

    func timeline(for configuration: StockWidgetIntent, in context: Context) async -> Timeline<StockEntry> {
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        guard let user = Auth.auth().currentUser else {
            let entry = StockEntry(date: Date(), stocks: [], totalPortfolio: 0.0, totalTax: 0.0, isLoggedIn: false, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
        
        let db = Firestore.firestore()
        do {
            let stocksSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("stocks"))
            let transSnap = try await getDocumentsServerFirst(db.collection("users").document(user.uid).collection("financeTransactions"))
            
            var stocksDict: [String: (name: String, currentPrice: Double, dailyChange: Double)] = [:]
            for doc in stocksSnap.documents {
                let data = doc.data()
                let id = doc.documentID
                let name = data["name"] as? String ?? ""
                let currentPrice = parseAmount(data["currentPrice"])
                let dailyChange = parseAmount(data["dailyChange"])
                let deleted = data["deleted"] as? Bool ?? false
                if !deleted && !name.isEmpty {
                    stocksDict[id] = (name, currentPrice, dailyChange)
                }
            }
            
            struct TransactionRecord {
                let id: String
                let stockId: String
                let type: String
                let quantity: Double
                let price: Double
                let taxRate: Double
                let date: String
                let createdAtSeconds: Int
            }
            
            var records: [TransactionRecord] = []
            for doc in transSnap.documents {
                let data = doc.data()
                let id = doc.documentID
                let deleted = data["deleted"] as? Bool ?? false
                if deleted { continue }
                
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
                
                records.append(TransactionRecord(id: id, stockId: stockId, type: type, quantity: quantity, price: price, taxRate: taxRate, date: date, createdAtSeconds: seconds))
            }
            
            records.sort {
                let dateCmp = $0.date.compare($1.date)
                if dateCmp != .orderedSame {
                    return dateCmp == .orderedAscending
                }
                return $0.createdAtSeconds < $1.createdAtSeconds
            }
            
            var buyLots: [String: [FinanceLot]] = [:]
            
            for r in records {
                let key = r.stockId
                if r.type.hasPrefix("AL") {
                    if buyLots[key] == nil {
                        buyLots[key] = []
                    }
                    buyLots[key]?.append(FinanceLot(remaining: r.quantity, price: r.price, taxRate: r.taxRate, date: r.date))
                } else {
                    var remainingToSell = r.quantity
                    if var lots = buyLots[key] {
                        for idx in 0..<lots.count {
                            if remainingToSell <= 0 { break }
                            if lots[idx].remaining <= 0 { continue }
                            let sellAmount = min(lots[idx].remaining, remainingToSell)
                            lots[idx].remaining -= sellAmount
                            remainingToSell -= sellAmount
                        }
                        buyLots[key] = lots
                    }
                }
            }
            
            var statsDict: [String: (totalInvestment: Double, unrealizedNet: Double, unrealizedGross: Double, dailyGain: Double)] = [:]
            for (stockId, _) in stocksDict {
                statsDict[stockId] = (0.0, 0.0, 0.0, 0.0)
            }
            
            for (stockId, lots) in buyLots {
                guard let stockInfo = stocksDict[stockId] else { continue }
                
                for lot in lots {
                    if lot.remaining > 0 {
                        let cost = lot.price * lot.remaining
                        let currentVal = stockInfo.currentPrice * lot.remaining
                        let uGross = currentVal - cost
                        let uTax = uGross > 0 ? (uGross * (lot.taxRate / 100)) : 0.0
                        
                        if var stats = statsDict[stockId] {
                            stats.totalInvestment += cost
                            stats.unrealizedNet += (uGross - uTax)
                            stats.unrealizedGross += uGross
                            stats.dailyGain += currentVal * (stockInfo.dailyChange / (100.0 + stockInfo.dailyChange))
                            statsDict[stockId] = stats
                        }
                    }
                }
            }
            
            var stockList: [WidgetStock] = []
            for (stockId, stockInfo) in stocksDict {
                if let stats = statsDict[stockId] {
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
                        
                        stockList.append(WidgetStock(id: stockId, name: stockInfo.name, netValue: netValue, dailyGain: dailyGain, taxValue: taxValue, dailyGainPercent: dailyGainPercent, totalGain: totalGain, totalGainPercent: totalGainPercent, taxRate: taxRate))
                    }
                }
            }
            
            let total = stockList.reduce(0.0) { $0 + $1.netValue }
            let totalTax = stockList.reduce(0.0) { $0 + $1.taxValue }
            
            var sortedStocks = stockList
            sortedStocks.sort { $0.netValue > $1.netValue }
            
            let topStocks = Array(sortedStocks.prefix(7))
            
            let entry = StockEntry(date: Date(), stocks: topStocks, totalPortfolio: total, totalTax: totalTax, isLoggedIn: true, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        } catch {
            print("Error loading stocks data in Widget: \(error)")
            let entry = StockEntry(date: Date(), stocks: [], totalPortfolio: 0.0, totalTax: 0.0, isLoggedIn: true, showTax: configuration.showTax)
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }
    }
}

struct StockWidgetEntryView: View {
    var entry: StockProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        VStack(spacing: 8) {
            // Header Row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "0052cc"))
                    Text("Hisse Özetleri")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Portföy: \(formatCurrency(entry.totalPortfolio))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "0052cc"))
                    if entry.showTax && entry.totalTax > 0 {
                        Text("Stopaj: -\(formatCurrency(entry.totalTax))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "0052cc").opacity(0.08))
                .cornerRadius(8)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            if !entry.isLoggedIn {
                Spacer()
                Text("Lütfen giriş yapın.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else if entry.stocks.isEmpty {
                Spacer()
                Text("Portföyde hisse bulunamadı.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                if family == .systemLarge {
                    VStack(spacing: 8) {
                        ForEach(entry.stocks) { stock in
                            LargeStockRowView(stock: stock, showTax: entry.showTax)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            if entry.stocks.count > 0 {
                                StockCardView(stock: entry.stocks[0], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                            if entry.stocks.count > 1 {
                                StockCardView(stock: entry.stocks[1], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                        HStack(spacing: 6) {
                            if entry.stocks.count > 2 {
                                StockCardView(stock: entry.stocks[2], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                            if entry.stocks.count > 3 {
                                StockCardView(stock: entry.stocks[3], showTax: entry.showTax)
                            } else {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct StockCardView: View {
    let stock: WidgetStock
    let showTax: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Left: Circle with Symbol
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
                
                Text(stock.name ?? "")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            
            // Right: Multi-row statistics
            VStack(alignment: .leading, spacing: 1) {
                // Row 1: Daily gain and daily gain percentage
                HStack(spacing: 2) {
                    Text(formatDailyGain(stock.dailyGain))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(stock.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                    
                    Text(formatPercent(stock.dailyGainPercent))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(stock.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                }
                
                // Row 2: Total gain
                HStack(spacing: 2) {
                    Text("Top:")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Text(formatDailyGain(stock.totalGain))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(stock.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                    
                    Text(formatPercent(stock.totalGainPercent))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(stock.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                        .lineLimit(1)
                }
                
                // Optional Row 3: Stopaj (if showTax is true)
                if showTax && stock.taxValue > 0 {
                    HStack(spacing: 2) {
                        Text("Stpj: -\(formatCurrency(stock.taxValue))")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(1)
                        
                        Text(formatSimplePercent(stock.taxRate))
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct LargeStockRowView: View {
    let stock: WidgetStock
    let showTax: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white))
                    
                    Text(stock.name ?? "")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                
                Text(stock.name ?? "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black.opacity(0.8))
                    .lineLimit(1)
                
                Text(formatPercent(stock.dailyGainPercent))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(stock.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
                
                Spacer()
                
                Text(formatDailyGain(stock.dailyGain))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(stock.dailyGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
            }
            
            HStack(spacing: 8) {
                Text("Toplam")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 32)
                
                Text(formatPercent(stock.totalGainPercent))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(stock.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
                
                Spacer()
                
                Text(formatDailyGain(stock.totalGain))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(stock.totalGain < 0 ? Color(hex: "d9534f") : Color(hex: "2ecc71"))
                    .lineLimit(1)
            }
            
            if showTax && stock.taxValue > 0 {
                HStack(spacing: 8) {
                    Text("Stopaj")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 32)
                    
                    Spacer()
                    
                    Text("-\(formatCurrency(stock.taxValue))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hex: "f4f7fc")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 1, x: 0, y: 1)
    }
}

struct StockWidget: Widget {
    let kind: String = "StockWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StockWidgetIntent.self, provider: StockProvider()) { entry in
            if #available(iOS 17.0, *) {
                StockWidgetEntryView(entry: entry)
                    .containerBackground(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ), for: .widget)
                    .widgetURL(URL(string: "nova://finance"))
            } else {
                StockWidgetEntryView(entry: entry)
                    .background(LinearGradient(
                        colors: [Color(hex: "f8fafd"), Color(hex: "edf2f9")],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .widgetURL(URL(string: "nova://finance"))
            }
        }
        .configurationDisplayName("Hisse Özetleri")
        .description("Yatırım yaptığınız hisse senedi portföy değerlerini takip edin.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

#Preview(as: .systemLarge) {
    StockWidget()
} timeline: {
    StockEntry(date: Date(), stocks: [
        WidgetStock(id: "1", name: "THY", netValue: 120531.97, dailyGain: 1500.0, taxValue: 150.0, dailyGainPercent: 1.25, totalGain: 5500.0, totalGainPercent: 4.78),
        WidgetStock(id: "2", name: "EREGL", netValue: 82148.06, dailyGain: -382.24, taxValue: 0.0, dailyGainPercent: -0.46, totalGain: -4382.19, totalGainPercent: -5.06),
        WidgetStock(id: "3", name: "KCHOL", netValue: 69990.62, dailyGain: 321.36, taxValue: 198.40, dailyGainPercent: 0.46, totalGain: 935.27, totalGainPercent: 1.35),
        WidgetStock(id: "4", name: "SASA", netValue: 18999.94, dailyGain: -626.62, taxValue: 0.0, dailyGainPercent: -3.19, totalGain: -200.0, totalGainPercent: -1.04)
    ], totalPortfolio: 291670.59, totalTax: 348.40, isLoggedIn: true, showTax: true)
}

// MARK: - Firestore Cache Extensions for Widget
extension Query {
    func getDocumentsSmart() async throws -> QuerySnapshot {
        do {
            let cacheSnap = try await self.getDocuments(source: .cache)
            if !cacheSnap.documents.isEmpty {
                return cacheSnap
            }
        } catch {
            // Fallback to server if cache miss
        }
        return try await self.getDocuments(source: .default)
    }
}

