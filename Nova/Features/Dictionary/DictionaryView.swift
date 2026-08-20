import SwiftUI
import UIKit
import AVFoundation
import FirebaseAuth
import FirebaseFirestore

fileprivate func parseFamilyItem(_ item: String) -> (term: String, desc: String) {
    if let openIdx = item.range(of: "(") {
        let term = String(item[..<openIdx.lowerBound]).trimmingCharacters(in: .whitespaces)
        let desc = String(item[openIdx.lowerBound...]).trimmingCharacters(in: .whitespaces)
        return (term, desc)
    }
    return (item, "")
}

// MARK: - Text To Speech Manager

class TextToSpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TextToSpeechManager()
    private let synthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    func speak(_ text: String, language: String = "en-US") {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: cleanText)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }
}

// MARK: - Helper Models (Moved to DictionaryModels.swift)

func parseFirestoreDate(_ val: Any?) -> Date {
    guard let val = val else { return Date.distantPast }
    if let ts = val as? Timestamp {
        return ts.dateValue()
    }
    if let d = val as? Date {
        return d
    }
    if let dict = val as? [String: Any], let sec = dict["seconds"] as? Double {
        let nano = dict["nanoseconds"] as? Double ?? 0
        return Date(timeIntervalSince1970: sec + (nano / 1_000_000_000))
    }
    if let num = val as? Double {
        return num > 1_000_000_000_000 ? Date(timeIntervalSince1970: num / 1000) : Date(timeIntervalSince1970: num)
    }
    if let num = val as? Int {
        let dNum = Double(num)
        return dNum > 1_000_000_000_000 ? Date(timeIntervalSince1970: dNum / 1000) : Date(timeIntervalSince1970: dNum)
    }
    if let str = val as? String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: str) { return d }
        
        let isoStandard = ISO8601DateFormatter()
        if let d = isoStandard.date(from: str) { return d }
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "dd.MM.yyyy HH:mm"] {
            df.dateFormat = fmt
            if let d = df.date(from: str) { return d }
        }
    }
    return Date.distantPast
}

// MARK: - Main Dictionary View

struct DictionaryView: View {
    @State private var selectedTab: String? = nil
    
    // Firestore Data States
    @State private var totalWords: Int = 0
    @State private var newWords: Int = 0
    @State private var learningWords: Int = 0
    @State private var learnedWords: Int = 0
    @State private var recentWords: [LocalWord] = []
    @State private var allWords: [LocalWord] = [] // All words list
    @State private var customLists: [CustomListModel] = [] // Custom lists from DB
    @State private var stickyNotes: [StickyNoteModel] = [] // Sticky notes from DB
    @State private var dailyStatsMap: [String: Any] = [:] // Raw daily stats from DB
    @State private var streakCount: Int = 0
    @State private var isLoading: Bool = false
    @State private var visibleLimit: Int = 10 // Paginated limit for main view
    
    // Search, Filter and Selection States
    @State private var searchText: String = ""
    @State private var showFilterSheet: Bool = false
    @State private var showStreakModal: Bool = false
    @State private var showOnlyDuplicates: Bool = false
    @State private var isSelectionMode: Bool = false
    @State private var selectedWordIds: Set<String> = []
    
    // Active Detail Word state
    @State private var selectedWordForDetail: LocalWord? = nil
    
    // Filter parameters (applied in sheet)
    @State private var filterLanguage: String = "all" // "all", "english", etc.
    @State private var filterStarredOnly: Bool = false
    @State private var filterSortRules: [SortRule] = [] // Multi-level sorting rules
    @State private var filterStatus: String = "all" // "all", "yeni", "ogreniyor", "ogrendi"
    @State private var filterListId: String? = nil // selected custom list ID (nil = all)
    @State private var isSyncingFromRemote: Bool = false
    @State private var settingsListener: ListenerRegistration? = nil
    
    // Sticky Notes Navigation bar Header states
    @State private var stickySearchText: String = ""
    @State private var showStickySearch: Bool = false
    @State private var showStickySettingsSheet: Bool = false
    @State private var practiceViewMode: String = "options"
    
    // Repetition & Slider States
    @AppStorage("unsolved_words_threshold_days") private var unsolvedWordsThresholdDays: Int = 15
    @AppStorage("unsolved_words_max_count") private var unsolvedWordsMaxCount: Double = 15
    @State private var bannerSliderIndex: Int = 0
    
    // Home Dashboard Customization States
    @AppStorage("home_sections_order_v1") private var homeSectionsOrderJSON: String = "[\"banner\",\"tools\",\"words\"]"
    @AppStorage("home_sections_hidden_v1") private var homeSectionsHiddenJSON: String = "[]"
    @State private var isCustomizeMode: Bool = false
    
    private var sectionOrder: [String] {
        if let data = homeSectionsOrderJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        return ["banner", "tools", "words"]
    }
    
    private var hiddenSections: Set<String> {
        if let data = homeSectionsHiddenJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return Set(arr)
        }
        return []
    }
    
    private func saveSectionOrder(_ order: [String]) {
        if let data = try? JSONEncoder().encode(order),
           let str = String(data: data, encoding: .utf8) {
            homeSectionsOrderJSON = str
        }
    }
    
    private func toggleSectionVisibility(_ id: String) {
        var current = hiddenSections
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        if let data = try? JSONEncoder().encode(Array(current)),
           let str = String(data: data, encoding: .utf8) {
            homeSectionsHiddenJSON = str
        }
    }
    
    private func moveSection(id: String, direction: Int) {
        var current = sectionOrder
        guard let idx = current.firstIndex(of: id) else { return }
        let newIdx = idx + direction
        if newIdx >= 0 && newIdx < current.count {
            current.swapAt(idx, newIdx)
            saveSectionOrder(current)
        }
    }
    
    private func getSectionTitle(_ id: String) -> String {
        switch id {
        case "banner": return "Karşılama ve İstatistikler"
        case "tools": return "Sözlük Araçları"
        case "words": return "Filtreleme, Arama ve Kelimelerim"
        default: return "Bölüm"
        }
    }
    
    private var currentMaxCountForThreshold: Int {
        let key = "unsolved_words_max_count_\(unsolvedWordsThresholdDays)"
        let val = UserDefaults.standard.double(forKey: key)
        if val > 0 { return Int(val) }
        return Int(unsolvedWordsMaxCount > 0 ? unsolvedWordsMaxCount : 15)
    }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Top Header Bar
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Sözlük Studio")
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                                
                                Text("PRO")
                                    .font(.system(size: 10, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    .cornerRadius(6)
                            }
                            Text("Kişisel Sözlük ve Öğrenme Arenası")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Interactive Streak Flame Pill
                        let df = DateFormatter()
                        let _ = df.dateFormat = "yyyy-MM-dd"
                        let todayStr = df.string(from: Date())
                        let todayData = dailyStatsMap[todayStr] as? [String: Any] ?? [:]
                        let todaySolvedCount = (todayData["correctCount"] as? NSNumber)?.intValue ?? (todayData["correctCount"] as? Int ?? 0)
                        let isGoalDone = todaySolvedCount >= 100
                        
                        Button(action: {
                            showStreakModal = true
                        }) {
                            HStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(isGoalDone ? Color.red.opacity(0.2) : Color.orange.opacity(0.15))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: isGoalDone ? "flame.fill" : "flame")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(isGoalDone ? .red : .orange)
                                }
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(streakCount) Gün Seri")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                                    Text(isGoalDone ? "HEDEF TAMAM!" : "\(todaySolvedCount)/100 SORU")
                                        .font(.system(size: 8, weight: .heavy))
                                        .foregroundColor(isGoalDone ? .red : .secondary)
                                }
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 10)
                            .padding(.vertical, 5)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    
                    // Featured Word & Progress Hero Card
                    bannerSectionView
                    
                    // Subpages Hub
                    toolsSectionView
                    
                    // All Words & Search Section
                    wordsSectionView
                }
                .padding(.bottom, 36)
            }
            .background(
                Group {
                    NavigationLink(
                        destination: CustomListsSubView(
                            customLists: customLists,
                            onSelectList: { listId in
                                filterListId = listId
                                selectedTab = nil
                            }
                        ),
                        tag: "lists",
                        selection: $selectedTab
                    ) { EmptyView() }
                    
                    NavigationLink(
                        destination: PratikSubView(
                            allWords: $allWords,
                            customLists: effectiveCustomLists,
                            stickyNotes: stickyNotes,
                            viewMode: $practiceViewMode,
                            onSelectWord: { word in
                                selectedWordForDetail = word
                            }
                        ),
                        tag: "pratik",
                        selection: $selectedTab
                    ) { EmptyView() }
                    
                    NavigationLink(
                        destination: StickySubView(
                            stickyNotes: stickyNotes,
                            allWords: allWords,
                            searchText: $stickySearchText,
                            showSettingsSheet: $showStickySettingsSheet,
                            onSelectWord: { word in
                                selectedWordForDetail = word
                            }
                        ),
                        tag: "sticky",
                        selection: $selectedTab
                    ) { EmptyView() }
                }
                .hidden()
            )
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showFilterSheet) {
            FilterSheetView(
                filterLanguage: $filterLanguage,
                filterStarredOnly: $filterStarredOnly,
                filterSortRules: $filterSortRules,
                filterStatus: $filterStatus,
                filterListId: $filterListId,
                customLists: customLists,
                languages: uniqueLanguagesList,
                totalCount: allWords.count,
                languageCounts: languageCounts,
                starredCount: allWords.filter { $0.isStarred }.count,
                filteredCount: applyFilters(allWords).count
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStreakModal) {
            DailyStatsSheetView(dailyStatsMap: dailyStatsMap, allWords: allWords)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedWordForDetail) { word in
            WordDetailSheetView(
                word: word,
                stickyNotes: stickyNotes,
                allWords: allWords,
                onNoteAddedOrDeleted: {
                    loadDictionaryData()
                }
            )
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
            loadFilterSettings()
            loadDictionaryData()
            setupSettingsListener()
        }
        .onDisappear {
            settingsListener?.remove()
            settingsListener = nil
        }
        .onChange(of: filterLanguage) { _ in saveFilterSettings() }
        .onChange(of: filterStarredOnly) { _ in saveFilterSettings() }
        .onChange(of: filterStatus) { _ in saveFilterSettings() }
        .onChange(of: filterListId) { _ in saveFilterSettings() }
        .onChange(of: filterSortRules) { _ in saveFilterSettings() }
        .onChange(of: searchText) { _ in saveFilterSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectDictionarySection"))) { notification in
            if let section = notification.object as? String {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = section
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StartQuickTest"))) { notification in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedTab = "pratik"
            }
            if let testId = notification.object as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: Notification.Name("RunQuickTestInPratik"), object: testId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DictionaryTabReselected"))) { _ in
            if selectedWordForDetail != nil {
                selectedWordForDetail = nil
            }
            if showFilterSheet {
                showFilterSheet = false
            }
            if showStreakModal {
                showStreakModal = false
            }
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if selectedTab == "pratik" {
                    if practiceViewMode != "options" {
                        // Test veya test sonucunda iken -> 1 tık geriye: Pratik Yap menüsüne dön
                        practiceViewMode = "options"
                    } else {
                        // Pratik Yap menüsünde iken -> 1 tık geriye: Sözlük ana sayfasına dön
                        selectedTab = nil
                    }
                } else if selectedTab != nil {
                    // Sticky Notlar veya Listelerim sayfasında iken -> 1 tık geriye: Sözlük ana sayfasına dön
                    selectedTab = nil
                }
            }
        }
    }
    
    private func toggleWordInCustomList(wordId: String, listId: String) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("customLists").document(listId)
        
        if let idx = customLists.firstIndex(where: { $0.id == listId }) {
            var updatedWordIds = customLists[idx].wordIds
            if updatedWordIds.contains(wordId) {
                updatedWordIds.removeAll { $0 == wordId }
            } else {
                updatedWordIds.append(wordId)
            }
            
            // Optimistic update
            customLists[idx] = CustomListModel(id: customLists[idx].id, name: customLists[idx].name, wordIds: updatedWordIds, userId: customLists[idx].userId)
            
            Task {
                try? await ref.updateData(["wordIds": updatedWordIds])
            }
        }
    }
    
    private func setupSettingsListener() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("settings").document("app")
        
        settingsListener?.remove()
        settingsListener = ref.addSnapshotListener { snapshot, error in
            guard let data = snapshot?.data(), snapshot?.exists == true else { return }
            
            DispatchQueue.main.async {
                self.isSyncingFromRemote = true
                
                if let lang = data["filterLanguage"] as? String ?? data["activeLanguageFilter"] as? String {
                    let normLang = (lang.isEmpty || lang == "all") ? "all" : lang
                    if self.filterLanguage != normLang {
                        self.filterLanguage = normLang
                    }
                }
                
                if let starred = data["filterStarredOnly"] as? Bool ?? data["showOnlyStarred"] as? Bool {
                    if self.filterStarredOnly != starred {
                        self.filterStarredOnly = starred
                    }
                }
                
                if let status = data["filterStatus"] as? String ?? data["quickStatusFilter"] as? String {
                    let normStatus: String
                    let lower = status.lowercased()
                    if lower == "yeni" { normStatus = "yeni" }
                    else if lower == "ogreniyor" || lower == "öğreniyor" { normStatus = "ogreniyor" }
                    else if lower == "ogrendi" || lower == "öğrendi" { normStatus = "ogrendi" }
                    else { normStatus = "all" }
                    
                    if self.filterStatus != normStatus {
                        self.filterStatus = normStatus
                    }
                }
                
                if let listId = data["filterListId"] as? String {
                    let normListId = listId.isEmpty ? nil : listId
                    if self.filterListId != normListId {
                        self.filterListId = normListId
                    }
                }
                
                if let search = data["searchQuery"] as? String {
                    if self.searchText != search {
                        self.searchText = search
                    }
                }
                
                if let rawSortRules = data["sortRules"] as? [[String: Any]] {
                    var parsedRules: [SortRule] = []
                    for item in rawSortRules {
                        if let field = item["field"] as? String, let dir = item["direction"] as? String {
                            parsedRules.append(SortRule(field: field, direction: dir))
                        }
                    }
                    if self.filterSortRules.map({ $0.field + $0.direction }) != parsedRules.map({ $0.field + $0.direction }) {
                        self.filterSortRules = parsedRules
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isSyncingFromRemote = false
                }
            }
        }
    }
    
    private func loadFilterSettings() {
        let defaults = UserDefaults.standard
        if let lang = defaults.string(forKey: "dictionary_saved_filterLanguage") {
            self.filterLanguage = lang
        }
        if defaults.object(forKey: "dictionary_saved_filterStarredOnly") != nil {
            self.filterStarredOnly = defaults.bool(forKey: "dictionary_saved_filterStarredOnly")
        }
        if let status = defaults.string(forKey: "dictionary_saved_filterStatus") {
            self.filterStatus = status
        }
        if let listId = defaults.string(forKey: "dictionary_saved_filterListId") {
            self.filterListId = listId.isEmpty ? nil : listId
        }
        if let search = defaults.string(forKey: "dictionary_saved_searchQuery") {
            self.searchText = search
        }
        if let sortData = defaults.data(forKey: "dictionary_saved_filterSortRules"),
           let rules = try? JSONDecoder().decode([SortRule].self, from: sortData) {
            self.filterSortRules = rules
        }
    }

    private func saveFilterSettings() {
        let defaults = UserDefaults.standard
        defaults.set(filterLanguage, forKey: "dictionary_saved_filterLanguage")
        defaults.set(filterStarredOnly, forKey: "dictionary_saved_filterStarredOnly")
        defaults.set(filterStatus, forKey: "dictionary_saved_filterStatus")
        defaults.set(filterListId ?? "", forKey: "dictionary_saved_filterListId")
        defaults.set(searchText, forKey: "dictionary_saved_searchQuery")
        if let encoded = try? JSONEncoder().encode(filterSortRules) {
            defaults.set(encoded, forKey: "dictionary_saved_filterSortRules")
        }
        
        guard !isSyncingFromRemote, let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("settings").document("app")
        
        var sortRulesArray: [[String: String]] = []
        for r in filterSortRules {
            sortRulesArray.append(["field": r.field, "direction": r.direction])
        }
        
        let webStatus: String
        switch filterStatus {
        case "yeni": webStatus = "Yeni"
        case "ogreniyor": webStatus = "Öğreniyor"
        case "ogrendi": webStatus = "Öğrendi"
        default: webStatus = ""
        }
        
        let payload: [String: Any] = [
            "filterLanguage": filterLanguage,
            "activeLanguageFilter": filterLanguage == "all" ? "" : filterLanguage,
            "filterStarredOnly": filterStarredOnly,
            "showOnlyStarred": filterStarredOnly,
            "filterStatus": filterStatus,
            "quickStatusFilter": webStatus,
            "filterListId": filterListId ?? "",
            "searchQuery": searchText,
            "sortRules": sortRulesArray
        ]
        
        ref.setData(payload, merge: true)
    }
    
    private var hasActiveFilters: Bool {
        filterLanguage != "all" || filterStarredOnly || filterStatus != "all" || !filterSortRules.isEmpty || showOnlyDuplicates || filterListId != nil
    }
    
    private func resetAllFilters() {
        filterLanguage = "all"
        filterStarredOnly = false
        filterStatus = "all"
        filterSortRules.removeAll()
        showOnlyDuplicates = false
        filterListId = nil
    }
    
    @ViewBuilder
    private func filterIndicator(text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.blue)
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(6)
    }
    
    private var uniqueLanguagesList: [String] {
        let langs = allWords.compactMap { $0.language.isEmpty ? nil : $0.language }
        return Array(Set(langs)).sorted()
    }
    
    private var languageCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for w in allWords {
            if !w.language.isEmpty {
                counts[w.language, default: 0] += 1
            }
        }
        return counts
    }
    
    private var duplicateIds: Set<String> {
        var dups = Set<String>()
        var termMap = [String: [String]]()
        for w in allWords {
            let term = w.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            termMap[term, default: []].append(w.id)
        }
        for (_, ids) in termMap {
            if ids.count > 1 {
                ids.forEach { dups.insert($0) }
            }
        }
        return dups
    }
    
    private func applyFilters(_ list: [LocalWord]) -> [LocalWord] {
        var result = list
        
        // 1. Filter by Selected Custom List (wordIds)
        if let listId = filterListId, let selectedList = customLists.first(where: { $0.id == listId }) {
            let allowedIds = Set(selectedList.wordIds)
            result = result.filter { allowedIds.contains($0.id) }
        }
        
        // 2. Search term
        if !searchText.isEmpty {
            let term = searchText.lowercased()
            result = result.filter {
                $0.term.lowercased().contains(term) || $0.shortMeanings.lowercased().contains(term)
            }
        }
        
        // 3. Language
        if filterLanguage != "all" {
            result = result.filter { $0.language.lowercased() == filterLanguage.lowercased() }
        }
        
        // 4. Starred
        if filterStarredOnly {
            result = result.filter { $0.isStarred }
        }
        
        // 5. Duplicate
        if showOnlyDuplicates {
            let dups = duplicateIds
            result = result.filter { dups.contains($0.id) }
        }
        
        // 6. Status
        if filterStatus != "all" {
            switch filterStatus {
            case "yeni":
                result = result.filter { $0.learningStage == 0 }
            case "ogreniyor":
                result = result.filter { $0.learningStage > 0 && $0.learningStage < 10 }
            case "ogrendi":
                result = result.filter { $0.learningStage >= 10 }
            default:
                break
            }
        }
        
        // 7. Multi-level sorting application
        if filterSortRules.isEmpty {
            result.sort { a, b in
                if a.createdAt != b.createdAt {
                    return a.createdAt > b.createdAt
                }
                return a.term.localizedCompare(b.term) == .orderedAscending
            }
        } else {
            result.sort { a, b in
                for rule in filterSortRules {
                    let isAsc = rule.direction == "asc"
                    switch rule.field {
                    case "term":
                        let cmp = a.term.localizedCompare(b.term)
                        if cmp != .orderedSame {
                            return isAsc ? cmp == .orderedAscending : cmp == .orderedDescending
                        }
                    case "createdAt":
                        let aTime = a.createdAt.timeIntervalSince1970
                        let bTime = b.createdAt.timeIntervalSince1970
                        if aTime != bTime {
                            return isAsc ? aTime < bTime : aTime > bTime
                        }
                    case "learningStage":
                        if a.learningStage != b.learningStage {
                            return isAsc ? a.learningStage < b.learningStage : a.learningStage > b.learningStage
                        }
                    default:
                        break
                    }
                }
                let cmp = a.term.localizedCompare(b.term)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return a.createdAt > b.createdAt
            }
        }
        
        return result
    }
    
    private func extractTurkishPronunciation(_ pron: String) -> String {
        if let openParen = pron.range(of: "("), let closeParen = pron.range(of: ")") {
            let inside = pron[openParen.upperBound..<closeParen.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty { return inside }
        }
        let cleaned = pron.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned
    }
    
    private var unsolvedWords: [UnsolvedWordItem] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        
        var latestSolvedMap: [String: Date] = [:]
        for (dateStr, val) in dailyStatsMap {
            guard let date = df.date(from: dateStr),
                  let dict = val as? [String: Any],
                  let wordsMap = dict["words"] as? [String: Any] else { continue }
            
            for (wId, wData) in wordsMap {
                if let wDict = wData as? [String: Any] {
                    let correct = (wDict["correct"] as? NSNumber)?.intValue ?? (wDict["correct"] as? Int ?? 0)
                    let incorrect = (wDict["incorrect"] as? NSNumber)?.intValue ?? (wDict["incorrect"] as? Int ?? 0)
                    if correct > 0 || incorrect > 0 {
                        if let existing = latestSolvedMap[wId] {
                            if date > existing {
                                latestSolvedMap[wId] = date
                            }
                        } else {
                            latestSolvedMap[wId] = date
                        }
                    }
                }
            }
        }
        
        let now = Date()
        let calendar = Calendar.current
        var items: [UnsolvedWordItem] = []
        
        for word in allWords {
            if let lastDate = latestSolvedMap[word.id] {
                let days = calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0
                if days >= unsolvedWordsThresholdDays {
                    items.append(UnsolvedWordItem(word: word, lastSolvedDate: lastDate, daysSinceLastSolved: days))
                }
            } else {
                items.append(UnsolvedWordItem(word: word, lastSolvedDate: nil, daysSinceLastSolved: nil))
            }
        }
        
        items.sort { a, b in
            if a.daysSinceLastSolved == nil && b.daysSinceLastSolved == nil {
                return a.word.createdAt < b.word.createdAt
            }
            if a.daysSinceLastSolved == nil { return true }
            if b.daysSinceLastSolved == nil { return false }
            return a.daysSinceLastSolved! > b.daysSinceLastSolved!
        }
        
        return Array(items.prefix(currentMaxCountForThreshold))
    }
    
    private var effectiveCustomLists: [CustomListModel] {
        var lists = customLists
        let unsolvedIds = unsolvedWords.map { $0.word.id }
        if !unsolvedIds.isEmpty {
            lists.insert(
                CustomListModel(
                    id: "smart_unsolved",
                    name: "🕒 Unutulanlar (\(unsolvedWordsThresholdDays)+ Gün)",
                    wordIds: unsolvedIds,
                    userId: Auth.auth().currentUser?.uid ?? ""
                ),
                at: 0
            )
        }
        return lists
    }
    
    private func launchUnsolvedPracticeTest() {
        let unsolvedIds = unsolvedWords.map { $0.word.id }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedTab = "pratik"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(
                name: Notification.Name("StartUnsolvedTest"),
                object: unsolvedIds
            )
        }
    }
    
    @ViewBuilder
    private var bannerSectionView: some View {
        VStack(spacing: 12) {
            // Header Row (Section Title on left, Fixed "Test Yap" Button on right)
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.orange)
                    
                    Text("TEKRAR EDİLECEK KELİMELER")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.2))
                    
                    if !unsolvedWords.isEmpty {
                        Text("\(unsolvedWords.count)")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .cornerRadius(10)
                    }
                }
                
                Spacer()
                
                // Fixed "Test Yap" button
                Button(action: {
                    launchUnsolvedPracticeTest()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .black))
                        Text("Test Yap")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.9, green: 0.3, blue: 0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(14)
                    .shadow(color: Color.orange.opacity(0.35), radius: 6, x: 0, y: 3)
                }
            }
            .padding(.horizontal, 4)
            
            // Slider / Paging Carousel or Empty State Card
            if unsolvedWords.isEmpty {
                // Empty state card (No unpracticed words)
                VStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                        Text("Tüm Kelimeler Güncel!")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    Text("Son \(unsolvedWordsThresholdDays) gündür çözülmemiş hiçbir kelimeniz bulunmuyor. Düzenli çalıştığınız için harikasınız!")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding(.vertical, 26)
                .background(
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.08, green: 0.28, blue: 0.22),
                                Color(red: 0.12, green: 0.42, blue: 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Circle()
                            .fill(Color.green.opacity(0.25))
                            .frame(width: 140, height: 140)
                            .blur(radius: 25)
                            .offset(x: 100, y: -20)
                    }
                )
                .cornerRadius(22)
                .shadow(color: Color(red: 0.08, green: 0.28, blue: 0.22).opacity(0.3), radius: 12, x: 0, y: 5)
            } else {
                TabView(selection: $bannerSliderIndex) {
                    ForEach(Array(unsolvedWords.enumerated()), id: \.element.id) { index, item in
                        let word = item.word
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                // Status badge
                                HStack(spacing: 4) {
                                    if let days = item.daysSinceLastSolved {
                                        Image(systemName: "clock.badge.exclamationmark.fill")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("\(days) GÜNDÜR ÇÖZÜLMEDİ")
                                            .font(.system(size: 9, weight: .heavy))
                                            .tracking(0.5)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("HİÇ ÇÖZÜLMEDİ")
                                            .font(.system(size: 9, weight: .heavy))
                                            .tracking(0.5)
                                    }
                                }
                                .foregroundColor(item.daysSinceLastSolved == nil ? Color(red: 1.0, green: 0.85, blue: 0.4) : .white.opacity(0.95))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    item.daysSinceLastSolved == nil
                                        ? Color.orange.opacity(0.25)
                                        : Color.white.opacity(0.18)
                                )
                                .cornerRadius(8)
                                
                                Spacer()
                                
                                Button(action: {
                                    TextToSpeechManager.shared.speak(word.term)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "speaker.wave.3.fill")
                                            .font(.system(size: 12))
                                        Text("Dinle")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(12)
                                }
                            }
                            
                            HStack(alignment: .lastTextBaseline, spacing: 10) {
                                Text(word.term)
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                
                                let trPron = extractTurkishPronunciation(word.pronunciation)
                                if !trPron.isEmpty {
                                    Text("(\(trPron))")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                
                                Spacer()
                            }
                            
                            if !word.shortMeanings.isEmpty {
                                Text(word.shortMeanings)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(2)
                            }
                            
                            Spacer(minLength: 4)
                            
                            // Stage progress bar
                            HStack(spacing: 8) {
                                Text("Öğrenme Aşaması")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.8))
                                
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.2))
                                            .frame(height: 5)
                                        Capsule()
                                            .fill(Color.white)
                                            .frame(width: geo.size.width * CGFloat(Double(word.learningStage) / 10.0), height: 5)
                                    }
                                }
                                .frame(height: 5)
                                
                                Text("\(word.learningStage)/10")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 34)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(
                            ZStack {
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.16, blue: 0.36),
                                        Color(red: 0.22, green: 0.32, blue: 0.65)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                
                                Circle()
                                    .fill(Color.blue.opacity(0.3))
                                    .frame(width: 160, height: 160)
                                    .blur(radius: 30)
                                    .offset(x: 120, y: -30)
                            }
                        )
                        .cornerRadius(22)
                        .shadow(color: Color(red: 0.12, green: 0.16, blue: 0.36).opacity(0.3), radius: 12, x: 0, y: 5)
                        .tag(index)
                        .onTapGesture {
                            selectedWordForDetail = word
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: 215)
            }
            
            // 4 Stats Hub Grid (2x2)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    statBox(title: "TOPLAM KELİME", count: totalWords, icon: "book.closed.fill", color: .blue)
                    statBox(title: "YENİ KELİMELER", count: newWords, icon: "plus.circle.fill", color: Color(red: 0.2, green: 0.6, blue: 0.9))
                }
                HStack(spacing: 8) {
                    statBox(title: "ÖĞRENİLİYOR", count: learningWords, icon: "hourglass.badge.plus", color: .orange)
                    statBox(title: "ÖĞRENİLENLER", count: learnedWords, icon: "checkmark.seal.fill", color: Color(red: 0.08, green: 0.6, blue: 0.25))
                }
            }
        }
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    private var toolsSectionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SÖZLÜK MODÜLLERİ & ALT SAYFALAR")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            
            VStack(spacing: 12) {
                dictSubPageCard(
                    title: "Özel Listelerim",
                    subtitle: "\(customLists.count) Oluşturulmuş Özel Kelime Listesi",
                    tag: "lists",
                    icon: "folder.fill",
                    color: .blue
                )
                
                dictSubPageCard(
                    title: "Pratik Yap & Test Arenası",
                    subtitle: "\(allWords.count) Kelime ile Soru, Kart & Yazma Pratiği",
                    tag: "pratik",
                    icon: "gamecontroller.fill",
                    color: Color(red: 0.08, green: 0.6, blue: 0.25)
                )
                
                dictSubPageCard(
                    title: "Sticky Notlarım",
                    subtitle: "\(stickyNotes.count) Kayıtlı Özel Not ve Çalışma Kartı",
                    tag: "sticky",
                    icon: "note.text",
                    color: .orange
                )
            }
            .padding(.horizontal, 16)
        }
    }
    
    @ViewBuilder
    private var wordsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KELİME KATALOĞU")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            
            // Search & Filter controls row
            HStack(spacing: 8) {
                Button(action: { showFilterSheet = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Filtrele")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(10)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    TextField("Kelime veya anlam ara...", text: $searchText)
                        .font(.system(size: 13))
                        .submitLabel(.search)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.04))
                .cornerRadius(10)
                
                Button(action: {
                    withAnimation {
                        showOnlyDuplicates.toggle()
                    }
                }) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(showOnlyDuplicates ? .blue : .secondary)
                        .padding(8)
                        .background(showOnlyDuplicates ? Color.blue.opacity(0.08) : Color.black.opacity(0.04))
                        .cornerRadius(10)
                }
                
                Button(action: {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedWordIds.removeAll()
                    }
                }) {
                    Text(isSelectionMode ? "Vazgeç" : "Seç")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(isSelectionMode ? .red : .blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelectionMode ? Color.red.opacity(0.08) : Color.blue.opacity(0.08))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 16)
            
            if hasActiveFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if filterLanguage != "all" {
                            filterIndicator(text: "Dil: \(filterLanguage.capitalized)") { filterLanguage = "all" }
                        }
                        if filterStarredOnly {
                            filterIndicator(text: "Yıldızlılar") { filterStarredOnly = false }
                        }
                        if filterStatus != "all" {
                            filterIndicator(text: "Durum: \(filterStatus.uppercased())") { filterStatus = "all" }
                        }
                        if filterListId != nil {
                            let name = customLists.first(where: { $0.id == filterListId })?.name ?? "Liste"
                            filterIndicator(text: "Liste: \(name)") { filterListId = nil }
                        }
                        if !filterSortRules.isEmpty {
                            filterIndicator(text: "Sıralama (\(filterSortRules.count))") { filterSortRules.removeAll() }
                        }
                        if showOnlyDuplicates {
                            filterIndicator(text: "Tekrar Edenler") { showOnlyDuplicates = false }
                        }
                        
                        Button(action: resetAllFilters) {
                            Text("Temizle")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            
            let filteredList = applyFilters(allWords)
            
            Text("KELİMELERİM (\(filteredList.count))")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            
            if isLoading && allWords.isEmpty {
                ProgressView("Kelimeler yükleniyor...")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else if filteredList.isEmpty {
                Text(allWords.isEmpty ? "Sözlüğünüzde henüz kelime yok." : "Aranan kriterlere uygun kelime bulunamadı.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(filteredList.prefix(visibleLimit)) { word in
                        WordCardView(
                            word: word,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedWordIds.contains(word.id),
                            customLists: customLists,
                            hasStickyNote: stickyNotes.contains(where: { $0.wordId == word.id || (!$0.wordTerm.isEmpty && $0.wordTerm.lowercased() == word.term.lowercased()) }),
                            onSelectToggle: {
                                if selectedWordIds.contains(word.id) {
                                    selectedWordIds.remove(word.id)
                                } else {
                                    selectedWordIds.insert(word.id)
                                }
                            },
                            onToggleCustomList: { listId in
                                toggleWordInCustomList(wordId: word.id, listId: listId)
                            }
                        )
                        .onTapGesture {
                            if isSelectionMode {
                                if selectedWordIds.contains(word.id) {
                                    selectedWordIds.remove(word.id)
                                } else {
                                    selectedWordIds.insert(word.id)
                                }
                            } else {
                                selectedWordForDetail = word
                            }
                        }
                        .onAppear {
                            if word.id == filteredList.prefix(visibleLimit).last?.id && visibleLimit < filteredList.count {
                                withAnimation {
                                    visibleLimit = min(visibleLimit + 10, filteredList.count)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
    
    @ViewBuilder
    private func statBox(title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 34, height: 34)
                
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.08), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func dictSubPageCard(title: String, subtitle: String, tag: String, icon: String, color: Color) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedTab = tag
            }
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.1))
                        .frame(width: 42, height: 42)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                        .multilineTextAlignment(.leading)
                    
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.gray.opacity(0.4))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.gray.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
        }
    }
    
    private var subscreenTitle: String {
        switch selectedTab {
        case "lists": return "Özel Listelerim"
        case "pratik": return "Pratik Yap"
        case "sticky": return "Sticky Notlarım"
        default: return "Sözlük"
        }
    }
    
    private func parseFirestoreDate(_ val: Any?) -> Date {
        guard let val = val else { return Date.distantPast }
        if let ts = val as? Timestamp {
            return ts.dateValue()
        }
        if let d = val as? Date {
            return d
        }
        if let dict = val as? [String: Any], let sec = dict["seconds"] as? Double {
            let nano = dict["nanoseconds"] as? Double ?? 0
            return Date(timeIntervalSince1970: sec + (nano / 1_000_000_000))
        }
        if let num = val as? Double {
            return num > 1_000_000_000_000 ? Date(timeIntervalSince1970: num / 1000) : Date(timeIntervalSince1970: num)
        }
        if let num = val as? Int {
            let dNum = Double(num)
            return dNum > 1_000_000_000_000 ? Date(timeIntervalSince1970: dNum / 1000) : Date(timeIntervalSince1970: dNum)
        }
        if let str = val as? String {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFormatter.date(from: str) { return d }
            
            let isoStandard = ISO8601DateFormatter()
            if let d = isoStandard.date(from: str) { return d }
            
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "dd.MM.yyyy HH:mm"] {
                df.dateFormat = fmt
                if let d = df.date(from: str) { return d }
            }
        }
        return Date.distantPast
    }
    
    private func loadDictionaryData() {
        guard let user = Auth.auth().currentUser else { return }
        self.isLoading = true
        
        let db = Firestore.firestore()
        
        Task {
            do {
                // 1. Fetch Custom Lists from user's subcollection
                let listsSnap = try await db.collection("users").document(user.uid).collection("customLists").getDocumentsSmart()
                var fetchedCustomLists: [CustomListModel] = []
                for doc in listsSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? ""
                    let wordIds = data["wordIds"] as? [String] ?? []
                    let uId = data["userId"] as? String ?? ""
                    
                    fetchedCustomLists.append(CustomListModel(id: id, name: name, wordIds: wordIds, userId: uId))
                }
                self.customLists = fetchedCustomLists
                
                // 2. Fetch Sticky Notes from user's subcollection
                let notesSnap = try await db.collection("users").document(user.uid).collection("stickyNotes").getDocumentsSmart()
                var fetchedNotes: [StickyNoteModel] = []
                for doc in notesSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let title = data["title"] as? String ?? ""
                    let text = data["text"] as? String ?? data["content"] as? String ?? ""
                    let wordTerm = data["wordTerm"] as? String ?? ""
                    let wordId = data["wordId"] as? String ?? ""
                    let createdAtVal = parseFirestoreDate(data["createdAt"])
                    
                    fetchedNotes.append(StickyNoteModel(id: id, title: title, text: text, wordTerm: wordTerm, wordId: wordId, createdAt: createdAtVal))
                }
                self.stickyNotes = fetchedNotes.sorted(by: { $0.createdAt > $1.createdAt })
                
                // 3. Fetch Words
                let wordsSnap = try await db.collection("users").document(user.uid).collection("words").getDocumentsSmart()
                
                var allWordsList: [LocalWord] = []
                for doc in wordsSnap.documents {
                    let data = doc.data()
                    let id = doc.documentID
                    let term = data["term"] as? String ?? ""
                    let shortMeanings = data["shortMeanings"] as? String ?? ""
                    let stage = data["learningStage"] as? Int ?? 0
                    let level = data["level"] as? String ?? "B2"
                    let starred = data["isStarred"] as? Bool ?? false
                    let pron = data["pronunciation"] as? String ?? ""
                    let lang = data["language"] as? String ?? data["lang"] as? String ?? "english"
                    let note = data["specialNote"] as? String ?? ""
                    let conj = data["conjugation"] as? String ?? ""
                    
                    // Parse lists/arrays
                    let collocations = data["collocations"] as? [String] ?? []
                    let wordFamily = data["wordFamily"] as? [String] ?? []
                    
                    // Parse meanings with definitions and examples
                    var parsedMeanings: [WordMeaning] = []
                    if let rawMeanings = data["meanings"] as? [[String: Any]] {
                        for m in rawMeanings {
                            let def = m["definition"] as? String ?? ""
                            var parsedExamples: [WordExample] = []
                            if let rawExamples = m["examples"] as? [Any] {
                                for ex in rawExamples {
                                    if let exMap = ex as? [String: String] {
                                        parsedExamples.append(WordExample(en: exMap["en"] ?? "", tr: exMap["tr"] ?? ""))
                                    } else if let exStr = ex as? String {
                                        parsedExamples.append(WordExample(en: exStr, tr: ""))
                                    }
                                }
                            }
                            parsedMeanings.append(WordMeaning(definition: def, examples: parsedExamples))
                        }
                    }
                    
                    let parsedSynonyms = parseRelations(data["synonyms"])
                    let parsedAntonyms = parseRelations(data["antonyms"])
                    let createdAtVal = parseFirestoreDate(data["createdAt"])
                    
                    if !term.isEmpty {
                        allWordsList.append(
                            LocalWord(
                                id: id,
                                term: term,
                                shortMeanings: shortMeanings,
                                pronunciation: pron,
                                level: level,
                                isStarred: starred,
                                learningStage: stage,
                                createdAt: createdAtVal,
                                language: lang,
                                meanings: parsedMeanings,
                                synonyms: parsedSynonyms,
                                antonyms: parsedAntonyms,
                                collocations: collocations,
                                wordFamily: wordFamily,
                                specialNote: note,
                                conjugation: conj
                            )
                        )
                    }
                }
                
                let sorted = allWordsList.sorted { a, b in
                    if a.createdAt != b.createdAt {
                        return a.createdAt > b.createdAt
                    }
                    return a.term.localizedCompare(b.term) == .orderedAscending
                }
                self.allWords = sorted
                self.totalWords = allWordsList.count
                self.newWords = allWordsList.filter { $0.learningStage == 0 }.count
                self.learningWords = allWordsList.filter { $0.learningStage > 0 && $0.learningStage < 10 }.count
                self.learnedWords = allWordsList.filter { $0.learningStage >= 10 }.count
                self.recentWords = Array(sorted.prefix(5))
                
                // 4. Fetch Daily Stats
                let statsSnap = try await db.collection("users").document(user.uid).collection("daily_stats").getDocumentsSmart()
                var dailyStatsDict: [String: Any] = [:]
                var correctCountsDict: [String: Int] = [:]
                for doc in statsSnap.documents {
                    let data = doc.data()
                    let dateStr = doc.documentID
                    dailyStatsDict[dateStr] = data
                    if let count = (data["correctCount"] as? NSNumber)?.intValue ?? (data["correctCount"] as? Int) {
                        correctCountsDict[dateStr] = count
                    }
                }
                self.dailyStatsMap = dailyStatsDict
                
                var streak = 0
                var d = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let todayStr = formatter.string(from: d)
                let todayCount = correctCountsDict[todayStr] ?? 0
                if todayCount >= 100 { streak += 1 }
                
                d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
                while true {
                    let pastStr = formatter.string(from: d)
                    let pastCount = correctCountsDict[pastStr] ?? 0
                    if pastCount >= 100 {
                        streak += 1
                        d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
                    } else {
                        break
                    }
                }
                
                self.streakCount = streak
                self.isLoading = false
            } catch {
                print("Error loading dictionary dashboard details: \(error)")
                self.isLoading = false
            }
        }
    }
    
    private func parseRelations(_ raw: Any?) -> [WordRelation] {
        guard let raw = raw else { return [] }
        var results: [WordRelation] = []
        
        if let str = raw as? String, !str.isEmpty {
            let sep = str.contains(",,") ? ",," : ","
            let items = str.components(separatedBy: sep)
            for item in items {
                let parts = item.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if let w = parts.first, !w.isEmpty {
                    let m = parts.count > 1 ? parts[1] : ""
                    results.append(WordRelation(word: w, meaning: m))
                }
            }
        } else if let arr = raw as? [Any] {
            for item in arr {
                if let map = item as? [String: String] {
                    let w = map["word"] ?? map["en"] ?? ""
                    let m = map["meaning"] ?? map["tr"] ?? ""
                    if !w.isEmpty {
                        results.append(WordRelation(word: w, meaning: m))
                    }
                } else if let s = item as? String, !s.isEmpty {
                    let parts = s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if let w = parts.first, !w.isEmpty {
                        let m = parts.count > 1 ? parts[1] : ""
                        results.append(WordRelation(word: w, meaning: m))
                    }
                }
            }
        }
        return results
    }
}

// MARK: - Daily Stats & Filter Sheet Views (Moved to Features/Dictionary/DailyStatsSheetView.swift and FilterSheetView.swift)

// MARK: - Word Detail Sheet Modal Implementation

struct WordDetailSheetView: View {
    @Environment(\.dismiss) var dismiss
    let word: LocalWord
    var stickyNotes: [StickyNoteModel] = []
    var allWords: [LocalWord] = []
    var onNoteAddedOrDeleted: (() -> Void)? = nil
    
    @State private var localNotes: [StickyNoteModel] = []
    @State private var isAddingNote: Bool = false
    @State private var newNoteTitle: String = ""
    @State private var newNoteText: String = ""
    @State private var isSavingNote: Bool = false
    
    var wordNotes: [StickyNoteModel] {
        localNotes.filter { n in
            n.wordId == word.id || (!n.wordTerm.isEmpty && n.wordTerm.lowercased() == word.term.lowercased())
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // 1. Hero Header
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text(word.term)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.black.opacity(0.85))
                            
                            Spacer()
                            
                            // Star indicator
                            Image(systemName: word.isStarred ? "star.fill" : "star")
                                .font(.system(size: 22))
                                .foregroundColor(word.isStarred ? .orange : .secondary.opacity(0.4))
                        }
                        
                        HStack(spacing: 8) {
                            // Stage Badge
                            Text(getStatusLabel(word.learningStage))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(getStatusColor(word.learningStage))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(getStatusColor(word.learningStage).opacity(0.1))
                                .cornerRadius(8)
                            
                            // Level Badge
                            Text("CEFR: \(word.level)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.04))
                                .cornerRadius(8)
                            
                            // Language Badge
                            Text(word.language.capitalized)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.06))
                                .cornerRadius(8)
                        }
                        
                        let trPron = extractTurkishPronunciation(word.pronunciation)
                        if !trPron.isEmpty {
                            Button(action: {
                                TextToSpeechManager.shared.speak(word.term)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 14))
                                    Text(trPron)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                }
                                .foregroundColor(.blue.opacity(0.8))
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(18)
                    .background(Color.white)
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.015), radius: 5, x: 0, y: 3)
                    
                    // 2. Meanings Section
                    if let meanings = word.meanings, !meanings.isEmpty {
                        detailBlock(title: "KELİME ANLAMLARI", icon: "bookmark.fill", iconColor: .green) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(meanings.enumerated()), id: \.offset) { idx, m in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(idx + 1).")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.green)
                                            .frame(width: 20, alignment: .leading)
                                        
                                        Text(m.definition)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                    }
                    
                    // 3. Examples Section (With TTS Read Out button)
                    if let meanings = word.meanings {
                        let examples = meanings.flatMap { $0.examples }.filter { !$0.en.isEmpty }
                        if !examples.isEmpty {
                            detailBlock(title: "ÖRNEK CÜMLELER", icon: "quote.bubble.fill", iconColor: .blue) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(examples) { ex in
                                        HStack(alignment: .top, spacing: 8) {
                                            Button(action: {
                                                TextToSpeechManager.shared.speak(ex.en)
                                            }) {
                                                Image(systemName: "speaker.wave.2")
                                                    .font(.system(size: 14))
                                                    .foregroundColor(.blue.opacity(0.8))
                                                    .padding(.top, 2)
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("\"\(ex.en)\"")
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                
                                                if !ex.tr.isEmpty {
                                                    Text(ex.tr)
                                                        .font(.system(size: 12, design: .rounded))
                                                        .foregroundColor(.secondary)
                                                        .italic()
                                                        .padding(.top, 2)
                                                }
                                            }
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.blue.opacity(0.02))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.blue.opacity(0.08), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // 4. Synonyms & Antonyms (Fixed display logic for empty items)
                    if let syns = word.synonyms, !syns.filter({ !$0.word.isEmpty }).isEmpty {
                        detailBlock(title: "EŞ ANLAMlILAR", icon: "shuffle", iconColor: .purple) {
                            FlowLayoutView(items: syns.filter { !$0.word.isEmpty }.map { $0.meaning.isEmpty ? $0.word : "\($0.word) (\($0.meaning))" }) { item in
                                Text(item)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.purple)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.purple.opacity(0.08))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    
                    if let ants = word.antonyms, !ants.filter({ !$0.word.isEmpty }).isEmpty {
                        detailBlock(title: "ZIT ANLAMlILAR", icon: "arrow.left.and.right", iconColor: .red) {
                            FlowLayoutView(items: ants.filter { !$0.word.isEmpty }.map { $0.meaning.isEmpty ? $0.word : "\($0.word) (\($0.meaning))" }) { item in
                                Text(item)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.red.opacity(0.08))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    
                    // 5. Collocations
                    if let collocations = word.collocations, !collocations.filter({ !$0.isEmpty }).isEmpty {
                        detailBlock(title: "KALIPLAR VE ÖBEKLER", icon: "hash", iconColor: .orange) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(collocations.filter { !$0.isEmpty }, id: \.self) { c in
                                    Text(c)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(.primary)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    
                    // 6. Word Family (Safely parsed to avoid String Index Out Of Bounds crash)
                    if let wordFamily = word.wordFamily, !wordFamily.filter({ !$0.isEmpty }).isEmpty {
                        detailBlock(title: "KELİME AİLESİ (WORD FAMILY)", icon: "network", iconColor: .blue) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(wordFamily.filter { !$0.isEmpty }, id: \.self) { rawItem in
                                        let parsed = parseFamilyItem(rawItem)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(parsed.term)
                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                .foregroundColor(.blue)
                                            if !parsed.desc.isEmpty {
                                                Text(parsed.desc)
                                                    .font(.system(size: 10, design: .rounded))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.blue.opacity(0.05))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // 7. Conjugations & Grammars (Filtered out "N/A")
                    if let specialNote = word.specialNote, !specialNote.isEmpty && specialNote != "N/A" {
                        detailBlock(title: "DİL BİLGİSİ / KELİME NOTU", icon: "info.circle.fill", iconColor: .cyan) {
                            Text(specialNote)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                                .padding(12)
                                .background(Color.cyan.opacity(0.05))
                                .cornerRadius(10)
                        }
                    }
                    
                    if let conj = word.conjugation, !conj.isEmpty && conj != "N/A" {
                        detailBlock(title: "KELİME ÇEKİMLERİ", icon: "filepattern.regular", iconColor: .secondary) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(conj.components(separatedBy: "|"), id: \.self) { item in
                                    Text(item)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    // 8. Sticky Notes Section
                    detailBlock(title: "STICKY NOTLARIM (\(wordNotes.count))", icon: "note.text", iconColor: .orange) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(wordNotes.isEmpty ? "Bu kelimeye henüz not eklenmemiş." : "\(wordNotes.count) adet ilişkili not var")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isAddingNote.toggle()
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isAddingNote ? "minus.circle.fill" : "plus.circle.fill")
                                            .font(.system(size: 13))
                                        Text(isAddingNote ? "İptal" : "Not Ekle")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(12)
                                }
                            }
                            
                            if isAddingNote {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("YENİ STICKY NOT EKLE")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.orange)
                                        .tracking(0.5)
                                    
                                    TextField("Başlık / Yorum ekle (Opsiyonel)", text: $newNoteTitle)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .padding(10)
                                        .background(Color.white)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                        )
                                    
                                    TextField("Notunuzu buraya yazın...", text: $newNoteText, axis: .vertical)
                                        .font(.system(size: 13, design: .rounded))
                                        .lineLimit(3...6)
                                        .padding(10)
                                        .background(Color.white)
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                        )
                                    
                                    HStack {
                                        Spacer()
                                        
                                        Button(action: {
                                            saveNewNote()
                                        }) {
                                            if isSavingNote {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                    .frame(width: 60)
                                            } else {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 12, weight: .bold))
                                                    Text("Kaydet")
                                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                                }
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 7)
                                                .background(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.5) : Color.orange)
                                                .cornerRadius(14)
                                            }
                                        }
                                        .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingNote)
                                    }
                                }
                                .padding(12)
                                .background(Color.orange.opacity(0.05))
                                .cornerRadius(14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                                )
                            }
                            
                            if wordNotes.isEmpty && !isAddingNote {
                                VStack(spacing: 8) {
                                    Image(systemName: "note.text")
                                        .font(.system(size: 28))
                                        .foregroundColor(.orange.opacity(0.4))
                                    Text("Henüz not eklenmemiş. Yukarıdaki buton ile hızlıca not ekleyebilirsiniz.")
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                            } else {
                                VStack(spacing: 12) {
                                    ForEach(wordNotes) { note in
                                        VStack(alignment: .leading, spacing: 10) {
                                            // Header
                                            HStack(alignment: .center, spacing: 10) {
                                                ZStack {
                                                    Circle()
                                                        .fill(LinearGradient(colors: [Color.orange, Color.yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                        .frame(width: 28, height: 28)
                                                    Image(systemName: "pin.fill")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundColor(.white)
                                                }
                                                
                                                let cleanTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                                Text(cleanTitle.isEmpty ? (note.wordTerm.isEmpty ? "Sticky Not" : note.wordTerm) : cleanTitle)
                                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                                    .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                                                    .lineLimit(1)
                                                
                                                Spacer()
                                                
                                                Button(action: {
                                                    deleteNote(note)
                                                }) {
                                                    Image(systemName: "trash")
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundColor(.red.opacity(0.8))
                                                        .padding(6)
                                                        .background(Color.red.opacity(0.08))
                                                        .cornerRadius(8)
                                                }
                                            }
                                            
                                            // Note Text Content
                                            StickyHTMLTextView(htmlContent: note.text, fontSize: 13.5)
                                                .fixedSize(horizontal: false, vertical: true)
                                            
                                            // Creation Date Footer
                                            HStack(spacing: 4) {
                                                Image(systemName: "calendar.badge.clock")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                                Text(formatDate(note.createdAt))
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.top, 2)
                                        }
                                        .padding(14)
                                        .background(Color.white)
                                        .cornerRadius(18)
                                        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(hex: "f4f6fa").ignoresSafeArea())
            .navigationTitle(word.term)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                }
            }
            .onAppear {
                localNotes = stickyNotes
            }
        }
    }
    
    private func saveNewNote() {
        let cleanText = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        let titleText = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingNote = true
        
        Task {
            do {
                let db = Firestore.firestore()
                guard let user = Auth.auth().currentUser else {
                    await MainActor.run { isSavingNote = false }
                    return
                }
                let docRef = db.collection("users").document(user.uid).collection("stickyNotes").document()
                let now = Date()
                let newDocData: [String: Any] = [
                    "title": titleText,
                    "text": cleanText,
                    "wordId": word.id,
                    "wordTerm": word.term,
                    "userId": user.uid,
                    "createdAt": FieldValue.serverTimestamp()
                ]
                try await docRef.setData(newDocData)
                
                let newNote = StickyNoteModel(
                    id: docRef.documentID,
                    title: titleText,
                    text: cleanText,
                    wordTerm: word.term,
                    wordId: word.id,
                    createdAt: now
                )
                
                await MainActor.run {
                    localNotes.insert(newNote, at: 0)
                    newNoteTitle = ""
                    newNoteText = ""
                    isAddingNote = false
                    isSavingNote = false
                    onNoteAddedOrDeleted?()
                }
            } catch {
                await MainActor.run {
                    isSavingNote = false
                }
                print("Error adding sticky note: \(error)")
            }
        }
    }
    
    private func deleteNote(_ note: StickyNoteModel) {
        Task {
            do {
                let db = Firestore.firestore()
                guard let user = Auth.auth().currentUser else { return }
                try await db.collection("users").document(user.uid).collection("stickyNotes").document(note.id).delete()
                await MainActor.run {
                    localNotes.removeAll(where: { $0.id == note.id })
                    onNoteAddedOrDeleted?()
                }
            } catch {
                print("Error deleting sticky note: \(error)")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        return df.string(from: date)
    }
    
    private func stripHTML(_ text: String) -> String {
        return text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractTurkishPronunciation(_ pron: String) -> String {
        if let openParen = pron.range(of: "("), let closeParen = pron.range(of: ")") {
            let inside = pron[openParen.upperBound..<closeParen.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty { return inside }
        }
        let cleaned = pron.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned
    }
    
    private func parseEnglishAndTurkishExample(_ text: String) -> (en: String, tr: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openIdx = trimmed.range(of: "(", options: .backwards),
           let closeIdx = trimmed.range(of: ")", options: .backwards),
           openIdx.lowerBound < closeIdx.lowerBound {
            let enPart = String(trimmed[..<openIdx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            let trPart = String(trimmed[openIdx.upperBound..<closeIdx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            if !trPart.isEmpty {
                return (enPart, trPart)
            }
        }
        return (trimmed.replacingOccurrences(of: "\"", with: ""), "")
    }
    
    private func parseFamilyItem(_ item: String) -> (term: String, desc: String) {
        if let openIdx = item.range(of: "(") {
            let term = String(item[..<openIdx.lowerBound]).trimmingCharacters(in: .whitespaces)
            let desc = String(item[openIdx.lowerBound...]).trimmingCharacters(in: .whitespaces)
            return (term, desc)
        }
        return (item, "")
    }
    
    @ViewBuilder
    private func detailBlock<Content: View>(title: String, icon: String, iconColor: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(iconColor)
                
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(1)
            }
            
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.black.opacity(0.03), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.01), radius: 5, x: 0, y: 3)
    }
    
    private func getStatusLabel(_ stage: Int) -> String {
        if stage == 0 { return "YENİ" }
        if stage < 10 { return "ÖĞRENİYOR" }
        return "ÖĞRENDİ"
    }
    
    private func getStatusColor(_ stage: Int) -> Color {
        if stage == 0 { return .blue }
        if stage < 10 { return .orange }
        return .green
    }
}

// FlowLayoutView helper to wrap tags nicely in SwiftUI
struct FlowLayoutView<Content: View>: View {
    let items: [String]
    let content: (String) -> Content
    
    var body: some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(self.items, id: \.self) { item in
                    self.content(item)
                        .padding([.horizontal, .vertical], 4)
                        .alignmentGuide(.leading, computeValue: { d in
                            if (abs(width - d.width) > geo.size.width) {
                                width = 0
                                height -= d.height
                            }
                            let result = width
                            if item == self.items.last! {
                                width = 0 // last item
                            } else {
                                width -= d.width
                            }
                            return result
                        })
                        .alignmentGuide(.top, computeValue: { d in
                            let result = height
                            if item == self.items.last! {
                                height = 0 // last item
                            }
                            return result
                        })
                }
            }
        }
        .frame(height: 100) // Fallback height for tags layout
    }
}

// MARK: - Word detail sub-models (Moved to DictionaryModels.swift)

// MARK: - WordCardView matching Web Project aesthetics

struct WordCardView: View {
    let word: LocalWord
    let isSelectionMode: Bool
    let isSelected: Bool
    let customLists: [CustomListModel]
    var hasStickyNote: Bool = false
    let onSelectToggle: () -> Void
    let onToggleCustomList: (String) -> Void
    
    @State private var isStarredState: Bool = false
    
    private var isInAnyCustomList: Bool {
        customLists.contains(where: { $0.wordIds.contains(word.id) })
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 12) {
            // Header: Checkbox + Star + Term + Pronunciation + Custom Lists Menu Button with Red Dot Badge
            HStack(alignment: .center, spacing: 10) {
                // If in selection mode, render check/uncheck circle
                if isSelectionMode {
                    Button(action: onSelectToggle) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                    }
                }
                
                Button(action: {
                    toggleStar()
                }) {
                    Image(systemName: isStarredState ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundColor(isStarredState ? .orange : .secondary.opacity(0.6))
                }
                
                Text(word.term)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.black.opacity(0.85))
                
                let trPron = extractTurkishPronunciation(word.pronunciation)
                if !trPron.isEmpty {
                    Button(action: {
                        TextToSpeechManager.shared.speak(word.term)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 11))
                            Text(trPron)
                                .font(.system(size: 12, design: .rounded))
                        }
                        .foregroundColor(.blue.opacity(0.8))
                        .padding(.leading, 2)
                    }
                }
                
                Spacer()
                
                // Play/Collection Icon Menu with Red Badge if in custom list
                Menu {
                    Text("Özel Listeye Ekle / Çıkar")
                        .font(.system(size: 11, weight: .bold))
                    
                    Divider()
                    
                    if customLists.isEmpty {
                        Text("Henüz özel liste yok")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customLists) { list in
                            let isInList = list.wordIds.contains(word.id)
                            Button(action: {
                                onToggleCustomList(list.id)
                            }) {
                                HStack {
                                    Text(list.name)
                                    if isInList {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.blue.opacity(0.8))
                        
                        if isInAnyCustomList {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .padding(4)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                let list = word.meaningsList
                ForEach(0..<list.count, id: \.self) { idx in
                    Text("\(idx + 1). \(list[idx])")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.blue.opacity(0.85))
                }
            }
            .padding(.leading, 2)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ÖĞR. AŞAMASI")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(word.learningStage)/10")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                }
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.black.opacity(0.04))
                            .frame(height: 4)
                        
                        Capsule()
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.7), Color.blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * CGFloat(Double(word.learningStage) / 10.0), height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.top, 4)
            
            Divider()
                .padding(.vertical, 2)
            
            HStack {
                Text(getStatusLabel(word.learningStage))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(getStatusColor(word.learningStage))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(getStatusColor(word.learningStage).opacity(0.08))
                    .cornerRadius(6)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Text(word.level)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.04))
                        .cornerRadius(4)
                    
                    Button(action: {
                        // Edit action
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                    
                    Button(action: {
                        // Delete action
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
        
        if hasStickyNote {
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
                .shadow(color: Color.orange.opacity(0.5), radius: 3, x: 0, y: 1)
                .offset(x: -4, y: -4)
        }
        }
        .contentShape(Rectangle())
        .onAppear {
            self.isStarredState = word.isStarred
        }
    }
    
    private func extractTurkishPronunciation(_ pron: String) -> String {
        if let openParen = pron.range(of: "("), let closeParen = pron.range(of: ")") {
            let inside = pron[openParen.upperBound..<closeParen.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty { return inside }
        }
        let cleaned = pron.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned
    }
    
    private func getStatusLabel(_ stage: Int) -> String {
        if stage == 0 { return "YENİ" }
        if stage < 10 { return "ÖĞRENİYOR" }
        return "ÖĞRENDİ"
    }
    
    private func getStatusColor(_ stage: Int) -> Color {
        if stage == 0 { return .blue }
        if stage < 10 { return .orange }
        return .green
    }
    
    private func toggleStar() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("words").document(word.id)
        
        let target = !isStarredState
        self.isStarredState = target
        
        Task {
            do {
                try await ref.updateData(["isStarred": target])
            } catch {
                print("Error updating star status: \(error)")
                self.isStarredState = !target
            }
        }
    }
}

// MARK: - CustomListsContentView Implementation

struct CustomListsContentView: View {
    let customLists: [CustomListModel]
    let onSelectList: (String) -> Void
    
    @State private var searchText: String = ""
    
    private var totalWordsInLists: Int {
        var set = Set<String>()
        for l in customLists {
            l.wordIds.forEach { set.insert($0) }
        }
        return set.count
    }
    
    private var filteredLists: [CustomListModel] {
        if searchText.isEmpty { return customLists }
        let q = searchText.lowercased()
        return customLists.filter { $0.name.lowercased().contains(q) }
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Glass Hero Header Banner
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 50, height: 50)
                            Image(systemName: "folder.fill.badge.gearshape")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Özel Kelime Listelerim")
                                .font(.system(size: 21, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                            Text("Kelime grupların, kategorilerin ve özel çalışma koleksiyonların.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.8))
                            Text("\(customLists.count) Liste")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.8))
                            Text("\(totalWordsInLists) Kelime")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.28, blue: 0.75),
                                Color(red: 0.35, green: 0.48, blue: 0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        
                        Circle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 140, height: 140)
                            .blur(radius: 25)
                            .offset(x: 120, y: -30)
                    }
                )
                .cornerRadius(24)
                .shadow(color: Color(red: 0.12, green: 0.28, blue: 0.75).opacity(0.3), radius: 12, x: 0, y: 5)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                
                // Search Input
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    TextField("Özel listelerde ara...", text: $searchText)
                        .font(.system(size: 14, design: .rounded))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                
                // Section Title
                Text("LİSTELERİM (\(filteredLists.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(1)
                    .padding(.horizontal, 20)
                
                if filteredLists.isEmpty {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.08))
                                .frame(width: 72, height: 72)
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 34))
                                .foregroundColor(.blue)
                        }
                        Text("Henüz özel bir kelime listesi yok.")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                        Text("Kelime detay kartları üzerindeki liste ikonuna tıklayarak ilk listenizi hemen oluşturabilirsiniz.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(filteredLists) { list in
                            Button(action: {
                                onSelectList(list.id)
                            }) {
                                HStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(colors: [Color.blue, Color(red: 0.35, green: 0.65, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 48, height: 48)
                                        
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(list.name)
                                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                                            .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                                        
                                        HStack(spacing: 6) {
                                            Text("\(list.wordIds.count) KELİME")
                                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                                .foregroundColor(.blue)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.08))
                                                .cornerRadius(6)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    HStack(spacing: 4) {
                                        Text("Aç")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundColor(.blue)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.blue)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(10)
                                }
                                .padding(16)
                                .background(Color.white)
                                .cornerRadius(22)
                                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22)
                                        .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 32)
        }
    }
}

// MARK: - PratikContentView Implementation (Web-matched Quiz & Practice Engine)

// MARK: - PratikContentView Implementation (Moved models to DictionaryModels.swift)

struct PratikContentView: View {
    @Binding var allWords: [LocalWord]
    let customLists: [CustomListModel]
    var stickyNotes: [StickyNoteModel] = []
    @Binding var viewMode: String
    let onSelectWord: (LocalWord) -> Void
    
    private func extractTurkishPronunciation(_ pron: String) -> String {
        if let openParen = pron.range(of: "("), let closeParen = pron.range(of: ")") {
            let inside = pron[openParen.upperBound..<closeParen.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty { return inside }
        }
        let cleaned = pron.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned
    }
    
    private func parseEnglishAndTurkishExample(_ text: String) -> (en: String, tr: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openIdx = trimmed.range(of: "(", options: .backwards),
           let closeIdx = trimmed.range(of: ")", options: .backwards),
           openIdx.lowerBound < closeIdx.lowerBound {
            let enPart = String(trimmed[..<openIdx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            let trPart = String(trimmed[openIdx.upperBound..<closeIdx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            if !trPart.isEmpty {
                return (enPart, trPart)
            }
        }
        return (trimmed.replacingOccurrences(of: "\"", with: ""), "")
    }
    
    private func getOptionPronunciation(optText: String, targetWord: LocalWord) -> String? {
        let textLower = optText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLower = targetWord.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let match = allWords.first(where: { $0.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == textLower }) ?? (textLower == targetLower ? targetWord : nil)
        
        if let rawPron = match?.pronunciation, !rawPron.isEmpty {
            let tr = extractTurkishPronunciation(rawPron)
            return tr.isEmpty ? nil : tr
        }
        return nil
    }
    
    // Test Options Configurations
    @State private var questionCount: Double = 15
    @State private var questionFormat: String = "mixed" // "definition" | "term" | "mixed"
    @State private var selectedLanguage: String = "all"
    @State private var statusYeni: Bool = true
    @State private var statusOgreniyor: Bool = true
    @State private var statusOgrendi: Bool = true
    
    @State private var typeMCQ: Bool = true
    @State private var typeTF: Bool = true
    @State private var typeFlashcard: Bool = true
    @State private var typeWritten: Bool = false
    
    @State private var selectedListIds: Set<String> = []
    
    @State private var onlyStarred: Bool = false
    @State private var excludeStarred: Bool = false
    @State private var excludeSolvedToday: Bool = false
    @State private var shufflePool: Bool = true
    @State private var smartDistractors: Bool = true
    @State private var timeSurvival: Bool = false
    
    // Quick Tests and Saved Tests from Firestore
    @State private var quickTests: [QuickTestTemplate] = []
    @State private var savedPracticeTests: [[String: Any]] = []
    @State private var isLoading: Bool = false
    @State private var showSaveQuickTestAlert: Bool = false
    @State private var showDeleteAllTestsAlert: Bool = false
    @State private var showDeleteSingleTestAlert: Bool = false
    @State private var deletingSingleTestId: String? = nil
    @State private var showTestQuestionsSheet: Bool = false
    @State private var showUnansweredWarningAlert: Bool = false
    @State private var showExitTestAlert: Bool = false
    @State private var selectedQuickTestId: String? = nil
    @State private var newQuickTestName: String = ""
    
    // Yardımcı Araçlar & Ekstra Modlar
    @State private var helpShowLetterCounter: Bool = true
    @State private var helpColorOnLengthMatch: Bool = true
    @State private var helpColorOnExactMatch: Bool = true
    @AppStorage("practice_max_allowed_typo_letters") private var maxAllowedTypoLetters: Int = 2
    
    @State private var modeFillInTheBlanks: Bool = false
    @State private var modeMissingLetters: Bool = false
    @State private var modeSingleMeaning: Bool = false
    @State private var modeComboStreak: Bool = false
    @State private var modeProgressiveHint: Bool = false
    
    @FocusState private var focusedQuestionIdx: Int?
    @State private var solvedTodayCount: Int = 0
    @State private var todaySolvedWordIds: Set<String> = []
    @State private var revealedHintIndicesMap: [Int: [Int]] = [:]
    
    @State private var editingQuickTest: QuickTestTemplate? = nil
    @State private var editingQuickTestName: String = ""
    @State private var showRenameQuickTestAlert: Bool = false
    
    @State private var deletingQuickTest: QuickTestTemplate? = nil
    @State private var showDeleteQuickTestAlert: Bool = false
    @State private var quickTestsListener: ListenerRegistration? = nil
    
    // Active Test Engine States
    @State private var activeQuestions: [PracticeQuestionItem] = []
    @State private var currentQuestionIndex: Int = 0
    @State private var score: Int = 0
    @State private var comboStreak: Int = 0
    @State private var selectedAnswerOption: String? = nil
    @State private var isAnswerSubmitted: Bool = false
    @State private var isAnswerCorrect: Bool = false
    @State private var writtenInputText: String = ""
    @State private var isCardFlipped: Bool = false
    @State private var testResultsList: [QuestionAnswerResult] = []
    @State private var activeTestId: String? = nil
    @State private var userAnswersMap: [Int: String] = [:]
    @State private var openCategoryKey: String? = nil
    
    @State private var cachedAvailableWordsCount: Int = 0
    @State private var cachedSolvedWordIds: Set<String> = []
    
    private var solvedWordIdsFromPracticeTests: Set<String> {
        cachedSolvedWordIds
    }
    
    private var availableWordsCount: Int {
        cachedAvailableWordsCount
    }
    
    private func updateSolvedWordIds() {
        var set = Set<String>()
        for test in savedPracticeTests {
            if let array = test["solvedWordIds"] as? [String] {
                for id in array { set.insert(id) }
            }
            if let questions = test["questions"] as? [[String: Any]] {
                let answersDict = test["answers"] as? [String: [String: Any]]
                let answersArray = test["answers"] as? [[String: Any]]
                
                for (idx, q) in questions.enumerated() {
                    let wId = q["wordId"] as? String ?? ""
                    guard !wId.isEmpty else { continue }
                    
                    var isCorrect = false
                    if let dict = answersDict, let ans = dict["\(idx)"] {
                        if (ans["isCorrect"] as? Bool == true) || ((ans["selected"] as? [String: Any])?["isCorrect"] as? Bool == true) {
                            isCorrect = true
                        }
                    } else if let arr = answersArray, idx < arr.count {
                        let ans = arr[idx]
                        if (ans["isCorrect"] as? Bool == true) || ((ans["selected"] as? [String: Any])?["isCorrect"] as? Bool == true) {
                            isCorrect = true
                        }
                    }
                    
                    if isCorrect {
                        set.insert(wId)
                    }
                }
            }
        }
        self.cachedSolvedWordIds = set
    }
    
    private func recalculateAvailableWords() {
        updateSolvedWordIds()
        var pool = allWords
        if onlyStarred { pool = pool.filter { $0.isStarred } }
        if excludeStarred { pool = pool.filter { !$0.isStarred } }
        if excludeSolvedToday { pool = pool.filter { !cachedSolvedWordIds.contains($0.id) } }
        if selectedLanguage != "all" { pool = pool.filter { $0.language == selectedLanguage } }
        if !selectedListIds.isEmpty {
            let allowedIds = Set(customLists.filter { selectedListIds.contains($0.id) }.flatMap { $0.wordIds })
            pool = pool.filter { allowedIds.contains($0.id) }
        } else {
            let statusFilters: [String] = [
                statusYeni ? "Yeni" : "",
                statusOgreniyor ? "Öğreniyor" : "",
                statusOgrendi ? "Öğrendi" : ""
            ].filter { !$0.isEmpty }
            if !statusFilters.isEmpty {
                pool = pool.filter { word in
                    let wordStatus = word.learningStage == 0 ? "Yeni" : (word.learningStage >= 5 ? "Öğrendi" : "Öğreniyor")
                    return statusFilters.contains(wordStatus)
                }
            }
        }
        self.cachedAvailableWordsCount = pool.count
    }
    
    var uniqueLanguages: [String] {
        let langs = Set(allWords.map { $0.language.isEmpty ? "İngilizce" : $0.language })
        var arr = Array(langs).sorted()
        if !arr.contains("İngilizce") { arr.insert("İngilizce", at: 0) }
        return arr
    }
    
    var progressPercent: Int {
        guard !activeQuestions.isEmpty else { return 0 }
        return Int(Double(currentQuestionIndex + 1) / Double(activeQuestions.count) * 100.0)
    }
    
    var progressFraction: CGFloat {
        guard !activeQuestions.isEmpty else { return 0 }
        return CGFloat(currentQuestionIndex + 1) / CGFloat(activeQuestions.count)
    }
    
    @ViewBuilder
    var body: some View {
        VStack(spacing: 0) {
            if viewMode == "active" {
                activeQuizView
            } else if viewMode == "results" {
                testResultsView
            } else {
                optionsSetupView
            }
        }
        .alert("Hızlı Test İsmini Düzenle", isPresented: $showRenameQuickTestAlert) {
            TextField("Hızlı test ismi...", text: $editingQuickTestName)
            Button("İptal", role: .cancel) { }
            Button("Kaydet") {
                if let qt = editingQuickTest {
                    renameQuickTest(id: qt.id, newName: editingQuickTestName)
                }
            }
        } message: {
            Text("Hızlı test için yeni bir isim girin.")
        }
        .onAppear {
            loadPratikSettings()
            loadQuickTests()
            loadSavedPracticeTests()
            fetchTodayStats()
            recalculateAvailableWords()
            
            if viewMode != "results" && loadActiveTestState() {
                viewMode = "active"
            }
        }
        .onChange(of: allWords.count) { _ in recalculateAvailableWords() }
        .onChange(of: savedPracticeTests.count) { _ in recalculateAvailableWords() }
        .onChange(of: onlyStarred) { _ in recalculateAvailableWords() }
        .onChange(of: excludeStarred) { _ in recalculateAvailableWords() }
        .onChange(of: excludeSolvedToday) { _ in recalculateAvailableWords() }
        .onChange(of: selectedLanguage) { _ in recalculateAvailableWords() }
        .onChange(of: selectedListIds) { _ in recalculateAvailableWords() }
        .onChange(of: statusYeni) { _ in recalculateAvailableWords() }
        .onChange(of: statusOgreniyor) { _ in recalculateAvailableWords() }
        .onChange(of: statusOgrendi) { _ in recalculateAvailableWords() }
        .onChange(of: userAnswersMap) { _ in saveActiveTestState() }
        .onChange(of: revealedHintIndicesMap) { _ in saveActiveTestState() }
        .onChange(of: hiddenOptionsMap) { _ in saveActiveTestState() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveActiveTestState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            saveActiveTestState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RunQuickTestInPratik"))) { notification in
            if let testId = notification.object as? String {
                executeQuickTestById(testId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StartUnsolvedTest"))) { notification in
            selectedListIds = ["smart_unsolved"]
            selectedQuickTestId = nil
            if let ids = notification.object as? [String], !ids.isEmpty {
                questionCount = Double(min(15, ids.count))
            } else {
                questionCount = 15
            }
            questionFormat = "mixed"
            selectedLanguage = "all"
            typeMCQ = true
            typeTF = true
            typeFlashcard = true
            typeWritten = false
            statusYeni = true
            statusOgreniyor = true
            statusOgrendi = true
            onlyStarred = false
            excludeStarred = false
            excludeSolvedToday = false
            shufflePool = true
            viewMode = "setup"
        }
    }
    
    private func executeQuickTestById(_ testId: String) {
        let found = quickTests.first(where: { $0.id == testId })
        if let template = found {
            viewMode = "setup"
            startTestFromQuickTemplate(template)
        }
    }
    
    private func fetchTodayStats() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())
        Task {
            if let snap = try? await db.collection("users").document(user.uid).collection("daily_stats").document(todayStr).getDocument(),
               let data = snap.data() {
                let wordsDict = data["words"] as? [String: Any] ?? [:]
                var solvedSet = Set<String>()
                for (wId, wData) in wordsDict {
                    if let dict = wData as? [String: Any] {
                        let c = dict["correct"] as? Int ?? 0
                        if c > 0 {
                            solvedSet.insert(wId)
                        }
                    }
                }
                await MainActor.run {
                    self.todaySolvedWordIds = solvedSet
                    self.solvedTodayCount = solvedSet.count
                }
            }
        }
    }
    
    // MARK: - Active In-Progress Test Persistence
    private func saveActiveTestState() {
        guard !activeQuestions.isEmpty && viewMode == "active" else { return }
        let state = ActiveTestState(
            activeQuestions: activeQuestions,
            userAnswersMap: userAnswersMap,
            hiddenOptionsMap: hiddenOptionsMap,
            revealedHintIndicesMap: revealedHintIndicesMap,
            activeTestId: activeTestId,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "pratik_active_test_state")
        }
    }
    
    private func clearActiveTestState() {
        UserDefaults.standard.removeObject(forKey: "pratik_active_test_state")
    }
    
    @discardableResult
    private func loadActiveTestState() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "pratik_active_test_state"),
              let state = try? JSONDecoder().decode(ActiveTestState.self, from: data),
              !state.activeQuestions.isEmpty else {
            return false
        }
        self.activeQuestions = state.activeQuestions
        self.userAnswersMap = state.userAnswersMap
        self.hiddenOptionsMap = state.hiddenOptionsMap
        self.revealedHintIndicesMap = state.revealedHintIndicesMap
        self.activeTestId = state.activeTestId
        return true
    }
    
    // MARK: - Save and Load Pratik Settings
    private func savePratikSettings() {
        let defaults = UserDefaults.standard
        defaults.set(questionCount, forKey: "pratik_questionCount")
        defaults.set(questionFormat, forKey: "pratik_questionFormat")
        defaults.set(selectedLanguage, forKey: "pratik_selectedLanguage")
        defaults.set(statusYeni, forKey: "pratik_statusYeni")
        defaults.set(statusOgreniyor, forKey: "pratik_statusOgreniyor")
        defaults.set(statusOgrendi, forKey: "pratik_statusOgrendi")
        defaults.set(typeMCQ, forKey: "pratik_typeMCQ")
        defaults.set(typeTF, forKey: "pratik_typeTF")
        defaults.set(typeFlashcard, forKey: "pratik_typeFlashcard")
        defaults.set(typeWritten, forKey: "pratik_typeWritten")
        defaults.set(onlyStarred, forKey: "pratik_onlyStarred")
        defaults.set(excludeStarred, forKey: "pratik_excludeStarred")
        defaults.set(shufflePool, forKey: "pratik_shufflePool")
        defaults.set(smartDistractors, forKey: "pratik_smartDistractors")
        defaults.set(excludeSolvedToday, forKey: "pratik_excludeSolvedToday")
        
        defaults.set(helpShowLetterCounter, forKey: "pratik_helpShowLetterCounter")
        defaults.set(helpColorOnLengthMatch, forKey: "pratik_helpColorOnLengthMatch")
        defaults.set(helpColorOnExactMatch, forKey: "pratik_helpColorOnExactMatch")
        defaults.set(maxAllowedTypoLetters, forKey: "pratik_maxAllowedTypoLetters")
        
        defaults.set(modeFillInTheBlanks, forKey: "pratik_modeFillInTheBlanks")
        defaults.set(modeMissingLetters, forKey: "pratik_modeMissingLetters")
        defaults.set(modeSingleMeaning, forKey: "pratik_modeSingleMeaning")
        defaults.set(modeComboStreak, forKey: "pratik_modeComboStreak")
        defaults.set(modeProgressiveHint, forKey: "pratik_modeProgressiveHint")
        
        if let qid = selectedQuickTestId {
            defaults.set(qid, forKey: "pratik_selectedQuickTestId")
        } else {
            defaults.removeObject(forKey: "pratik_selectedQuickTestId")
        }
    }
    
    private func loadPratikSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pratik_questionCount") != nil {
            questionCount = defaults.double(forKey: "pratik_questionCount")
        }
        if let fmt = defaults.string(forKey: "pratik_questionFormat") {
            questionFormat = fmt
        }
        if let lang = defaults.string(forKey: "pratik_selectedLanguage") {
            selectedLanguage = lang
        }
        if defaults.object(forKey: "pratik_statusYeni") != nil {
            statusYeni = defaults.bool(forKey: "pratik_statusYeni")
        }
        if defaults.object(forKey: "pratik_statusOgreniyor") != nil {
            statusOgreniyor = defaults.bool(forKey: "pratik_statusOgreniyor")
        }
        if defaults.object(forKey: "pratik_statusOgrendi") != nil {
            statusOgrendi = defaults.bool(forKey: "pratik_statusOgrendi")
        }
        if defaults.object(forKey: "pratik_typeMCQ") != nil {
            typeMCQ = defaults.bool(forKey: "pratik_typeMCQ")
        }
        if defaults.object(forKey: "pratik_typeTF") != nil {
            typeTF = defaults.bool(forKey: "pratik_typeTF")
        }
        if defaults.object(forKey: "pratik_typeFlashcard") != nil {
            typeFlashcard = defaults.bool(forKey: "pratik_typeFlashcard")
        }
        if defaults.object(forKey: "pratik_typeWritten") != nil {
            typeWritten = defaults.bool(forKey: "pratik_typeWritten")
        }
        if defaults.object(forKey: "pratik_onlyStarred") != nil {
            onlyStarred = defaults.bool(forKey: "pratik_onlyStarred")
        }
        if defaults.object(forKey: "pratik_excludeStarred") != nil {
            excludeStarred = defaults.bool(forKey: "pratik_excludeStarred")
        }
        if defaults.object(forKey: "pratik_shufflePool") != nil {
            shufflePool = defaults.bool(forKey: "pratik_shufflePool")
        }
        if defaults.object(forKey: "pratik_smartDistractors") != nil {
            smartDistractors = defaults.bool(forKey: "pratik_smartDistractors")
        }
        if defaults.object(forKey: "pratik_excludeSolvedToday") != nil {
            excludeSolvedToday = defaults.bool(forKey: "pratik_excludeSolvedToday")
        }
        
        if defaults.object(forKey: "pratik_helpShowLetterCounter") != nil {
            helpShowLetterCounter = defaults.bool(forKey: "pratik_helpShowLetterCounter")
        }
        if defaults.object(forKey: "pratik_helpColorOnLengthMatch") != nil {
            helpColorOnLengthMatch = defaults.bool(forKey: "pratik_helpColorOnLengthMatch")
        }
        if defaults.object(forKey: "pratik_helpColorOnExactMatch") != nil {
            helpColorOnExactMatch = defaults.bool(forKey: "pratik_helpColorOnExactMatch")
        }
        if defaults.object(forKey: "pratik_maxAllowedTypoLetters") != nil {
            maxAllowedTypoLetters = defaults.integer(forKey: "pratik_maxAllowedTypoLetters")
        }
        
        if defaults.object(forKey: "pratik_modeFillInTheBlanks") != nil {
            modeFillInTheBlanks = defaults.bool(forKey: "pratik_modeFillInTheBlanks")
        }
        if defaults.object(forKey: "pratik_modeMissingLetters") != nil {
            modeMissingLetters = defaults.bool(forKey: "pratik_modeMissingLetters")
        }
        if defaults.object(forKey: "pratik_modeSingleMeaning") != nil {
            modeSingleMeaning = defaults.bool(forKey: "pratik_modeSingleMeaning")
        }
        if defaults.object(forKey: "pratik_modeComboStreak") != nil {
            modeComboStreak = defaults.bool(forKey: "pratik_modeComboStreak")
        }
        if defaults.object(forKey: "pratik_modeProgressiveHint") != nil {
            modeProgressiveHint = defaults.bool(forKey: "pratik_modeProgressiveHint")
        }
        
        selectedQuickTestId = defaults.string(forKey: "pratik_selectedQuickTestId")
    }
    
    // MARK: - Options Setup View
    @ViewBuilder
    private var optionsSetupView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // In-Progress Test Resume Banner
                if !activeQuestions.isEmpty {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Devam Eden Testiniz Var")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("\(userAnswersMap.count)/\(activeQuestions.count) soru yanıtlandı • Kaldığınız yerden devam edin")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            withAnimation {
                                viewMode = "active"
                            }
                        }) {
                            Text("Devam Et")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                        
                        Button(action: {
                            clearActiveTestState()
                            withAnimation {
                                activeQuestions.removeAll()
                                userAnswersMap.removeAll()
                                hiddenOptionsMap.removeAll()
                                revealedHintIndicesMap.removeAll()
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.gray.opacity(0.5))
                        }
                    }
                    .padding(14)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                
                // 1. Purple/Blue Premium Gradient Banner
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 46, height: 46)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                )
                            
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pratik Yap & Test Çöz")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("Seçenekleri belirleyerek kelime dağarcığınızı test edin, hızlı test şablonlarıyla pratik yapın.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            showSaveQuickTestAlert = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Hızlı Teste Kaydet")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 100)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                        }
                        
                        Button(action: {
                            startNewTest()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Teste Başla")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(Color(hex: "0891b2"))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Color.white)
                            .cornerRadius(100)
                            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "2563eb"), Color(hex: "9333ea")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(20)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // 2. Hızlı Test Şablonları Section
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Color.amber)
                        
                        Text("Hızlı Test Oluştur")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 20)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(quickTests) { test in
                                let isSel = selectedQuickTestId == test.id
                                let isMod = isSel && isQuickTestModified(test)
                                QuickTestCardView(
                                    test: test,
                                    isSelected: isSel,
                                    isModified: isMod,
                                    onSave: {
                                        updateQuickTest(id: test.id)
                                    },
                                    onEdit: {
                                        editingQuickTest = test
                                        editingQuickTestName = test.name
                                        showRenameQuickTestAlert = true
                                    },
                                    onDelete: {
                                        deletingQuickTest = test
                                        showDeleteQuickTestAlert = true
                                    }
                                )
                                .onTapGesture {
                                    if isSel {
                                        selectedQuickTestId = nil
                                    } else {
                                        startTestFromQuickTemplate(test)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                
                // 3. Test Yapılandırması Form Card
                testOptionsFormCard
                
                // 4. Kayıtlı / Devam Eden Testler Section (Horizontal & Sorted)
                if !savedPracticeTests.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Kayıtlı & Devam Eden Testler")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Button(action: {
                                showDeleteAllTestsAlert = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                    Text("Tümünü Sil")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                }
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(savedPracticeTests.enumerated()), id: \.offset) { idx, test in
                                    savedTestCard(test: test, index: idx)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        }
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .alert("Hızlı Teste Kaydet", isPresented: $showSaveQuickTestAlert) {
            TextField("Şablon Adı", text: $newQuickTestName)
            Button("Kaydet") {
                saveCurrentQuickTest()
            }
            Button("İptal", role: .cancel) { }
        } message: {
            Text("Bu test ayarlarını hızlı erişim şablonu olarak kaydedin.")
        }
        .alert("Tüm Testleri Sil", isPresented: $showDeleteAllTestsAlert) {
            Button("Evet, Tümünü Sil", role: .destructive) {
                deleteAllPracticeTests()
            }
            Button("Vazgeç", role: .cancel) { }
        } message: {
            Text("Kayıtlı ve devam eden tüm pratik testleriniz silinecek. Emin misiniz?")
        }
        .alert("Testi Sil", isPresented: $showDeleteSingleTestAlert) {
            Button("Evet, Sil", role: .destructive) {
                if let id = deletingSingleTestId {
                    deleteSinglePracticeTest(id: id)
                }
            }
            Button("Vazgeç", role: .cancel) { }
        } message: {
            Text("Bu kayıtlı testi silmek istediğinize emin misiniz?")
        }
        .alert("Şablonu Sil", isPresented: $showDeleteQuickTestAlert) {
            Button("Evet, Sil", role: .destructive) {
                if let qt = deletingQuickTest {
                    deleteQuickTest(id: qt.id)
                }
            }
            Button("Vazgeç", role: .cancel) { }
        } message: {
            Text("\"\(deletingQuickTest?.name ?? "Şablon")\" şablonu silinecek. Emin misiniz?")
        }
    }
    
    // MARK: - Test Options Form Card
    @ViewBuilder
    private var testOptionsFormCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Test Yapılandırması")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            // Soru Sayısı Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Soru Sayısı")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        Text("Seçili ayarlarla \(availableWordsCount) kelime bulunuyor.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        if availableWordsCount > 0 && availableWordsCount < Int(questionCount) {
                            Text("Maksimum \(availableWordsCount) soru çıkacak.")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Spacer()
                    
                    Text("\(min(Int(questionCount), availableWordsCount)) / \(availableWordsCount) Soru")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                }
                
                let maxSliderBound = max(2.0, Double(availableWordsCount))
                Slider(value: $questionCount, in: 1...maxSliderBound, step: 1)
                    .tint(.blue)
                    .disabled(availableWordsCount == 0)
            }
            
            Divider()
            
            // Soru Formatı
            VStack(alignment: .leading, spacing: 8) {
                Text("Soru Yönü / Formatı")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    formatChip(title: "Karışık", tag: "mixed")
                    formatChip(title: "Türkçe Sor", tag: "definition")
                    formatChip(title: "Kelime Sor", tag: "term")
                }
            }
            
            Divider()
            
            // Dil Seçimi
            VStack(alignment: .leading, spacing: 8) {
                Text("Dil")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        langChip(title: "Tüm Diller", tag: "all")
                        ForEach(uniqueLanguages, id: \.self) { lang in
                            langChip(title: lang, tag: lang)
                        }
                    }
                }
            }
            
            Divider()
            
            // Öğrenim Durumu
            VStack(alignment: .leading, spacing: 8) {
                Text("Öğrenim Durumları")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    toggleChip(title: "Yeni", isSelected: $statusYeni, color: .blue)
                    toggleChip(title: "Öğreniyor", isSelected: $statusOgreniyor, color: .orange)
                    toggleChip(title: "Öğrendi", isSelected: $statusOgrendi, color: .green)
                }
            }
            
            Divider()
            
            // Soru Tipleri
            VStack(alignment: .leading, spacing: 8) {
                Text("Soru Tipleri")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    toggleChip(title: "Çoktan Seçmeli", isSelected: $typeMCQ, color: .blue)
                    toggleChip(title: "Doğru / Yanlış", isSelected: $typeTF, color: .blue)
                    toggleChip(title: "Bilgi Kartı", isSelected: $typeFlashcard, color: .blue)
                    toggleChip(title: "Yazılı Cevap", isSelected: $typeWritten, color: .blue)
                }
            }
            
            // Özel Listeler (if available)
            if !customLists.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Özel Listelerim")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(customLists) { list in
                                let isSel = selectedListIds.contains(list.id)
                                Button(action: {
                                    if isSel { selectedListIds.remove(list.id) }
                                    else { selectedListIds.insert(list.id) }
                                }) {
                                    Text(list.name)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundColor(isSel ? .white : .primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(isSel ? Color.blue : Color.black.opacity(0.04))
                                        .cornerRadius(12)
                                }
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Gelişmiş Seçenekler
            VStack(alignment: .leading, spacing: 10) {
                Text("Gelişmiş Seçenekler")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                
                VStack(spacing: 8) {
                    toggleRow(title: "Sadece Yıldızlı Kelimeler", isSelected: Binding(
                        get: { onlyStarred },
                        set: { val in
                            onlyStarred = val
                            if val { excludeStarred = false }
                        }
                    ), icon: "star.fill", color: .yellow)
                    
                    toggleRow(title: "Sadece Yıldızsız Kelimeler", isSelected: Binding(
                        get: { excludeStarred },
                        set: { val in
                            excludeStarred = val
                            if val { onlyStarred = false }
                        }
                    ), icon: "star.slash", color: .gray)
                    
                    toggleRow(title: "Karışık Sıralama (Shuffle)", isSelected: $shufflePool, icon: "shuffle", color: .indigo)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        toggleRow(title: "Doğru Çözülenleri Ekleme", isSelected: $excludeSolvedToday, icon: "calendar.badge.clock", color: .orange)
                        Text("Ekarte edilecek kelime sayısı: \(solvedWordIdsFromPracticeTests.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.blue)
                            .padding(.leading, 32)
                    }
                }
            }
            
            Divider()
            
            // Yardımcı Araçlar
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 14))
                    Text("Yardımcı Araçlar")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                }
                
                VStack(spacing: 10) {
                    toggleRow(title: "Harf Sayacı", isSelected: $helpShowLetterCounter, icon: "textformat.123", color: .blue)
                    toggleRow(title: "Uzunluk Eşleşince Yeşil Olsun", isSelected: $helpColorOnLengthMatch, icon: "checkmark.seal", color: .green)
                    toggleRow(title: "Tam Eşleşince Mavi Olsun", isSelected: $helpColorOnExactMatch, icon: "checkmark.circle.fill", color: .blue)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "character.cursor.ibeam")
                                .foregroundColor(.orange)
                                .font(.system(size: 13))
                            
                            Text("Yazım Hatası Toleransı")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Text("\(maxAllowedTypoLetters) Harf")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(6)
                        }
                        
                        Slider(
                            value: Binding(
                                get: { Double(maxAllowedTypoLetters) },
                                set: { maxAllowedTypoLetters = Int($0) }
                            ),
                            in: 0...5,
                            step: 1
                        )
                        .accentColor(.orange)
                        
                        HStack {
                            Text("0 (Tam Eşleşme)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Maks. 5 Harf")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.03))
                    .cornerRadius(12)
                }
            }
            
            Divider()
            
            // Ekstra Modlar
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text("Ekstra Modlar")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
                
                VStack(spacing: 8) {
                    toggleRow(title: "Örnek Cümle Tamamlama (Mod)", isSelected: $modeFillInTheBlanks, icon: "quote.bubble.fill", color: .indigo)
                    toggleRow(title: "Çeldirici Şıklar (Akıllı Şıklar)", isSelected: $smartDistractors, icon: "exclamationmark.triangle.fill", color: .orange)
                    toggleRow(title: "Eksik Harfler (Cellat Modu)", isSelected: $modeMissingLetters, icon: "text.cursor", color: .purple)
                    toggleRow(title: "Gizli Anlamlar (Tek Anlam)", isSelected: $modeSingleMeaning, icon: "eye.slash.fill", color: .gray)
                    toggleRow(title: "Combo / Seri Çarpanı", isSelected: $modeComboStreak, icon: "bolt.fill", color: .yellow)
                    toggleRow(title: "Kademeli İpucu", isSelected: $modeProgressiveHint, icon: "sparkles", color: .cyan)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.02), radius: 5, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Active Quiz Solver View (Web-Matched Vertical List)
    @ViewBuilder
    private var activeQuizView: some View {
        VStack(spacing: 0) {
            if activeQuestions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)
                    Text("Seçilen filtrelere uygun soru üretilemedi.")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Button("Ayarlara Dön") { viewMode = "options" }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
            } else {
                // Single-Line Compact Header with Back/Exit Warning
                HStack(spacing: 8) {
                    Button(action: {
                        showExitTestAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                            Text("Pratik Yap")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    
                    Text("Test Arenası")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                    
                    Text("\(userAnswersMap.count)/\(activeQuestions.count)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    Button(action: {
                        handleFinishTestAttempt()
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white)
                .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 1)
                .alert("Testten Çıksın mı?", isPresented: $showExitTestAlert) {
                    Button("Devam Et", role: .cancel) { }
                    Button("Testi Sonlandır", role: .destructive) {
                        clearActiveTestState()
                        withAnimation {
                            activeQuestions.removeAll()
                            userAnswersMap.removeAll()
                            hiddenOptionsMap.removeAll()
                            revealedHintIndicesMap.removeAll()
                            viewMode = "options"
                        }
                    }
                } message: {
                    Text("Devam eden testiniz sonlandırılacaktır.")
                }
                
                // Single Vertical ScrollView with ScrollViewReader for Auto-Scroll to Top
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 20) {
                            ForEach(Array(activeQuestions.enumerated()), id: \.offset) { idx, q in
                                let hasQuestionStickyNote = stickyNotes.contains(where: { $0.wordId == q.targetWord.id || (!$0.wordTerm.isEmpty && $0.wordTerm.lowercased() == q.targetWord.term.lowercased()) })
                                VStack(alignment: .leading, spacing: 14) {
                                    // Question Header: Index Badge + Format + Native iOS Action Pills
                                    HStack {
                                        HStack(spacing: 8) {
                                            Text("Soru \(idx + 1)")
                                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                                .foregroundColor((userAnswersMap[idx] != nil && !(userAnswersMap[idx]?.isEmpty ?? true)) ? .blue : .primary)
                                            
                                            Text("•")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.secondary.opacity(0.4))
                                            
                                            Text(q.prompt == q.targetWord.shortMeanings ? "Anlamı Bul" : "Kelimeyi Bul")
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundColor(.blue)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.08))
                                                .cornerRadius(10)
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 8) {
                                            // 1. Star Toggle Button (Live state from allWords)
                                            let liveWord = allWords.first(where: { $0.id == q.targetWord.id }) ?? allWords.first(where: { $0.term.lowercased() == q.targetWord.term.lowercased() }) ?? q.targetWord
                                            let isStarred = liveWord.isStarred
                                            
                                            Button(action: {
                                                toggleWordStar(liveWord)
                                            }) {
                                                Image(systemName: isStarred ? "star.fill" : "star")
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundColor(isStarred ? .orange : .gray)
                                                    .frame(width: 36, height: 36)
                                                    .background(isStarred ? Color.orange.opacity(0.12) : Color.black.opacity(0.05))
                                                    .clipShape(Circle())
                                            }
                                            .buttonStyle(.plain)
                                            
                                            // 2. Hint Button (💡 Icon Only)
                                            let maxHints: Int = q.questionType == "written" ? q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).count : (q.questionType == "tf" ? 0 : (q.questionType == "flashcard" ? 1 : min(2, max(0, q.options.count - 1))))
                                            let usedHints: Int = q.questionType == "written" ? (revealedHintIndicesMap[idx] ?? []).count : (q.questionType == "flashcard" ? ((revealedHintIndicesMap[idx] ?? []).contains(999) ? 1 : 0) : (hiddenOptionsMap[idx] ?? []).count)
                                            
                                            if maxHints > 0 {
                                                Button(action: {
                                                    if q.questionType == "written" {
                                                        let targetAns = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                                                        let currentRevealed = revealedHintIndicesMap[idx] ?? []
                                                        
                                                        let unrevealedIndices = targetAns.enumerated().compactMap { (cIdx, char) -> Int? in
                                                            return (char != " " && !currentRevealed.contains(cIdx)) ? cIdx : nil
                                                        }
                                                        
                                                        if let randomIdx = unrevealedIndices.randomElement() {
                                                            var updated = currentRevealed
                                                            updated.append(randomIdx)
                                                            revealedHintIndicesMap[idx] = updated
                                                        }
                                                        focusedQuestionIdx = idx
                                                    } else if q.questionType == "mcq" {
                                                        let wrongOptions = q.options.filter { $0 != q.correctAnswer }
                                                        let currentHidden = hiddenOptionsMap[idx] ?? []
                                                        if let nextToHide = wrongOptions.first(where: { !currentHidden.contains($0) }) {
                                                            var updated = currentHidden
                                                            updated.append(nextToHide)
                                                            hiddenOptionsMap[idx] = updated
                                                        }
                                                    } else if q.questionType == "flashcard" {
                                                        var currentRevealed = revealedHintIndicesMap[idx] ?? []
                                                        if !currentRevealed.contains(999) {
                                                            currentRevealed.append(999)
                                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                                                revealedHintIndicesMap[idx] = currentRevealed
                                                            }
                                                        }
                                                    }
                                                }) {
                                                    Image(systemName: "lightbulb.fill")
                                                        .font(.system(size: 16, weight: .semibold))
                                                        .foregroundColor(usedHints >= maxHints ? .gray.opacity(0.4) : .orange)
                                                        .frame(width: 36, height: 36)
                                                        .background(usedHints >= maxHints ? Color.black.opacity(0.04) : Color.orange.opacity(0.12))
                                                        .clipShape(Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(usedHints >= maxHints)
                                            }
                                            
                                            // 3. Kelime Detay Sheet Button (info.circle.fill)
                                            Button(action: {
                                                let matched = allWords.first(where: { $0.id == q.targetWord.id }) ?? allWords.first(where: { $0.term.lowercased() == q.targetWord.term.lowercased() }) ?? q.targetWord
                                                onSelectWord(matched)
                                            }) {
                                                Image(systemName: "info.circle.fill")
                                                    .font(.system(size: 17, weight: .semibold))
                                                    .foregroundColor(.blue)
                                                    .frame(width: 36, height: 36)
                                                    .background(Color.blue.opacity(0.1))
                                                    .clipShape(Circle())
                                            }
                                            .buttonStyle(.plain)
                                            
                                            // 4. Speaker Button
                                            Button(action: {
                                                TextToSpeechManager.shared.speak(q.targetWord.term, language: q.targetWord.language)
                                            }) {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(.blue)
                                                    .frame(width: 36, height: 36)
                                                    .background(Color.blue.opacity(0.08))
                                                    .clipShape(Circle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    
                                    // Prompt Text
                                    Text(q.prompt)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                        .padding(.vertical, 2)
                                    
                                    let subtextTr: String? = {
                                        if let tr = q.turkishTranslation, !tr.isEmpty {
                                            return tr
                                        }
                                        if let ex = q.exampleSentence, !ex.isEmpty {
                                            let parsed = parseEnglishAndTurkishExample(ex)
                                            if !parsed.tr.isEmpty {
                                                return parsed.tr
                                            }
                                        }
                                        return nil
                                    }()
                                    
                                    if let subTr = subtextTr, !subTr.isEmpty, subTr.trimmingCharacters(in: .whitespacesAndNewlines) != q.prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                                        HStack(alignment: .top, spacing: 8) {
                                            Rectangle()
                                                .fill(Color.blue)
                                                .frame(width: 3)
                                                .cornerRadius(1.5)
                                            Text(subTr)
                                                .font(.system(size: 13, design: .rounded))
                                                .italic()
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.top, 2)
                                    }
                                    
                                    Divider()
                                    
                                    // Question Options
                                    if q.questionType == "written" {
                                        VStack(alignment: .leading, spacing: 10) {
                                            // Eksik Harfler (Cellat Modu) Masked Answer Banner
                                            if modeMissingLetters || !(revealedHintIndicesMap[idx] ?? []).isEmpty {
                                                let targetAns = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                                                let revealedIndices = revealedHintIndicesMap[idx] ?? []
                                                
                                                ScrollView(.horizontal, showsIndicators: false) {
                                                    HStack(spacing: 6) {
                                                        ForEach(Array(targetAns.enumerated()), id: \.offset) { charIdx, char in
                                                            let charStr = String(char)
                                                            if charStr == " " {
                                                                Text(" ")
                                                                    .frame(width: 12)
                                                            } else {
                                                                let isRevealed = revealedIndices.contains(charIdx)
                                                                Text(isRevealed ? charStr : "_")
                                                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                                                    .foregroundColor(isRevealed ? .blue : .gray.opacity(0.5))
                                                            }
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.blue.opacity(0.06))
                                                .cornerRadius(12)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                                                )
                                            }
                                            
                                            TextField("Doğru kelimeyi buraya yazın...", text: Binding(
                                                get: { userAnswersMap[idx] ?? "" },
                                                set: { userAnswersMap[idx] = $0 }
                                            ))
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .padding(12)
                                            .background(Color.black.opacity(0.04))
                                            .cornerRadius(12)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled(false)
                                            .submitLabel(idx + 1 < activeQuestions.count ? .next : .done)
                                            .focused($focusedQuestionIdx, equals: idx)
                                            .onSubmit {
                                                if idx + 1 < activeQuestions.count {
                                                    focusedQuestionIdx = idx + 1
                                                    withAnimation(.easeInOut(duration: 0.35)) {
                                                        scrollProxy.scrollTo(idx + 1, anchor: .center)
                                                    }
                                                } else {
                                                    focusedQuestionIdx = nil
                                                }
                                            }
                                            
                                            // Yardımcı Araçlar: Harf Sayacı
                                            if helpShowLetterCounter {
                                                let typed = (userAnswersMap[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                                let target = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                                                let isLengthMatch = typed.count == target.count
                                                let isExactMatch = typed.lowercased() == target.lowercased()
                                                
                                                let familyTerms = (q.targetWord.wordFamily ?? []).map { parseFamilyItem($0).term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                                let isFamilyMatch = !isExactMatch && !typed.isEmpty && familyTerms.contains(typed.lowercased())
                                                
                                                let counterColor: Color = isFamilyMatch && helpColorOnExactMatch ? .purple : (isExactMatch && helpColorOnExactMatch ? .blue : (isLengthMatch && helpColorOnLengthMatch ? .green : .secondary))
                                                
                                                HStack {
                                                    Spacer()
                                                    Text("\(typed.count) / \(target.count) harf")
                                                        .font(.system(size: 11, weight: (isLengthMatch || isExactMatch || isFamilyMatch) ? .bold : .medium, design: .rounded))
                                                        .foregroundColor(counterColor)
                                                }
                                                .padding(.top, 2)
                                            }
                                        }
                                    } else if q.questionType == "tf" {
                                        VStack(alignment: .leading, spacing: 10) {
                                            let isPromptTerm = q.prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == q.targetWord.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                                            let labelText = isPromptTerm ? "Eşleşen anlam bu mu?" : "Eşleşen kelime bu mu?"
                                            
                                            Text(labelText)
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundColor(.secondary)
                                            
                                            let statementText = q.statement ?? q.correctAnswer
                                            HStack(spacing: 8) {
                                                Text(statementText)
                                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                                    .foregroundColor(.blue)
                                                
                                                Spacer()
                                                
                                                Button(action: {
                                                    TextToSpeechManager.shared.speak(statementText, language: q.targetWord.language)
                                                }) {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundColor(.blue)
                                                }
                                            }
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.blue.opacity(0.06))
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                            )
                                            
                                            HStack(spacing: 12) {
                                                ForEach(["Doğru", "Yanlış"], id: \.self) { tfOpt in
                                                    let isSel = userAnswersMap[idx] == tfOpt
                                                    Button(action: {
                                                        if isSel {
                                                            userAnswersMap[idx] = nil
                                                        } else {
                                                            userAnswersMap[idx] = tfOpt
                                                            if idx + 1 < activeQuestions.count {
                                                                withAnimation(.easeInOut(duration: 0.35)) {
                                                                    scrollProxy.scrollTo(idx + 1, anchor: .center)
                                                                }
                                                            }
                                                        }
                                                    }) {
                                                        Text(tfOpt)
                                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                                            .foregroundColor(isSel ? .white : .primary)
                                                            .frame(maxWidth: .infinity)
                                                            .padding(.vertical, 12)
                                                            .background(isSel ? Color.blue : Color.black.opacity(0.04))
                                                            .cornerRadius(12)
                                                    }
                                                }
                                            }
                                        }
                                    } else if q.questionType == "flashcard" {
                                        let isFlipped = (revealedHintIndicesMap[idx] ?? []).contains(999)
                                        VStack(spacing: 12) {
                                            Button(action: {
                                                var set = revealedHintIndicesMap[idx] ?? []
                                                if set.contains(999) { set.removeAll(where: { $0 == 999 }) }
                                                else { set.append(999) }
                                                revealedHintIndicesMap[idx] = set
                                            }) {
                                                HStack(spacing: 8) {
                                                    if !isFlipped {
                                                        Image(systemName: "eye.fill")
                                                        Text("Görmek için tıkla")
                                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                                    } else {
                                                        Text("Cevap:")
                                                            .font(.system(size: 13, design: .rounded))
                                                            .foregroundColor(.secondary)
                                                        Text(q.correctAnswer)
                                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                                            .foregroundColor(.blue)
                                                        
                                                        if let pron = getOptionPronunciation(optText: q.correctAnswer, targetWord: q.targetWord) {
                                                            Text("(\(pron))")
                                                                .font(.system(size: 13, design: .rounded))
                                                                .foregroundColor(.blue.opacity(0.8))
                                                        }
                                                    }
                                                }
                                                .padding(14)
                                                .frame(maxWidth: .infinity)
                                                .background(isFlipped ? Color.blue.opacity(0.1) : Color.black.opacity(0.04))
                                                .cornerRadius(12)
                                            }
                                            
                                            HStack(spacing: 12) {
                                                ForEach([("Bildim", Color.green), ("Bilmedim", Color.red)], id: \.0) { title, col in
                                                    let isSel = userAnswersMap[idx] == title
                                                    Button(action: {
                                                        userAnswersMap[idx] = isSel ? nil : title
                                                        if idx + 1 < activeQuestions.count {
                                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                                scrollProxy.scrollTo(idx + 1, anchor: .center)
                                                            }
                                                        }
                                                    }) {
                                                        Text(title)
                                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                                            .foregroundColor(isSel ? .white : col)
                                                            .frame(maxWidth: .infinity)
                                                            .padding(.vertical, 12)
                                                            .background(isSel ? col : col.opacity(0.1))
                                                            .cornerRadius(12)
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        // MCQ / Flashcard Options 2x2 Grid
                                        let hiddenForThisQ = hiddenOptionsMap[idx] ?? []
                                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                            ForEach(Array(q.options.enumerated()), id: \.offset) { optIdx, optText in
                                                let isHidden = hiddenForThisQ.contains(optText)
                                                if !isHidden {
                                                    let isSel = userAnswersMap[idx] == optText
                                                    Button(action: {
                                                        if isSel {
                                                            userAnswersMap[idx] = nil
                                                        } else {
                                                            userAnswersMap[idx] = optText
                                                            if idx + 1 < activeQuestions.count {
                                                                withAnimation(.easeInOut(duration: 0.35)) {
                                                                    scrollProxy.scrollTo(idx + 1, anchor: .center)
                                                                }
                                                            }
                                                        }
                                                    }) {
                                                        HStack(spacing: 8) {
                                                            Text("\(optIdx + 1)")
                                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                                .foregroundColor(isSel ? .blue : .primary)
                                                                .frame(width: 22, height: 22)
                                                                .background(isSel ? Color.white : Color.black.opacity(0.08))
                                                                .clipShape(Circle())
                                                            
                                                            VStack(alignment: .leading, spacing: 2) {
                                                                Text(optText)
                                                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                                    .foregroundColor(isSel ? .white : .primary)
                                                                    .lineLimit(2)
                                                                    .multilineTextAlignment(.leading)
                                                                
                                                                if let optPron = getOptionPronunciation(optText: optText, targetWord: q.targetWord) {
                                                                    Text("(\(optPron))")
                                                                        .font(.system(size: 10, design: .rounded))
                                                                        .foregroundColor(isSel ? .white.opacity(0.85) : .secondary)
                                                                }
                                                            }
                                                            
                                                            Spacer(minLength: 0)
                                                            
                                                            Button(action: {
                                                                TextToSpeechManager.shared.speak(optText, language: q.targetWord.language)
                                                            }) {
                                                                Image(systemName: "speaker.wave.2")
                                                                    .font(.system(size: 12))
                                                                    .foregroundColor(isSel ? .white.opacity(0.8) : .blue)
                                                            }
                                                        }
                                                        .padding(12)
                                                        .background(isSel ? Color.blue : Color.black.opacity(0.03))
                                                        .cornerRadius(14)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 14)
                                                                .stroke(isSel ? Color.blue : Color.black.opacity(0.06), lineWidth: 1)
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(16)
                                .background(Color.white)
                                .cornerRadius(18)
                                .shadow(color: Color.black.opacity(0.025), radius: 5, x: 0, y: 2)
                                .overlay(alignment: .topTrailing) {
                                    if hasQuestionStickyNote {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 10, height: 10)
                                            .shadow(color: Color.orange.opacity(0.5), radius: 3, x: 0, y: 1)
                                            .offset(x: -12, y: 12)
                                    }
                                }
                                .id(idx)
                            }
                            
                            // Bottom Finish Test Button
                            Button(action: {
                                handleFinishTestAttempt()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Testi Bitir & Sonuçları Gör")
                                }
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(16)
                                .shadow(color: Color.blue.opacity(0.25), radius: 6, x: 0, y: 3)
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 40)
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.never)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            HStack {
                                Spacer()
                                
                                HStack(spacing: 24) {
                                    // Aktif kutudaki metni temizle (X simgesi - En Solda)
                                    Button(action: {
                                        if let cur = focusedQuestionIdx {
                                            userAnswersMap[cur] = ""
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor((focusedQuestionIdx != nil && !(userAnswersMap[focusedQuestionIdx ?? -1]?.isEmpty ?? true)) ? Color.gray.opacity(0.75) : Color.gray.opacity(0.3))
                                    }
                                    .disabled(focusedQuestionIdx == nil || (userAnswersMap[focusedQuestionIdx ?? -1]?.isEmpty ?? true))
                                    
                                    // Önceki Soru (Yukarı Ok)
                                    Button(action: {
                                        if let cur = focusedQuestionIdx, cur > 0 {
                                            focusedQuestionIdx = cur - 1
                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                scrollProxy.scrollTo(cur - 1, anchor: .center)
                                            }
                                        }
                                    }) {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor((focusedQuestionIdx ?? 0) > 0 ? Color.primary : Color.gray.opacity(0.35))
                                    }
                                    .disabled((focusedQuestionIdx ?? 0) <= 0)
                                    
                                    // Sonraki Soru (Aşağı Ok)
                                    Button(action: {
                                        if let cur = focusedQuestionIdx, cur + 1 < activeQuestions.count {
                                            focusedQuestionIdx = cur + 1
                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                scrollProxy.scrollTo(cur + 1, anchor: .center)
                                            }
                                        }
                                    }) {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor((focusedQuestionIdx ?? 0) < activeQuestions.count - 1 ? Color.primary : Color.gray.opacity(0.35))
                                    }
                                    .disabled((focusedQuestionIdx ?? 0) >= activeQuestions.count - 1)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(Capsule())
                                .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                            }
                        }
                    }
                }
            }
        }
        .alert("Çözülmemiş Sorular Var", isPresented: $showUnansweredWarningAlert) {
            Button("Geri Dön", role: .cancel) { }
            Button("Devam Et") {
                finishActiveTest()
            }
        } message: {
            let count = activeQuestions.indices.filter { idx in
                (userAnswersMap[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            Text("Testte henüz çözülmemiş \(count) soru bulunmaktadır. Yine de testi bitirmek istediğinize emin misiniz?")
        }
    }
                    
                    // MARK: - Test Results View (Web-Matched with Kelimeleri Yonet)
                    @ViewBuilder
                    private var testResultsView: some View {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 20) {
                                // Top Navigation Header with Geri Don Button
                                HStack {
                                    Button(action: { viewMode = "options" }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "chevron.left")
                                                .font(.system(size: 13, weight: .bold))
                                            Text("Geri Dön")
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        }
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(10)
                                    }
                                    
                                    Spacer()
                                    
                                    Text("Test Sonucu")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Color.clear.frame(width: 75, height: 28)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                
                                // Score Summary Card
                                VStack(spacing: 14) {
                                    let totalCount = testResultsList.count
                                    let correctCount = testResultsList.filter { $0.isCorrect }.count
                                    let percent = totalCount > 0 ? Int(Double(correctCount) / Double(totalCount) * 100) : 0
                                    
                                    ZStack {
                                        Circle()
                                            .stroke(Color.black.opacity(0.06), lineWidth: 10)
                                        Circle()
                                            .trim(from: 0, to: CGFloat(percent) / 100)
                                            .stroke(percent >= 70 ? Color.green : (percent >= 40 ? Color.orange : Color.red), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                        VStack(spacing: 2) {
                                            Text("%\(percent)")
                                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                                .foregroundColor(.primary)
                                            Text("BAŞARI")
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 110, height: 110)
                                    .padding(.top, 10)
                                    
                                    let exactCount = testResultsList.filter { $0.isCorrect && !$0.isTypo }.count
                                    let typosCount = testResultsList.filter { $0.isTypo }.count
                                    let wrongCount = testResultsList.filter { !$0.isCorrect && $0.userAnswer != "Boş bırakıldı" }.count
                                    let blankCount = testResultsList.filter { $0.userAnswer == "Boş bırakıldı" }.count
                                    
                                    HStack(spacing: 12) {
                                        statCell(title: typosCount > 0 ? "Tam Doğru" : "Doğru", value: "\(exactCount)", color: .green)
                                        if typosCount > 0 {
                                            statCell(title: "Hatalı", value: "\(typosCount)", color: .orange)
                                        }
                                        statCell(title: "Yanlış", value: "\(wrongCount)", color: .red)
                                        statCell(title: "Boş", value: "\(blankCount)", color: .gray)
                                    }
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity)
                                .background(Color.white)
                                .cornerRadius(20)
                                .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                
                                // Fast Repeat Action Buttons
                                VStack(spacing: 10) {
                                    Button(action: { retakeSameTest() }) {
                                        HStack(spacing: 12) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.blue)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Aynı Testi Yeniden Çöz")
                                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                Text("Aynı kelimelerle testi tekrarla.")
                                                    .font(.system(size: 11, design: .rounded))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(14)
                                        .background(Color.white)
                                        .cornerRadius(14)
                                        .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                                    }
                                    
                                    if testResultsList.contains(where: { !$0.isCorrect }) {
                                        Button(action: { retakeMissedQuestions() }) {
                                            HStack(spacing: 12) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.red)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Sadece Hataları Çöz")
                                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                                        .foregroundColor(.red)
                                                    Text("\(testResultsList.filter { !$0.isCorrect }.count) soruyu tekrarla.")
                                                        .font(.system(size: 11, design: .rounded))
                                                        .foregroundColor(.red.opacity(0.8))
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.red)
                                            }
                                            .padding(14)
                                            .background(Color.red.opacity(0.08))
                                            .cornerRadius(14)
                                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.2), lineWidth: 1))
                                        }
                                    }
                                    
                                    Button(action: { startNewTest() }) {
                                        HStack(spacing: 12) {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.purple)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Yeni Test Başlat")
                                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                Text("Farklı kelimelerle yeni test oluştur.")
                                                    .font(.system(size: 11, design: .rounded))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(14)
                                        .background(Color.white)
                                        .cornerRadius(14)
                                        .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                                    }
                                }
                                .padding(.horizontal, 16)
                                
                                // Question Categories Accordion Summary
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("Kategori Özeti")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        let starredInTest = allWords.filter { w in activeQuestions.contains(where: { $0.wordId == w.id }) && w.isStarred }
                                        Button(action: {
                                            for w in starredInTest {
                                                toggleWordStar(w)
                                            }
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "star.slash")
                                                Text("Yıldızları Kaldır (\(starredInTest.count))")
                                            }
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.red.opacity(0.1))
                                            .cornerRadius(10)
                                        }
                                        .disabled(starredInTest.isEmpty)
                                    }
                                    
                                    let familyQuestions = testResultsList.filter { $0.isWordFamily }
                                    let typoQuestions = testResultsList.filter { $0.isTypo }
                                    let correctQuestions = testResultsList.filter { $0.isCorrect && !$0.isTypo && !$0.isWordFamily }
                                    let blankQuestions = testResultsList.filter { $0.userAnswer == "Boş bırakıldı" }
                                    let wrongQuestions = testResultsList.filter { !$0.isCorrect && $0.userAnswer != "Boş bırakıldı" }
                                    
                                    VStack(spacing: 8) {
                                        if !familyQuestions.isEmpty {
                                            accordionCategoryRow(key: "families", title: "Kelime Ailesi", count: familyQuestions.count, icon: "network", color: .purple, questionList: familyQuestions)
                                        }
                                        accordionCategoryRow(key: "errors", title: "Hatalı Kelimeler", count: typoQuestions.count, icon: "exclamationmark.triangle.fill", color: .orange, questionList: typoQuestions)
                                        accordionCategoryRow(key: "corrects", title: "Doğru Kelimeler", count: correctQuestions.count, icon: "checkmark.circle.fill", color: .green, questionList: correctQuestions)
                                        accordionCategoryRow(key: "blanks", title: "Boş Bırakılanlar", count: blankQuestions.count, icon: "slash.circle", color: .gray, questionList: blankQuestions)
                                        accordionCategoryRow(key: "wrongs", title: "Yanlış Kelimeler", count: wrongQuestions.count, icon: "xmark.circle.fill", color: .red, questionList: wrongQuestions)
                                    }
                                }
                                .padding(16)
                                .background(Color.white)
                                .cornerRadius(20)
                                .shadow(color: Color.black.opacity(0.025), radius: 5, x: 0, y: 2)
                                .padding(.horizontal, 16)
                                
                                // Question Breakdown List
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Soru ve Yanıt Detayı")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 20)
                                    
                                    VStack(spacing: 12) {
                                        ForEach(Array(testResultsList.enumerated()), id: \.offset) { idx, item in
                                            let word = allWords.first(where: { $0.id == item.wordId })
                                            let itemBadgeText = item.isWordFamily ? "Kelime Ailesi" : (item.isTypo ? "Hatalı" : (item.isCorrect ? "Doğru" : "Yanlış"))
                                            let itemBadgeColor: Color = item.isWordFamily ? .purple : (item.isTypo ? .orange : (item.isCorrect ? .green : .red))
                                            
                                            VStack(alignment: .leading, spacing: 10) {
                                                HStack {
                                                    Text("\(idx + 1)")
                                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                                        .foregroundColor(.white)
                                                        .frame(width: 22, height: 22)
                                                        .background(Color.gray.opacity(0.6))
                                                        .clipShape(Circle())
                                                    
                                                        Button(action: {
                                                         if let matched = word ?? allWords.first(where: { $0.term.lowercased() == item.wordTerm.lowercased() }) {
                                                             onSelectWord(matched)
                                                         }
                                                     }) {
                                                         HStack(spacing: 4) {
                                                             Text(item.wordTerm)
                                                                 .font(.system(size: 15, weight: .bold, design: .rounded))
                                                                 .foregroundColor(.primary)
                                                             Image(systemName: "info.circle")
                                                                 .font(.system(size: 12))
                                                                 .foregroundColor(.blue.opacity(0.8))
                                                         }
                                                     }
                                                    
                                                    Spacer()
                                                    
                                                    Button(action: {
                                                        if let w = word { toggleWordStar(w) }
                                                    }) {
                                                        Image(systemName: (word?.isStarred ?? false) ? "star.fill" : "star")
                                                            .foregroundColor((word?.isStarred ?? false) ? .yellow : .gray.opacity(0.4))
                                                            .font(.system(size: 15))
                                                    }
                                                    
                                                    Menu {
                                                        Button("Yeni") { if let w = word { updateWordLearningStage(word: w, newStage: 0) } }
                                                        Button("Öğreniyor") { if let w = word { updateWordLearningStage(word: w, newStage: 5) } }
                                                        Button("Öğrendi") { if let w = word { updateWordLearningStage(word: w, newStage: 10) } }
                                                    } label: {
                                                        let stage = word?.learningStage ?? 0
                                                        let statusText = stage == 0 ? "Yeni" : (stage >= 10 ? "Öğrendi" : "Öğreniyor")
                                                        let statusColor: Color = stage == 0 ? .blue : (stage >= 10 ? .green : .orange)
                                                        Text(statusText)
                                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                                            .foregroundColor(statusColor)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 3)
                                                            .background(statusColor.opacity(0.12))
                                                            .cornerRadius(6)
                                                    }
                                                    
                                                    Button(action: {
                                                        TextToSpeechManager.shared.speak(item.wordTerm)
                                                    }) {
                                                        Image(systemName: "speaker.wave.2.fill")
                                                            .font(.system(size: 14))
                                                            .foregroundColor(.blue)
                                                    }
                                                    
                                                    Text(itemBadgeText)
                                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                                        .foregroundColor(itemBadgeColor)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 3)
                                                        .background(itemBadgeColor.opacity(0.12))
                                                        .cornerRadius(6)
                                                }
                                                
                                                Text(item.questionPrompt)
                                                    .font(.system(size: 13, design: .rounded))
                                                    .foregroundColor(.secondary)
                                                
                                                HStack(spacing: 12) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("Sizin Yanıtınız:")
                                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                            .foregroundColor(.secondary)
                                                        Text(item.userAnswer)
                                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                                            .foregroundColor(itemBadgeColor)
                                                    }
                                                    
                                                    if !item.isCorrect || item.isTypo || item.isWordFamily {
                                                        Spacer()
                                                        VStack(alignment: .trailing, spacing: 2) {
                                                            Text("Doğru Yanıt:")
                                                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                                .foregroundColor(.secondary)
                                                            Text(item.correctAnswer)
                                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                                .foregroundColor(.green)
                                                        }
                                                    }
                                                }
                                                .padding(10)
                                                .background(Color.black.opacity(0.03))
                                                .cornerRadius(10)
                                            }
                                            .padding(14)
                                            .background(Color.white)
                                            .cornerRadius(16)
                                            .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                                
                                // Bottom Geri Don Button
                                Button(action: { viewMode = "options" }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "chevron.left")
                                        Text("Geri Dön")
                                    }
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.black.opacity(0.06))
                                    .cornerRadius(14)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 40)
                            }
                        }
                    }
                    
                    @ViewBuilder
                    private func accordionCategoryRow(key: String, title: String, count: Int, icon: String, color: Color, questionList: [QuestionAnswerResult]) -> some View {
                        let isExpanded = openCategoryKey == key
                        
                        VStack(spacing: 0) {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    openCategoryKey = isExpanded ? nil : key
                                }
                            }) {
                                HStack {
                                    Image(systemName: icon)
                                        .foregroundColor(color)
                                        .font(.system(size: 15))
                                    Text(title)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                    
                                    Text("\(count)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(color)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(color.opacity(0.12))
                                        .cornerRadius(10)
                                    
                                    Spacer()
                                    
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                                .padding(12)
                                .background(color.opacity(0.06))
                                .cornerRadius(12)
                            }
                            
                            if isExpanded {
                                VStack(alignment: .leading, spacing: 12) {
                                    if questionList.isEmpty {
                                        Text("Bu kategoride kelime bulunmuyor.")
                                            .font(.system(size: 12, design: .rounded))
                                            .foregroundColor(.secondary)
                                            .padding(.vertical, 8)
                                    } else {
                                        let catWords = allWords.filter { w in questionList.contains(where: { $0.wordId == w.id }) }
                                        let allStarred = !catWords.isEmpty && catWords.allSatisfy { $0.isStarred }
                                        let allYeni = !catWords.isEmpty && catWords.allSatisfy { $0.learningStage == 0 }
                                        let allOgreniyor = !catWords.isEmpty && catWords.allSatisfy { $0.learningStage > 0 && $0.learningStage < 10 }
                                        let allOgrendi = !catWords.isEmpty && catWords.allSatisfy { $0.learningStage >= 10 }
                                        
                                        VStack(spacing: 10) {
                                            // Yıldızlı Switch
                                            Toggle(isOn: Binding(
                                                get: { allStarred },
                                                set: { val in
                                                    for w in catWords {
                                                        if w.isStarred != val { toggleWordStar(w) }
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "star.fill")
                                                        .foregroundColor(.yellow)
                                                        .font(.system(size: 14))
                                                    Text("Yıldızlı")
                                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                }
                                            }
                                            .tint(.yellow)
                                            
                                            Divider()
                                            
                                            // Yeni Switch
                                            Toggle(isOn: Binding(
                                                get: { allYeni },
                                                set: { val in
                                                    if val {
                                                        for w in catWords { updateWordLearningStage(word: w, newStage: 0) }
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Circle()
                                                        .stroke(Color.blue, lineWidth: 2)
                                                        .frame(width: 12, height: 12)
                                                    Text("Yeni")
                                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                }
                                            }
                                            .tint(.blue)
                                            
                                            // Öğreniyor Switch
                                            Toggle(isOn: Binding(
                                                get: { allOgreniyor },
                                                set: { val in
                                                    if val {
                                                        for w in catWords { updateWordLearningStage(word: w, newStage: 5) }
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Circle()
                                                        .stroke(Color.orange, lineWidth: 2)
                                                        .frame(width: 12, height: 12)
                                                    Text("Öğreniyor")
                                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                }
                                            }
                                            .tint(.orange)
                                            
                                            // Öğrendi Switch
                                            Toggle(isOn: Binding(
                                                get: { allOgrendi },
                                                set: { val in
                                                    if val {
                                                        for w in catWords { updateWordLearningStage(word: w, newStage: 10) }
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.green)
                                                        .font(.system(size: 14))
                                                    Text("Öğrendi")
                                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                }
                                            }
                                            .tint(.green)
                                        }
                                    }
                                }
                                .padding(14)
                                .background(Color.black.opacity(0.025))
                                .cornerRadius(12)
                                .padding(.top, 4)
                            }
                        }
                    }
    
    private func retakeSameTest() {
        activeTestId = nil
        userAnswersMap.removeAll()
        testResultsList.removeAll()
        currentQuestionIndex = 0
        score = 0
        comboStreak = 0
        isAnswerSubmitted = false
        selectedAnswerOption = nil
        writtenInputText = ""
        isCardFlipped = false
        hiddenOptionsMap.removeAll()
        
        // Shuffle question order AND answer option positions for each question
        activeQuestions = activeQuestions.shuffled().map { q in
            PracticeQuestionItem(
                id: q.id,
                wordId: q.wordId,
                targetWord: q.targetWord,
                questionType: q.questionType,
                prompt: q.prompt,
                correctAnswer: q.correctAnswer,
                options: q.options.shuffled(),
                isTrueStatement: q.isTrueStatement,
                statement: q.statement,
                exampleSentence: q.exampleSentence,
                turkishTranslation: q.turkishTranslation
            )
        }
        
        withAnimation { viewMode = "active" }
    }
    
    @State private var hiddenOptionsMap: [Int: [String]] = [:]
    
    private func toggleWordStar(_ word: LocalWord) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("words").document(word.id)
        let target = !word.isStarred
        
        if let idx = allWords.firstIndex(where: { $0.id == word.id }) {
            var updated = allWords[idx]
            updated.isStarred = target
            allWords[idx] = updated
        }
        
        Task {
            try? await ref.updateData(["isStarred": target])
        }
    }
    
    private func updateWordLearningStage(word: LocalWord, newStage: Int) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("words").document(word.id)
        
        let newStatus: String
        if newStage == 0 { newStatus = "Yeni" }
        else if newStage >= 10 { newStatus = "Öğrendi" }
        else { newStatus = "Öğreniyor" }
        
        if let idx = allWords.firstIndex(where: { $0.id == word.id }) {
            var updated = allWords[idx]
            updated.learningStage = newStage
            allWords[idx] = updated
        }
        
        Task {
            try? await ref.updateData([
                "learningStage": newStage,
                "learningStatus": newStatus
            ])
        }
    }
    
    private func retakeMissedQuestions() {
        activeTestId = nil
        let missedWordIds = Set(testResultsList.filter { !$0.isCorrect }.map { $0.wordId })
        let missedWords = allWords.filter { missedWordIds.contains($0.id) }
        if missedWords.isEmpty { return }
        
        var availableTypes: [String] = []
        if typeMCQ { availableTypes.append("mcq") }
        if typeTF { availableTypes.append("tf") }
        if typeFlashcard { availableTypes.append("flashcard") }
        if typeWritten { availableTypes.append("written") }
        if availableTypes.isEmpty { availableTypes = ["mcq"] }
        
        var generated: [PracticeQuestionItem] = []
        for word in missedWords {
            let qType = availableTypes.randomElement() ?? "mcq"
            let format = questionFormat == "mixed" ? (Bool.random() ? "definition" : "term") : questionFormat
            let prompt = format == "definition" ? word.shortMeanings : word.term
            let correct = format == "definition" ? word.term : word.shortMeanings
            
            var options: [String] = [correct]
            let distractorsPool = allWords.filter { $0.id != word.id }.map { format == "definition" ? $0.term : $0.shortMeanings }
            let randomDistractors = Array(distractorsPool.shuffled().prefix(3))
            options.append(contentsOf: randomDistractors)
            options.shuffle()
            
            let firstEx = word.meanings?.first?.examples.first
            let exSentence = firstEx?.en
            let trTrans = firstEx?.tr
            
            generated.append(PracticeQuestionItem(
                id: UUID().uuidString,
                wordId: word.id,
                targetWord: word,
                questionType: qType,
                prompt: prompt,
                correctAnswer: correct,
                options: options,
                isTrueStatement: qType == "tf" ? Bool.random() : nil,
                statement: prompt,
                exampleSentence: exSentence,
                turkishTranslation: trTrans
            ))
        }
        
        activeQuestions = generated
        currentQuestionIndex = 0
        userAnswersMap.removeAll()
        testResultsList = []
        score = 0
        comboStreak = 0
        isAnswerSubmitted = false
        selectedAnswerOption = nil
        writtenInputText = ""
        viewMode = "active"
        saveActiveTestState()
    }
    
    // MARK: - Test Creation & Engine Helpers
    private func startNewTest() {
        activeTestId = nil
        var pool = allWords
        
        userAnswersMap.removeAll()
        hiddenOptionsMap.removeAll()
        revealedHintIndicesMap.removeAll()
        
        if onlyStarred {
            pool = pool.filter { $0.isStarred }
        }
        
        if excludeStarred {
            pool = pool.filter { !$0.isStarred }
        }
        
        if selectedLanguage != "all" {
            pool = pool.filter { $0.language == selectedLanguage }
        }
        
        if !selectedListIds.isEmpty {
            let allowedIds = Set(customLists.filter { selectedListIds.contains($0.id) }.flatMap { $0.wordIds })
            pool = pool.filter { allowedIds.contains($0.id) }
        }
        
        let statusFilters: [String] = [
            statusYeni ? "Yeni" : "",
            statusOgreniyor ? "Öğreniyor" : "",
            statusOgrendi ? "Öğrendi" : ""
        ].filter { !$0.isEmpty }
        
        if !statusFilters.isEmpty {
            pool = pool.filter { word in
                let wordStatus = word.learningStage == 0 ? "Yeni" : (word.learningStage >= 5 ? "Öğrendi" : "Öğreniyor")
                return statusFilters.contains(wordStatus)
            }
        }
        
        if excludeSolvedToday {
            pool = pool.filter { !solvedWordIdsFromPracticeTests.contains($0.id) }
        }
        
        if pool.isEmpty {
            activeQuestions = []
            viewMode = "active"
            return
        }
        
        if shufflePool {
            pool.shuffle()
        }
        
        let targetWords = Array(pool.prefix(Int(questionCount)))
        
        // Build question types array
        var availableTypes: [String] = []
        if typeMCQ { availableTypes.append("mcq") }
        if typeTF { availableTypes.append("tf") }
        if typeFlashcard { availableTypes.append("flashcard") }
        if typeWritten { availableTypes.append("written") }
        if availableTypes.isEmpty { availableTypes = ["mcq"] }
        
        var generated: [PracticeQuestionItem] = []
        for word in targetWords {
            let qType = availableTypes.randomElement() ?? "mcq"
            let format = questionFormat == "mixed" ? (Bool.random() ? "definition" : "term") : questionFormat
            
            var prompt = format == "definition" ? word.shortMeanings : word.term
            var correct = format == "definition" ? word.term : word.shortMeanings
            var turkishTranslation: String? = nil
            var exSentence: String? = nil
            
            if modeFillInTheBlanks {
                var foundEn: String? = nil
                var foundTr: String? = nil
                
                if let meanings = word.meanings {
                    for m in meanings {
                        if !m.examples.isEmpty {
                            if let firstEx = m.examples.first(where: { !$0.en.isEmpty }) {
                                foundEn = firstEx.en
                                foundTr = firstEx.tr
                                break
                            }
                        }
                    }
                }
                
                if foundEn == nil, let col = word.collocations?.first, !col.isEmpty {
                    foundEn = col
                }
                
                if let rawEn = foundEn, !rawEn.isEmpty {
                    let termLower = word.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let replaceStr = String(repeating: "_ ", count: max(5, word.term.count)).trimmingCharacters(in: .whitespaces)
                    
                    var processed = rawEn
                    var extractedWord = word.term
                    
                    if let range = rawEn.range(of: termLower, options: .caseInsensitive) {
                        extractedWord = String(rawEn[range])
                        processed = rawEn.replacingCharacters(in: range, with: replaceStr)
                    } else {
                        let termRoot = String(termLower.prefix(max(3, termLower.count - 2)))
                        if let rootRange = rawEn.range(of: termRoot, options: .caseInsensitive) {
                            processed = rawEn.replacingCharacters(in: rootRange, with: replaceStr)
                        } else {
                            processed = "\(rawEn) (\(replaceStr))"
                        }
                    }
                    
                    prompt = processed
                    correct = extractedWord
                    turkishTranslation = foundTr
                    exSentence = rawEn
                }
            }
            
            // Build distractors for MCQ
            var options: [String] = [correct]
            let distractorsPool = allWords.filter { $0.id != word.id }.map { (modeFillInTheBlanks || format == "definition") ? $0.term : $0.shortMeanings }
            let randomDistractors = Array(distractorsPool.shuffled().prefix(3))
            options.append(contentsOf: randomDistractors)
            options.shuffle()
            
            let isTrue = Bool.random()
            let stmt = isTrue ? correct : (distractorsPool.randomElement() ?? "Bilinmiyor")
            
            generated.append(PracticeQuestionItem(
                id: UUID().uuidString,
                wordId: word.id,
                targetWord: word,
                questionType: qType,
                prompt: prompt,
                correctAnswer: correct,
                options: options,
                isTrueStatement: isTrue,
                statement: stmt,
                exampleSentence: exSentence,
                turkishTranslation: turkishTranslation
            ))
        }
        
        activeQuestions = generated
        currentQuestionIndex = 0
        score = 0
        comboStreak = 0
        testResultsList = []
        selectedAnswerOption = nil
        isAnswerSubmitted = false
        writtenInputText = ""
        isCardFlipped = false
        
        savePratikSettings()
        withAnimation {
            viewMode = "active"
        }
        saveActiveTestState()
    }
    
    private func startTestFromQuickTemplate(_ template: QuickTestTemplate) {
        selectedQuickTestId = template.id
        selectedListIds.remove("smart_unsolved")
        
        questionCount = Double(template.questionCount)
        questionFormat = template.questionFormat
        selectedLanguage = template.selectedLanguage
        
        typeMCQ = template.typeMCQ
        typeTF = template.typeTF
        typeFlashcard = template.typeFlashcard
        typeWritten = template.typeWritten
        
        statusYeni = template.statusYeni
        statusOgreniyor = template.statusOgreniyor
        statusOgrendi = template.statusOgrendi
        
        onlyStarred = template.onlyStarred
        excludeStarred = template.excludeStarred
        excludeSolvedToday = template.excludeSolvedToday
        shufflePool = template.shufflePool
        
        modeFillInTheBlanks = template.modeFillInTheBlanks
        smartDistractors = template.smartDistractors
        modeMissingLetters = template.modeMissingLetters
        modeSingleMeaning = template.modeSingleMeaning
        modeComboStreak = template.modeComboStreak
        modeProgressiveHint = template.modeProgressiveHint
        maxAllowedTypoLetters = template.maxAllowedTypoLetters
        
        savePratikSettings()
    }
    
    private func isQuickTestModified(_ test: QuickTestTemplate) -> Bool {
        guard selectedQuickTestId == test.id else { return false }
        if Int(questionCount) != test.questionCount { return true }
        if questionFormat != test.questionFormat { return true }
        if selectedLanguage != test.selectedLanguage { return true }
        if typeMCQ != test.typeMCQ { return true }
        if typeTF != test.typeTF { return true }
        if typeFlashcard != test.typeFlashcard { return true }
        if typeWritten != test.typeWritten { return true }
        if statusYeni != test.statusYeni { return true }
        if statusOgreniyor != test.statusOgreniyor { return true }
        if statusOgrendi != test.statusOgrendi { return true }
        if onlyStarred != test.onlyStarred { return true }
        if excludeStarred != test.excludeStarred { return true }
        if excludeSolvedToday != test.excludeSolvedToday { return true }
        if shufflePool != test.shufflePool { return true }
        if modeFillInTheBlanks != test.modeFillInTheBlanks { return true }
        if smartDistractors != test.smartDistractors { return true }
        if modeMissingLetters != test.modeMissingLetters { return true }
        if modeSingleMeaning != test.modeSingleMeaning { return true }
        if modeComboStreak != test.modeComboStreak { return true }
        if modeProgressiveHint != test.modeProgressiveHint { return true }
        if maxAllowedTypoLetters != test.maxAllowedTypoLetters { return true }
        return false
    }
    
    private func updateQuickTest(id: String) {
        guard let user = Auth.auth().currentUser, !id.isEmpty else { return }
        let db = Firestore.firestore()
        let tType = typeMCQ && !typeTF && !typeFlashcard && !typeWritten ? "Çoktan Seçmeli" : (typeWritten && !typeMCQ && !typeTF && !typeFlashcard ? "Yazılı" : "Karışık")
        let dir = questionFormat == "definition" ? "Türkçe -> Yabancı Dil" : (questionFormat == "term" ? "Yabancı Dil -> Türkçe" : "Karışık")
        let starOpt = onlyStarred ? "Sadece Yıldızlı" : (excludeStarred ? "Sadece Yıldızsız" : "Yıldızlı + Yıldızsız")
        
        let config: [String: Any] = [
            "questionCount": Int(questionCount),
            "type": tType,
            "questionFormat": questionFormat,
            "selectedLanguage": selectedLanguage,
            "language": selectedLanguage,
            "direction": dir,
            "typeMCQ": typeMCQ,
            "typeTF": typeTF,
            "typeFlashcard": typeFlashcard,
            "typeWritten": typeWritten,
            "questionTypes": ["mcq": typeMCQ, "tf": typeTF, "flashcard": typeFlashcard, "written": typeWritten],
            "statusYeni": statusYeni,
            "statusOgreniyor": statusOgreniyor,
            "statusOgrendi": statusOgrendi,
            "learningStatus": ["Yeni": statusYeni, "Öğreniyor": statusOgreniyor, "Öğrendi": statusOgrendi],
            "starOption": starOpt,
            "onlyStarred": onlyStarred,
            "excludeStarred": excludeStarred,
            "starOnly": onlyStarred,
            "excludeSolvedToday": excludeSolvedToday,
            "shuffle": shufflePool,
            "shufflePool": shufflePool,
            "advancedOptions": [
                "fillInTheBlanks": modeFillInTheBlanks,
                "smartDistractors": smartDistractors,
                "missingLetters": modeMissingLetters,
                "singleMeaning": modeSingleMeaning,
                "comboStreak": modeComboStreak,
                "progressiveHint": modeProgressiveHint
            ],
            "modeFillInTheBlanks": modeFillInTheBlanks,
            "smartDistractors": smartDistractors,
            "modeMissingLetters": modeMissingLetters,
            "modeSingleMeaning": modeSingleMeaning,
            "modeComboStreak": modeComboStreak,
            "modeProgressiveHint": modeProgressiveHint,
            "maxAllowedTypoLetters": maxAllowedTypoLetters
        ]
        
        let updates: [String: Any] = [
            "config": config,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        
        Task {
            do {
                try await db.collection("users").document(user.uid).collection("quick_tests").document(id).setData(updates, merge: true)
            } catch {
                print("Error updating quick test: \(error)")
            }
        }
    }
    
    private func renameQuickTest(id: String, newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        let updates: [String: Any] = [
            "name": name,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        
        Task {
            do {
                try await db.collection("users").document(user.uid).collection("quick_tests").document(id).setData(updates, merge: true)
            } catch {
                print("Error renaming quick test: \(error)")
            }
        }
    }
    
    private func deleteQuickTest(id: String) {
        guard let user = Auth.auth().currentUser, !id.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            quickTests.removeAll(where: { $0.id == id })
            if selectedQuickTestId == id {
                selectedQuickTestId = nil
            }
        }
        let db = Firestore.firestore()
        Task {
            do {
                try await db.collection("users").document(user.uid).collection("quick_tests").document(id).delete()
            } catch {
                print("Error deleting quick test: \(error)")
            }
        }
    }
    
    private func handleFinishTestAttempt() {
        let unansweredCount = activeQuestions.indices.filter { idx in
            (userAnswersMap[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        
        if unansweredCount > 0 {
            showUnansweredWarningAlert = true
        } else {
            finishActiveTest()
        }
    }
    
    private func finishActiveTest() {
        clearActiveTestState()
        var calculatedResults: [QuestionAnswerResult] = []
        var questionsArray: [[String: Any]] = []
        var answersDict: [String: [String: Any]] = [:]
        
        for (idx, q) in activeQuestions.enumerated() {
            let uAns = (userAnswersMap[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isAnswered = !uAns.isEmpty
            
            let isCorrect: Bool
            var isTypo = false
            var isWordFamily = false
            if q.questionType == "written" {
                let t = uAns.lowercased()
                let c = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                let familyTerms = (q.targetWord.wordFamily ?? []).map { parseFamilyItem($0).term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let isFamilyMatch = !familyTerms.isEmpty && familyTerms.contains(t)
                
                if t == c {
                    isCorrect = true
                    isTypo = false
                    isWordFamily = false
                } else if isFamilyMatch {
                    isCorrect = true
                    isTypo = false
                    isWordFamily = true
                } else {
                    let dist = levenshteinDistance(t, c)
                    if !t.isEmpty && maxAllowedTypoLetters > 0 && dist <= maxAllowedTypoLetters {
                        isCorrect = true
                        isTypo = true
                        isWordFamily = false
                    } else {
                        isCorrect = false
                        isTypo = false
                        isWordFamily = false
                    }
                }
            } else if q.questionType == "flashcard" {
                isCorrect = uAns == "Bildim"
            } else if q.questionType == "tf" {
                let expectedStr = (q.isTrueStatement ?? true) ? "Doğru" : "Yanlış"
                isCorrect = uAns == expectedStr
            } else {
                isCorrect = uAns.lowercased() == q.correctAnswer.lowercased()
            }
            
            let finalAnsText = isAnswered ? uAns : "Boş bırakıldı"
            
            calculatedResults.append(QuestionAnswerResult(
                wordId: q.wordId,
                wordTerm: q.targetWord.term,
                questionPrompt: q.prompt,
                correctAnswer: q.correctAnswer,
                userAnswer: finalAnsText,
                isCorrect: isCorrect,
                isTypo: isTypo,
                isWordFamily: isWordFamily
            ))
            
            if isAnswered {
                answersDict["\(idx)"] = [
                    "selected": [
                        "text": uAns,
                        "isCorrect": isCorrect,
                        "isTypo": isTypo,
                        "isWordFamily": isWordFamily
                    ]
                ]
            }
            
            let formattedOptions = q.options.map { optStr -> [String: Any] in
                let isCorrectOpt = optStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return [
                    "text": optStr,
                    "isCorrect": isCorrectOpt
                ]
            }
            
            let formatStr = q.prompt == q.targetWord.shortMeanings ? "definition" : "term"
            let qDict: [String: Any] = [
                "wordId": q.wordId,
                "prompt": q.prompt,
                "answer": q.correctAnswer,
                "correctAnswer": q.correctAnswer,
                "type": q.questionType,
                "format": formatStr,
                "options": formattedOptions,
                "exampleSentence": q.exampleSentence ?? "",
                "turkishTranslation": q.turkishTranslation ?? "",
                "targetWord": [
                    "id": q.targetWord.id,
                    "term": q.targetWord.term,
                    "shortMeanings": q.targetWord.shortMeanings,
                    "language": q.targetWord.language
                ]
            ]
            questionsArray.append(qDict)
        }
        
        self.testResultsList = calculatedResults
        let totalCount = activeQuestions.count
        let solvedCount = calculatedResults.filter { $0.userAnswer != "Boş bırakıldı" }.count
        let correctCount = calculatedResults.filter { $0.isCorrect }.count
        
        guard let user = Auth.auth().currentUser else {
            withAnimation { viewMode = "results" }
            return
        }
        
        let hasMCQ = activeQuestions.contains(where: { $0.questionType == "mcq" })
        let hasTF = activeQuestions.contains(where: { $0.questionType == "tf" })
        let hasFlashcard = activeQuestions.contains(where: { $0.questionType == "flashcard" })
        let hasWritten = activeQuestions.contains(where: { $0.questionType == "written" })
        
        let actualQuestionTypes: [String: Bool] = [
            "mcq": hasMCQ,
            "tf": hasTF,
            "flashcard": hasFlashcard,
            "written": hasWritten
        ]
        
        let db = Firestore.firestore()
        let testData: [String: Any] = [
            "name": "Pratik Test - \(Date().formatted(date: .abbreviated, time: .shortened))",
            "status": "completed",
            "completed": true,
            "questionCount": totalCount,
            "solvedCount": solvedCount,
            "correctCount": correctCount,
            "questions": questionsArray,
            "answers": answersDict,
            "writtenInputs": [String: Any](),
            "hintsUsed": [String: Any](),
            "hiddenOptions": [String: Any](),
            "config": [
                "questionCount": Int(questionCount),
                "questionFormat": questionFormat,
                "selectedLanguage": selectedLanguage,
                "learningStatus": ["Yeni": statusYeni, "Öğreniyor": statusOgreniyor, "Öğrendi": statusOgrendi],
                "questionTypes": actualQuestionTypes,
                "onlyStarred": onlyStarred,
                "shuffle": shufflePool,
                "smartDistractors": smartDistractors
            ],
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        
        Task {
            if let tid = activeTestId, !tid.isEmpty {
                try? await db.collection("users").document(user.uid).collection("practice_tests").document(tid).setData(testData, merge: true)
            } else {
                let docRef = try? await db.collection("users").document(user.uid).collection("practice_tests").addDocument(data: testData)
                activeTestId = docRef?.documentID
            }
            
            // Log to daily_stats for Streak & Daily Progress
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let todayStr = df.string(from: Date())
            let statRef = db.collection("users").document(user.uid).collection("daily_stats").document(todayStr)
            
            var wordStatsMap: [String: [String: Any]] = [:]
            for res in calculatedResults {
                let existing = wordStatsMap[res.wordId] ?? ["correct": 0, "incorrect": 0, "term": res.wordTerm]
                var c = existing["correct"] as? Int ?? 0
                var inc = existing["incorrect"] as? Int ?? 0
                if res.isCorrect { c += 1 }
                else if res.userAnswer != "Boş bırakıldı" { inc += 1 }
                wordStatsMap[res.wordId] = ["correct": c, "incorrect": inc, "term": res.wordTerm]
            }
            
            if let snap = try? await statRef.getDocument(), let data = snap.data() {
                let currentCorrect = (data["correctCount"] as? NSNumber)?.intValue ?? (data["correctCount"] as? Int ?? 0)
                let existingWords = data["words"] as? [String: Any] ?? [:]
                
                var mergedWords = existingWords
                for (wId, wData) in wordStatsMap {
                    if let newDict = wData as? [String: Any] {
                        var exDict = mergedWords[wId] as? [String: Any] ?? ["correct": 0, "incorrect": 0, "term": newDict["term"] ?? ""]
                        let c1 = exDict["correct"] as? Int ?? 0
                        let c2 = newDict["correct"] as? Int ?? 0
                        let i1 = exDict["incorrect"] as? Int ?? 0
                        let i2 = newDict["incorrect"] as? Int ?? 0
                        exDict["correct"] = c1 + c2
                        exDict["incorrect"] = i1 + i2
                        mergedWords[wId] = exDict
                    }
                }
                
                let newTotalCorrect = currentCorrect + correctCount
                try? await statRef.setData([
                    "correctCount": newTotalCorrect,
                    "words": mergedWords,
                    "lastActivity": FieldValue.serverTimestamp()
                ], merge: true)
            } else {
                try? await statRef.setData([
                    "correctCount": correctCount,
                    "words": wordStatsMap,
                    "lastActivity": FieldValue.serverTimestamp()
                ], merge: true)
            }
            
            await MainActor.run {
                fetchTodayStats()
            }
            await loadSavedPracticeTests()
        }
        
        withAnimation {
            viewMode = "results"
        }
    }
    
    private func updateWordStageAndLog(word: LocalWord, isCorrect: Bool) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        // 1. Update word stage & status in Firestore
        let currentStage = word.learningStage
        let newStage = isCorrect ? min(5, currentStage + 1) : max(0, currentStage - 1)
        let newStatus: String
        if newStage == 0 { newStatus = "Yeni" }
        else if newStage == 5 { newStatus = "Öğrendi" }
        else { newStatus = "Öğreniyor" }
        
        Task {
            try? await db.collection("users").document(user.uid).collection("words").document(word.id).updateData([
                "learningStage": newStage,
                "learningStatus": newStatus
            ])
        }
        
        // 2. Log to daily_stats
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())
        let statRef = db.collection("users").document(user.uid).collection("daily_stats").document(todayStr)
        
        Task {
            let docSnap = try? await statRef.getDocument()
            var currentCount = 0
            var wordsDict: [String: Any] = [:]
            
            if let data = docSnap?.data() {
                currentCount = (data["correctCount"] as? NSNumber)?.intValue ?? (data["correctCount"] as? Int ?? 0)
                wordsDict = data["words"] as? [String: Any] ?? [:]
            }
            
            let newCount = isCorrect ? currentCount + 1 : currentCount
            var wStat = wordsDict[word.id] as? [String: Any] ?? ["correct": 0, "incorrect": 0, "term": word.term]
            var wCorrect = wStat["correct"] as? Int ?? 0
            var wIncorrect = wStat["incorrect"] as? Int ?? 0
            
            if isCorrect { wCorrect += 1 }
            else { wIncorrect += 1 }
            
            wStat["correct"] = wCorrect
            wStat["incorrect"] = wIncorrect
            wStat["term"] = word.term
            wordsDict[word.id] = wStat
            
            try? await statRef.setData([
                "correctCount": newCount,
                "words": wordsDict,
                "lastActivity": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }
    
    private func parseQuickTestTemplate(docId: String, data d: [String: Any]) -> QuickTestTemplate {
        let name = d["name"] as? String ?? ""
        let cfg = (d["config"] as? [String: Any]) ?? d
        
        let qCount = (cfg["questionCount"] as? Int) ?? (cfg["questionCount"] as? NSNumber)?.intValue ?? 15
        let qFormat = cfg["questionFormat"] as? String ?? "definition"
        let lang = cfg["selectedLanguage"] as? String ?? (cfg["language"] as? String ?? "all")
        
        // Question Types
        var mcq = cfg["typeMCQ"] as? Bool ?? false
        var tf = cfg["typeTF"] as? Bool ?? false
        var flash = cfg["typeFlashcard"] as? Bool ?? false
        var written = cfg["typeWritten"] as? Bool ?? false
        
        if let qTypes = cfg["questionTypes"] as? [String: Any] {
            if let m = qTypes["mcq"] as? Bool { mcq = m }
            if let t = qTypes["tf"] as? Bool { tf = t }
            if let f = qTypes["flashcard"] as? Bool { flash = f }
            if let w = qTypes["written"] as? Bool { written = w }
        } else if let typeStr = cfg["type"] as? String {
            if typeStr.contains("Çoktan") { mcq = true }
            if typeStr.contains("Yazılı") { written = true }
            if typeStr.contains("Doğru") || typeStr.contains("Yanlış") { tf = true }
            if typeStr.contains("Flashcard") || typeStr.contains("Kart") { flash = true }
            if typeStr.contains("Karışık") { mcq = true; tf = true; flash = true; written = true }
        }
        if !mcq && !tf && !flash && !written { written = true }
        
        // Learning Status
        var sYeni = cfg["statusYeni"] as? Bool ?? false
        var sOgreniyor = cfg["statusOgreniyor"] as? Bool ?? false
        var sOgrendi = cfg["statusOgrendi"] as? Bool ?? false
        
        if let lStatus = cfg["learningStatus"] as? [String: Any] {
            if let y = lStatus["Yeni"] as? Bool { sYeni = y }
            if let o = lStatus["Öğreniyor"] as? Bool { sOgreniyor = o }
            if let d = lStatus["Öğrendi"] as? Bool { sOgrendi = d }
        } else if let statusStr = cfg["status"] as? String {
            if statusStr.contains("Yeni") { sYeni = true }
            if statusStr.contains("Öğreniyor") { sOgreniyor = true }
            if statusStr.contains("Öğrendi") { sOgrendi = true }
        }
        if !sYeni && !sOgreniyor && !sOgrendi { sYeni = true; sOgreniyor = true; sOgrendi = true }
        
        // Star & Options
        let oStarred = cfg["onlyStarred"] as? Bool ?? (cfg["starOnly"] as? Bool ?? ((cfg["starOption"] as? String)?.contains("Sadece Yıldızlı") ?? false))
        let eStarred = cfg["excludeStarred"] as? Bool ?? ((cfg["starOption"] as? String)?.contains("Yıldızsız") ?? false)
        let eSolvedToday = cfg["excludeSolvedToday"] as? Bool ?? false
        let shuffleP = cfg["shuffle"] as? Bool ?? (cfg["shufflePool"] as? Bool ?? true)
        
        // Advanced / Helper Modes
        var fillBlanks = cfg["modeFillInTheBlanks"] as? Bool ?? false
        var smart = cfg["smartDistractors"] as? Bool ?? true
        var missingL = cfg["modeMissingLetters"] as? Bool ?? false
        var singleM = cfg["modeSingleMeaning"] as? Bool ?? false
        var comboS = cfg["modeComboStreak"] as? Bool ?? false
        var progH = cfg["modeProgressiveHint"] as? Bool ?? false
        let maxTypo = (cfg["maxAllowedTypoLetters"] as? Int) ?? (cfg["maxAllowedTypoLetters"] as? NSNumber)?.intValue ?? 2
        
        if let adv = cfg["advancedOptions"] as? [String: Any] {
            if let f = adv["fillInTheBlanks"] as? Bool { fillBlanks = f }
            if let s = adv["smartDistractors"] as? Bool { smart = s }
            if let m = adv["missingLetters"] as? Bool { missingL = m }
            if let sm = adv["singleMeaning"] as? Bool { singleM = sm }
            if let c = adv["comboStreak"] as? Bool { comboS = c }
            if let p = adv["progressiveHint"] as? Bool { progH = p }
        }
        
        let createdAtVal = parseFirestoreDate(d["createdAt"])
        
        return QuickTestTemplate(
            id: docId,
            name: name.isEmpty ? "Hızlı Test" : name,
            questionCount: qCount,
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
            maxAllowedTypoLetters: maxTypo,
            createdAt: createdAtVal
        )
    }
    
    // MARK: - Firestore Load & Save Quick Tests
    private func loadQuickTests() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        quickTestsListener?.remove()
        quickTestsListener = db.collection("users").document(user.uid).collection("quick_tests").addSnapshotListener { snap, _ in
            guard let documents = snap?.documents else { return }
            var templates: [QuickTestTemplate] = []
            for doc in documents {
                templates.append(parseQuickTestTemplate(docId: doc.documentID, data: doc.data()))
            }
            templates.sort(by: { $0.createdAt > $1.createdAt })
            
            DispatchQueue.main.async {
                self.quickTests = templates
            }
        }
    }
    
    private func saveCurrentQuickTest() {
        let name = newQuickTestName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        let tType = typeWritten && !typeMCQ && !typeTF && !typeFlashcard ? "Yazılı" : (typeMCQ && !typeTF && !typeFlashcard && !typeWritten ? "Çoktan Seçmeli" : "Karışık")
        let dir = questionFormat == "definition" ? "Türkçe -> Yabancı Dil" : (questionFormat == "term" ? "Yabancı Dil -> Türkçe" : "Karışık")
        let starOpt = onlyStarred ? "Sadece Yıldızlı" : (excludeStarred ? "Sadece Yıldızsız" : "Yıldızlı + Yıldızsız")
        
        let config: [String: Any] = [
            "questionCount": Int(questionCount),
            "type": tType,
            "questionFormat": questionFormat,
            "selectedLanguage": selectedLanguage,
            "language": selectedLanguage,
            "direction": dir,
            "typeMCQ": typeMCQ,
            "typeTF": typeTF,
            "typeFlashcard": typeFlashcard,
            "typeWritten": typeWritten,
            "questionTypes": ["mcq": typeMCQ, "tf": typeTF, "flashcard": typeFlashcard, "written": typeWritten],
            "statusYeni": statusYeni,
            "statusOgreniyor": statusOgreniyor,
            "statusOgrendi": statusOgrendi,
            "learningStatus": ["Yeni": statusYeni, "Öğreniyor": statusOgreniyor, "Öğrendi": statusOgrendi],
            "starOption": starOpt,
            "onlyStarred": onlyStarred,
            "excludeStarred": excludeStarred,
            "starOnly": onlyStarred,
            "excludeSolvedToday": excludeSolvedToday,
            "shuffle": shufflePool,
            "shufflePool": shufflePool,
            "advancedOptions": [
                "fillInTheBlanks": modeFillInTheBlanks,
                "smartDistractors": smartDistractors,
                "missingLetters": modeMissingLetters,
                "singleMeaning": modeSingleMeaning,
                "comboStreak": modeComboStreak,
                "progressiveHint": modeProgressiveHint
            ],
            "modeFillInTheBlanks": modeFillInTheBlanks,
            "smartDistractors": smartDistractors,
            "modeMissingLetters": modeMissingLetters,
            "modeSingleMeaning": modeSingleMeaning,
            "modeComboStreak": modeComboStreak,
            "modeProgressiveHint": modeProgressiveHint,
            "maxAllowedTypoLetters": maxAllowedTypoLetters
        ]
        
        let data: [String: Any] = [
            "userId": user.uid,
            "name": name,
            "config": config,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        
        Task {
            do {
                _ = try await db.collection("users").document(user.uid).collection("quick_tests").addDocument(data: data)
                await MainActor.run {
                    newQuickTestName = ""
                }
            } catch {
                print("Error saving quick test: \(error)")
            }
        }
    }
    
    private func loadSavedPracticeTests() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        Task {
            do {
                let snap = try await db.collection("users").document(user.uid).collection("practice_tests").getDocumentsSmart()
                var list: [[String: Any]] = []
                for doc in snap.documents {
                    var d = doc.data()
                    d["id"] = doc.documentID
                    list.append(d)
                }
                
                list.sort { a, b in
                    let dateA = (a["updatedAt"] as? Timestamp)?.dateValue() ?? (a["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast
                    let dateB = (b["updatedAt"] as? Timestamp)?.dateValue() ?? (b["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast
                    return dateA > dateB
                }
                
                self.savedPracticeTests = list
            } catch {
                print("Error loading practice tests: \(error)")
            }
        }
    }
    
    private func openSavedPracticeTest(_ test: [String: Any]) {
        let testId = test["id"] as? String ?? ""
        activeTestId = testId
        
        var parsedQuestions: [PracticeQuestionItem] = []
        if let qRaw = test["questions"] as? [[String: Any]] {
            for item in qRaw {
                let wordId = item["wordId"] as? String ?? ""
                let prompt = item["prompt"] as? String ?? ""
                let type = item["type"] as? String ?? "mcq"
                let ex = item["exampleSentence"] as? String
                
                var targetWord = allWords.first(where: { $0.id == wordId })
                if targetWord == nil {
                    if let twDict = item["targetWord"] as? [String: Any] {
                        targetWord = LocalWord(
                            id: wordId,
                            term: twDict["term"] as? String ?? prompt,
                            shortMeanings: twDict["shortMeanings"] as? String ?? "",
                            pronunciation: "",
                            level: "A1",
                            isStarred: false,
                            learningStage: 1,
                            createdAt: Date(),
                            language: twDict["language"] as? String ?? "english"
                        )
                    }
                }
                
                // Extract options and T/F statement state
                var options: [String] = []
                var isTrueStatement: Bool = true
                
                if let optsArray = item["options"] as? [[String: Any]] {
                    options = optsArray.compactMap { $0["text"] as? String }
                    if let dogruOpt = optsArray.first(where: { ($0["text"] as? String) == "Doğru" }) {
                        isTrueStatement = (dogruOpt["isCorrect"] as? Bool) ?? true
                    }
                } else if let optsStrings = item["options"] as? [String] {
                    options = optsStrings
                }
                
                if let b = item["isTrueStatement"] as? Bool {
                    isTrueStatement = b
                }
                
                // Robust extraction of correct answer across Web and Mobile formats
                var correct = item["correctAnswer"] as? String ?? item["answer"] as? String ?? ""
                
                if correct.isEmpty, let optsArray = item["options"] as? [[String: Any]] {
                    if let correctOpt = optsArray.first(where: { ($0["isCorrect"] as? Bool) == true }) {
                        correct = correctOpt["text"] as? String ?? ""
                    }
                }
                
                if correct.isEmpty, let w = targetWord {
                    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanTerm = w.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if cleanPrompt == cleanTerm {
                        correct = w.shortMeanings
                    } else {
                        correct = w.term
                    }
                }
                
                if options.isEmpty && !correct.isEmpty {
                    options = [correct]
                }
                
                let statementText = item["displayedAnswerText"] as? String ?? item["statement"] as? String ?? correct
                let trTrans = item["turkishTranslation"] as? String ?? item["tr"] as? String ?? item["trText"] as? String
                
                let wordForQuestion = targetWord ?? LocalWord(
                    id: wordId,
                    term: prompt,
                    shortMeanings: correct,
                    pronunciation: "",
                    level: "A1",
                    isStarred: false,
                    learningStage: 1,
                    createdAt: Date(),
                    language: "english"
                )
                
                parsedQuestions.append(PracticeQuestionItem(
                    id: UUID().uuidString,
                    wordId: wordId,
                    targetWord: wordForQuestion,
                    questionType: type,
                    prompt: prompt,
                    correctAnswer: correct,
                    options: options,
                    isTrueStatement: isTrueStatement,
                    statement: statementText,
                    exampleSentence: ex,
                    turkishTranslation: trTrans
                ))
            }
        }
        
        var parsedResults: [QuestionAnswerResult] = []
        let ansDict = test["answers"] as? [String: Any]
        let ansArray = test["answers"] as? [[String: Any]]
        
        for idx in 0..<parsedQuestions.count {
            let q = parsedQuestions[idx]
            var selDict: [String: Any]? = nil
            
            if let dict = ansDict, let itemDict = dict["\(idx)"] as? [String: Any] {
                selDict = itemDict["selected"] as? [String: Any] ?? itemDict
            } else if let arr = ansArray, idx < arr.count {
                selDict = arr[idx]["selected"] as? [String: Any] ?? arr[idx]
            }
            
            if let sel = selDict {
                let userText = sel["text"] as? String ?? sel["userAnswer"] as? String ?? ""
                var isCorrect = sel["isCorrect"] as? Bool
                var isTypo = sel["isTypo"] as? Bool ?? false
                var isWordFamily = sel["isWordFamily"] as? Bool ?? false
                
                if isCorrect == nil {
                    if q.questionType == "written" {
                        let t = userText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let c = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        
                        let familyTerms = (q.targetWord.wordFamily ?? []).map { parseFamilyItem($0).term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        let isFamilyMatch = !familyTerms.isEmpty && familyTerms.contains(t)
                        
                        if t == c {
                            isCorrect = true
                            isTypo = false
                            isWordFamily = false
                        } else if isFamilyMatch {
                            isCorrect = true
                            isTypo = false
                            isWordFamily = true
                        } else {
                            let dist = levenshteinDistance(t, c)
                            if !t.isEmpty && maxAllowedTypoLetters > 0 && dist <= maxAllowedTypoLetters {
                                isCorrect = true
                                isTypo = true
                                isWordFamily = false
                            } else {
                                isCorrect = false
                                isTypo = false
                                isWordFamily = false
                            }
                        }
                    } else if q.questionType == "tf" {
                        let expected = (q.isTrueStatement ?? true) ? "Doğru" : "Yanlış"
                        isCorrect = userText == expected
                    } else {
                        isCorrect = userText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                } else if q.questionType == "written" && isCorrect == true && !isWordFamily {
                    let t = userText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let c = q.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let familyTerms = (q.targetWord.wordFamily ?? []).map { parseFamilyItem($0).term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    let isFamilyMatch = !familyTerms.isEmpty && familyTerms.contains(t)
                    
                    if isFamilyMatch {
                        isWordFamily = true
                        isTypo = false
                    } else if t != c {
                        isTypo = true
                    }
                }
                
                let finalAnsText = userText.isEmpty ? "Boş bırakıldı" : userText
                
                parsedResults.append(QuestionAnswerResult(
                    wordId: q.wordId,
                    wordTerm: q.targetWord.term,
                    questionPrompt: q.prompt,
                    correctAnswer: q.correctAnswer,
                    userAnswer: finalAnsText,
                    isCorrect: isCorrect ?? false,
                    isTypo: isTypo,
                    isWordFamily: isWordFamily
                ))
            }
        }
        
        activeQuestions = parsedQuestions
        testResultsList = parsedResults
        
        let isDone = (test["completed"] as? Bool ?? false) || (test["status"] as? String == "completed")
        if isDone {
            withAnimation { viewMode = "results" }
        } else {
            currentQuestionIndex = parsedResults.count
            score = parsedResults.filter { $0.isCorrect }.count * 10
            withAnimation { viewMode = "active" }
        }
    }
    
    private func deleteSinglePracticeTest(id: String) {
        guard let user = Auth.auth().currentUser, !id.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            savedPracticeTests.removeAll(where: { ($0["id"] as? String) == id })
        }
        let db = Firestore.firestore()
        Task {
            try? await db.collection("users").document(user.uid).collection("practice_tests").document(id).delete()
        }
    }
    
    private func deleteAllPracticeTests() {
        guard let user = Auth.auth().currentUser else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            savedPracticeTests.removeAll()
        }
        let db = Firestore.firestore()
        Task {
            let snap = try? await db.collection("users").document(user.uid).collection("practice_tests").getDocuments()
            if let docs = snap?.documents {
                for doc in docs {
                    try? await doc.reference.delete()
                }
            }
        }
    }
    
    // MARK: - UI Subview Utilities & Components
    @ViewBuilder
    private func formatChip(title: String, tag: String) -> some View {
        let isSel = questionFormat == tag
        Button(action: { questionFormat = tag }) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(isSel ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSel ? Color.blue : Color.black.opacity(0.04))
                .cornerRadius(12)
        }
    }
    
    @ViewBuilder
    private func langChip(title: String, tag: String) -> some View {
        let isSel = selectedLanguage == tag
        Button(action: { selectedLanguage = tag }) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(isSel ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSel ? Color.blue : Color.black.opacity(0.04))
                .cornerRadius(12)
        }
    }
    
    @ViewBuilder
    private func toggleChip(title: String, isSelected: Binding<Bool>, color: Color) -> some View {
        Button(action: { isSelected.wrappedValue.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: isSelected.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundColor(isSelected.wrappedValue ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected.wrappedValue ? color : Color.black.opacity(0.04))
            .cornerRadius(12)
        }
    }
    
    @ViewBuilder
    private func toggleRow(title: String, isSelected: Binding<Bool>, icon: String, color: Color) -> some View {
        Toggle(isOn: isSelected) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
        }
        .tint(.blue)
    }
    
    @ViewBuilder
    private func savedTestCard(test: [String: Any], index: Int) -> some View {
        let id = test["id"] as? String ?? ""
        let name = test["name"] as? String ?? "Pratik Test"
        let isDone = (test["completed"] as? Bool ?? false) || (test["status"] as? String == "completed")
        
        let qArray = test["questions"] as? [Any]
        let totalQuestionsConfig = (test["questionCount"] as? Int) ?? ((test["config"] as? [String: Any])?["questionCount"] as? Int) ?? 15
        let total = (qArray?.count ?? 0) > 0 ? qArray!.count : totalQuestionsConfig
        
        let answersDict = test["answers"] as? [String: Any]
        let solved = test["solvedCount"] as? Int ?? answersDict?.count ?? (test["correctCount"] as? Int ?? (isDone ? total : 0))
        
        let dateObj = parseFirestoreDate(test["updatedAt"] ?? test["createdAt"])
        let formattedDateStr = dateObj != Date.distantPast ? dateObj.formatted(date: .numeric, time: .shortened) : ""
        
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isDone ? "Tamamlandı" : "Devam Ediyor")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(isDone ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isDone ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                    .cornerRadius(8)
                
                Spacer()
                
                Button(action: {
                    deletingSingleTestId = id
                    showDeleteSingleTestAlert = true
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.8))
                }
            }
            
            Text(name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            HStack {
                Text("\(solved) / \(total) Soru")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !formattedDateStr.isEmpty {
                    Text(formattedDateStr)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            
            Spacer()
            
            Button(action: {
                openSavedPracticeTest(test)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isDone ? "eye.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text(isDone ? "İncele" : "Devam Et")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(isDone ? Color.blue : Color.green)
                .cornerRadius(10)
            }
        }
        .padding(12)
        .frame(width: 185, height: 145)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
    }
    
    @ViewBuilder
    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        let b = Array(s2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        var dist = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i-1] == b[j-1] {
                    dist[i][j] = dist[i-1][j-1]
                } else {
                    dist[i][j] = min(dist[i-1][j] + 1, dist[i][j-1] + 1, dist[i-1][j-1] + 1)
                }
            }
        }
        return dist[a.count][b.count]
    }
}

// MARK: - QuickTestTemplate (Moved to DictionaryModels.swift)

struct QuickTestCardView: View {
    let test: QuickTestTemplate
    var isSelected: Bool = false
    var isModified: Bool = false
    var onSave: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Text(test.name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? .blue : .black.opacity(0.85))
                    .lineLimit(2)
                
                Spacer(minLength: 4)
                
                HStack(spacing: 6) {
                    if isSelected && isModified {
                        Button(action: { onSave?() }) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Button(action: { onEdit?() }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: { onDelete?() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
            }
            .frame(height: 34, alignment: .topLeading)
            .padding(.top, 2)
            
            Divider()
                .padding(.vertical, 1)
            
            VStack(alignment: .leading, spacing: 6) {
                detailRow(icon: "number", text: "\(test.questionCount) Soru", color: .blue)
                detailRow(icon: "pencil.and.outline", text: test.testType, color: .cyan)
                detailRow(icon: "globe", text: test.lang, color: .green)
                detailRow(icon: "arrow.left.and.right", text: test.direction, color: .red)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(getStatusColor(test.status))
                        .frame(width: 8, height: 8)
                    
                    Text(test.status)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                detailRow(icon: "star.fill", text: test.starOption, color: .orange)
                detailRow(icon: "puzzlepiece.fill", text: test.features, color: .purple)
            }
        }
        .padding(14)
        .frame(width: 180, height: 220)
        .background(isSelected ? Color.blue.opacity(0.05) : Color.white)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? Color.blue : Color.black.opacity(0.04), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? Color.blue.opacity(0.15) : Color.black.opacity(0.015), radius: isSelected ? 6 : 5, x: 0, y: 3)
    }
    
    @ViewBuilder
    private func detailRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color.opacity(0.8))
                .frame(width: 14, alignment: .center)
            
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
    
    private func getStatusColor(_ statusStr: String) -> Color {
        let lower = statusStr.lowercased()
        if lower.contains("öğrendi") {
            return .green
        } else if lower.contains("öğreniyor") {
            return .orange
        } else {
            return .blue
        }
    }
}

struct StickyContentView: View {
    let stickyNotes: [StickyNoteModel]
    let allWords: [LocalWord]
    @Binding var searchText: String
    @Binding var showSettingsSheet: Bool
    let onSelectWord: (LocalWord) -> Void
    
    @AppStorage("stickyNote_displayMode") private var displayMode: String = "full"
    @State private var visibleLimit: Int = 10
    @State private var selectedNoteForDetail: StickyNoteModel? = nil
    
    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        return df
    }
    
    var filteredNotes: [StickyNoteModel] {
        let sorted = stickyNotes.sorted(by: { $0.createdAt > $1.createdAt })
        if searchText.isEmpty {
            return sorted
        }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.title.lowercased().contains(q) || $0.wordTerm.lowercased().contains(q) || stripHTML($0.text).lowercased().contains(q)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: 50, height: 50)
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sticky Notlarım")
                                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                Text("Kelimelere bağladığın çalışma notların, örnek cümlelerin ve ipuçların.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                        
                        HStack(spacing: 8) {
                            Text("\(stickyNotes.count) KAYITLI ÇALIŞMA NOTU")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(10)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.92, green: 0.45, blue: 0.1), Color(red: 0.98, green: 0.62, blue: 0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 140, height: 140)
                                .blur(radius: 25)
                                .offset(x: 120, y: -30)
                        }
                    )
                    .cornerRadius(24)
                    .shadow(color: Color.orange.opacity(0.3), radius: 12, x: 0, y: 5)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    
                    HStack {
                        Text("STICKY NOTLAR (\(filteredNotes.count))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    
                    if filteredNotes.isEmpty {
                        VStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.08))
                                    .frame(width: 72, height: 72)
                                Image(systemName: "note.text.badge.plus")
                                    .font(.system(size: 34))
                                    .foregroundColor(.orange)
                            }
                            Text("Henüz sticky not eklemediniz.")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                            Text("Kelime detay sayfasından not alarak çalışma kartlarınızı oluşturabilirsiniz.")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(filteredNotes.prefix(visibleLimit)) { note in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .center, spacing: 10) {
                                        ZStack {
                                            Circle()
                                                .fill(LinearGradient(colors: [Color.orange, Color.yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(width: 32, height: 32)
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                        
                                        let cleanTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                        Text(cleanTitle.isEmpty ? (note.wordTerm.isEmpty ? "Sticky Not" : note.wordTerm) : cleanTitle)
                                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                                            .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.18))
                                            .lineLimit(1)
                                        
                                        Spacer()
                                        
                                        let cleanWordTerm = note.wordTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !cleanWordTerm.isEmpty && cleanWordTerm.lowercased() != "manuel not" {
                                            Button(action: {
                                                if let matched = findWord(term: cleanWordTerm, wordId: note.wordId) {
                                                    onSelectWord(matched)
                                                }
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "link")
                                                        .font(.system(size: 10, weight: .bold))
                                                    Text(cleanWordTerm)
                                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                                }
                                                .foregroundColor(.blue)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.08))
                                                .cornerRadius(8)
                                            }
                                        }
                                    }
                                    
                                    if displayMode == "full" {
                                        StickyHTMLTextView(htmlContent: note.text, fontSize: 13.5)
                                    } else if displayMode == "titleAndOneLine" {
                                        StickyHTMLTextView(htmlContent: note.text, fontSize: 13, lineLimit: 1)
                                    }
                                    
                                    HStack(spacing: 4) {
                                        Image(systemName: "calendar.badge.clock")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(dateFormatter.string(from: note.createdAt))
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 2)
                                }
                                .padding(18)
                                .background(Color.white)
                                .cornerRadius(24)
                                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedNoteForDetail = note
                                }
                                .onAppear {
                                    if note.id == filteredNotes.prefix(visibleLimit).last?.id && visibleLimit < filteredNotes.count {
                                        withAnimation {
                                            visibleLimit = min(visibleLimit + 10, filteredNotes.count)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .sheet(item: $selectedNoteForDetail) { note in
            StickyNoteDetailSheetView(
                note: note,
                allWords: allWords,
                onSelectWord: onSelectWord
            )
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Görünüm Ayarları")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    VStack(spacing: 12) {
                        settingRow(title: "Tüm İçerik", tag: "full", icon: "doc.text.fill")
                        settingRow(title: "Başlık + Tek Satır", tag: "titleAndOneLine", icon: "text.alignleft")
                        settingRow(title: "Sadece Başlık", tag: "titleOnly", icon: "list.dash")
                    }
                    
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Not Görünümü")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Tamam") {
                            showSettingsSheet = false
                        }
                        .font(.system(size: 15, weight: .bold))
                    }
                }
            }
            .presentationDetents([.height(280)])
        }
    }
    
    @ViewBuilder
    private func settingRow(title: String, tag: String, icon: String) -> some View {
        Button(action: {
            displayMode = tag
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(displayMode == tag ? .blue : .secondary)
                    .frame(width: 24)
                
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if displayMode == tag {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                }
            }
            .padding(12)
            .background(displayMode == tag ? Color.blue.opacity(0.06) : Color.black.opacity(0.03))
            .cornerRadius(12)
        }
    }
    
    private func findWord(term: String, wordId: String) -> LocalWord? {
        if let w = allWords.first(where: { $0.id == wordId }) {
            return w
        }
        return allWords.first(where: { $0.term.lowercased() == term.lowercased() })
    }
    
    private func stripHTML(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        return clean.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - StickyNoteDetailSheetView Modal

struct StickyNoteDetailSheetView: View {
    let note: StickyNoteModel
    let allWords: [LocalWord]
    let onSelectWord: (LocalWord) -> Void
    @Environment(\.dismiss) private var dismiss
    
    private var formattedDate: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        return df.string(from: note.createdAt)
    }
    
    var matchedWord: LocalWord? {
        let clean = note.wordTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.isEmpty || clean == "manuel not" { return nil }
        if !note.wordId.isEmpty {
            if let w = allWords.first(where: { $0.id == note.wordId }) { return w }
        }
        return allWords.first(where: { $0.term.lowercased() == clean })
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "note.text")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.orange)
                            
                            let cleanTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(cleanTitle.isEmpty ? (note.wordTerm.isEmpty ? "Sticky Not" : note.wordTerm) : cleanTitle)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        
                        // Date badge
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("Eklenme Tarihi: \(formattedDate)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                        
                        // Linked word badge (if any)
                        if let word = matchedWord {
                            Divider().padding(.vertical, 4)
                            
                            Button(action: {
                                dismiss()
                                onSelectWord(word)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("İlişkili Kelime: \(word.term)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(.blue)
                                .padding(10)
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(10)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
                    
                    // Content section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOT İÇERİĞİ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                        
                        StickyHTMLTextView(htmlContent: note.text, fontSize: 15)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(color: Color.black.opacity(0.02), radius: 5, x: 0, y: 2)
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Not Detayı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }
            }
        }
    }
    
    private func stripHTML(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        return clean.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTML Render View for Sticky Notes (Web-matched rich text formatting)

struct StickyHTMLTextView: View {
    let htmlContent: String
    var fontSize: CGFloat = 14
    var lineLimit: Int? = nil
    
    var body: some View {
        Text(parseHTMLToAttributedString(htmlContent))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    private func parseHTMLToAttributedString(_ html: String) -> AttributedString {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var emptyAttr = AttributedString("Not içeriği yok")
            emptyAttr.font = .system(size: fontSize, design: .rounded)
            emptyAttr.foregroundColor = Color(red: 0.5, green: 0.5, blue: 0.55)
            return emptyAttr
        }
        
        var processed = trimmed
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "<p[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<div[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "<li[^>]*>", with: "• ", options: .regularExpression)
            .replacingOccurrences(of: "(?<!\\*)\\*\\*(.*?)\\*\\*(?!\\*)", with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: "(?<!\\*)\\*(.*?)\\*(?!\\*)", with: "<i>$1</i>", options: .regularExpression)
            .replacingOccurrences(of: "~~(.*?)~~", with: "<s>$1</s>", options: .regularExpression)
            .replacingOccurrences(of: "<strong>", with: "<b>", options: .caseInsensitive)
            .replacingOccurrences(of: "</strong>", with: "</b>", options: .caseInsensitive)
            .replacingOccurrences(of: "<em>", with: "<i>", options: .caseInsensitive)
            .replacingOccurrences(of: "</em>", with: "</i>", options: .caseInsensitive)
            .replacingOccurrences(of: "<strike>", with: "<s>", options: .caseInsensitive)
            .replacingOccurrences(of: "</strike>", with: "</s>", options: .caseInsensitive)
            .replacingOccurrences(of: "<del>", with: "<s>", options: .caseInsensitive)
            .replacingOccurrences(of: "</del>", with: "</s>", options: .caseInsensitive)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        
        let result = NSMutableAttributedString()
        let baseFont = UIFont.systemFont(ofSize: fontSize)
        let boldFont = UIFont.boldSystemFont(ofSize: fontSize)
        let italicFont = UIFont.italicSystemFont(ofSize: fontSize)
        let boldItalicFont: UIFont = {
            if let desc = boldFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: desc, size: fontSize)
            }
            return boldFont
        }()
        
        var isBold = false
        var isItalic = false
        var isUnderline = false
        var isStrikethrough = false
        
        let regex = try? NSRegularExpression(pattern: "(</?[bius]>)")
        let nsString = processed as NSString
        var lastIndex = 0
        let matches = regex?.matches(in: processed, range: NSRange(location: 0, length: nsString.length)) ?? []
        
        for match in matches {
            let range = match.range
            if range.location > lastIndex {
                let sub = nsString.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
                let cleanSub = sub.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !cleanSub.isEmpty {
                    let font = (isBold && isItalic) ? boldItalicFont : (isBold ? boldFont : (isItalic ? italicFont : baseFont))
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1.0)
                    ]
                    if isUnderline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if isStrikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    result.append(NSAttributedString(string: cleanSub, attributes: attrs))
                }
            }
            
            let tag = nsString.substring(with: range).lowercased()
            switch tag {
            case "<b>": isBold = true
            case "</b>": isBold = false
            case "<i>": isItalic = true
            case "</i>": isItalic = false
            case "<u>": isUnderline = true
            case "</u>": isUnderline = false
            case "<s>": isStrikethrough = true
            case "</s>": isStrikethrough = false
            default: break
            }
            lastIndex = range.location + range.length
        }
        
        if lastIndex < nsString.length {
            let sub = nsString.substring(from: lastIndex)
            let cleanSub = sub.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !cleanSub.isEmpty {
                let font = (isBold && isItalic) ? boldItalicFont : (isBold ? boldFont : (isItalic ? italicFont : baseFont))
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1.0)
                ]
                if isUnderline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if isStrikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: cleanSub, attributes: attrs))
            }
        }
        
        if let swiftAttr = try? AttributedString(result) {
            return swiftAttr
        }
        return AttributedString(result.string)
    }
}


extension Color {
    static let amber = Color(hex: "f59e0b")
}

// MARK: - Subpage Native Navigation Wrappers

struct CustomListsSubView: View {
    let customLists: [CustomListModel]
    let onSelectList: (String) -> Void
    
    var body: some View {
        CustomListsContentView(
            customLists: customLists,
            onSelectList: onSelectList
        )
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Özel Listelerim")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PratikSubView: View {
    @Binding var allWords: [LocalWord]
    let customLists: [CustomListModel]
    let stickyNotes: [StickyNoteModel]
    @Binding var viewMode: String
    let onSelectWord: (LocalWord) -> Void
    
    @State private var showExitTestAlert: Bool = false
    
    var body: some View {
        PratikContentView(
            allWords: $allWords,
            customLists: customLists,
            stickyNotes: stickyNotes,
            viewMode: $viewMode,
            onSelectWord: onSelectWord
        )
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle(viewMode == "options" ? "Pratik Yap" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(viewMode != "options")
        .background(
            SwipeBackEnabler(disabled: viewMode != "options")
        )
        .alert("Testi Sonlandır", isPresented: $showExitTestAlert) {
            Button("Vazgeç / Devam Et", role: .cancel) { }
            Button("Evet, Testi Bitir", role: .destructive) {
                withAnimation {
                    viewMode = "options"
                }
            }
        } message: {
            Text("Devam eden testinizi sonlandırmak istediğinize emin misiniz? İlerlemeniz kaydedilecektir.")
        }
    }
}

struct SwipeBackEnabler: UIViewControllerRepresentable {
    let disabled: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        return UIViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = !disabled
        }
    }
}

struct StickySubView: View {
    let stickyNotes: [StickyNoteModel]
    let allWords: [LocalWord]
    @Binding var searchText: String
    @Binding var showSettingsSheet: Bool
    let onSelectWord: (LocalWord) -> Void
    
    @State private var showStickySearchField: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showStickySearchField {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Sticky Notlarda Ara...", text: $searchText)
                        .font(.system(size: 14, design: .rounded))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            StickyContentView(
                stickyNotes: stickyNotes,
                allWords: allWords,
                searchText: $searchText,
                showSettingsSheet: $showSettingsSheet,
                onSelectWord: onSelectWord
            )
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.98).ignoresSafeArea())
        .navigationTitle("Sticky Notlarım")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    withAnimation { showStickySearchField.toggle() }
                }) {
                    Image(systemName: "magnifyingglass")
                }
                Button(action: {
                    showSettingsSheet = true
                }) {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }
}
