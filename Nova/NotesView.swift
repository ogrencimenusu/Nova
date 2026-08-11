import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import WebKit

// MARK: - String HTML Helper

extension String {
    var strippedHTML: String {
        return self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Rich HTML Render View (Clickable Links) — legacy, used in list rows

struct HTMLView: UIViewRepresentable {
    let htmlContent: String
    @Binding var dynamicHeight: CGFloat
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = [.link, .phoneNumber]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        let styledHTML = styledHTMLString(htmlContent)
        if let data = styledHTML.data(using: .utf8),
           let attr = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil) {
            uiView.attributedText = attr
        } else {
            uiView.text = htmlContent.strippedHTML
        }
        DispatchQueue.main.async {
            let w = uiView.bounds.width > 0 ? uiView.bounds.width : (UIScreen.main.bounds.width - 40)
            let fit = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            if fit.height > 0 && abs(self.dynamicHeight - fit.height) > 2 {
                self.dynamicHeight = fit.height
            }
        }
    }
}

// MARK: - Self-Sizing HTML Text View (used in detail sheet, no @State height needed)

struct NoteHTMLTextView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> AutoSizingTextView {
        let tv = AutoSizingTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link, .phoneNumber]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: AutoSizingTextView, context: Context) {
        let html = styledHTMLString(htmlContent)
        DispatchQueue.main.async {
            if let data = html.data(using: .utf8),
               let attr = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) {
                uiView.attributedText = attr
            } else {
                uiView.text = htmlContent.strippedHTML
            }
            uiView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AutoSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 72
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fit.height, 20))
    }
}

final class AutoSizingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let w = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 72
        let fit = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(fit.height, 20))
    }
}

// MARK: - Shared HTML Styling Helper

private func styledHTMLString(_ content: String) -> String {
    """
    <!DOCTYPE html>
    <html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
    body {
        font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        font-size: 15px;
        color: #1c1c1e;
        line-height: 1.6;
        margin: 0; padding: 0;
        word-wrap: break-word;
    }
    a { color: #007aff; text-decoration: underline; font-weight: 500; }
    p { margin-top: 0; margin-bottom: 8px; }
    ul, ol { padding-left: 20px; margin-top: 4px; margin-bottom: 8px; }
    img { max-width: 100%; height: auto; }
    </style>
    </head><body>\(content)</body></html>
    """
}


// MARK: - Note Model

struct NoteItem: Codable, Identifiable {
    @DocumentID var id: String?
    var title: String?
    var text: String?
    var content: String?
    var date: String? // "YYYY-MM-DD"
    var time: String?
    var color: String?
    var deleted: Bool?
    var createdAt: Date?
    var tags: [String]?
    var itemType: String?
    var isRecurring: Bool?
    var recurringGroupId: String?
    var imageUrl: String?

    var displayContent: String? {
        if let t = text, !t.strippedHTML.isEmpty { return t }
        if let c = content, !c.strippedHTML.isEmpty { return c }
        return nil
    }

    var parsedDate: Date? {
        guard let dateString = date, !dateString.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }

    var isPastNote: Bool {
        guard let pDate = parsedDate else { return false }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfNoteDate = Calendar.current.startOfDay(for: pDate)
        return startOfNoteDate < startOfToday
    }

    var colorHex: String {
        let col = (color ?? "").lowercased()
        if col.hasPrefix("#") { return col }
        switch col {
        case "red": return "#FF3B30"
        case "green": return "#34C759"
        case "yellow": return "#FFCC00"
        case "purple": return "#AF52DE"
        case "orange": return "#FF9500"
        default: return "#007AFF"
        }
    }
}

// MARK: - MonthDay Helper Struct

struct MonthDay: Identifiable {
    var id: String { date.description }
    let date: Date
    let isCurrentMonth: Bool
}

// MARK: - Main Notes View (Apple Calendar Style + Search)

struct NotesView: View {
    @State var initialSelectedNoteId: String? = nil
    @Environment(\.presentationMode) var presentationMode
    
    @State private var currentMonthDate: Date = Date()
    @State private var selectedDate: Date = Date()
    @State private var notes: [NoteItem] = []
    @State private var holidays: [HolidayItem] = []
    @State private var isLoading: Bool = true
    @State private var selectedNoteForDetail: NoteItem? = nil
    @State private var listenerRegistration: ListenerRegistration? = nil
    @State private var isAddNotePresented: Bool = false
    
    @State private var noteTags: [NoteTagItem] = []
    @State private var hiddenTags: [String] = []
    @State private var isShowingTagsView: Bool = false
    @State private var selectedTag: String? = nil
    @State private var isTagSettingsPresented: Bool = false
    @State private var tagNotesLimit: Int = 5
    @State private var tagNotesPage: Int = 1

    // Apple Calendar style mode selector (dots / stack) persisted via AppStorage
    @AppStorage("calendarViewMode") private var calendarViewMode: String = "dots"

    // Search State
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""

    private let calendar = Calendar.current
    private let weekDays = ["PZT", "SAL", "ÇAR", "PER", "CUM", "CMT", "PAZ"]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom Navigation Bar (Title on left)
                customNavBar
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background(Color(UIColor.systemBackground))

                // Header Controls (with Search Toggle)
                if !isShowingTagsView {
                    headerView
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemBackground))

                    Divider()
                }

                // Search Bar Input (when search active)
                if isSearching {
                    searchBarSection
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        if isSearching {
                            // Search Results View
                            searchResultsSection
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        } else if isShowingTagsView {
                            tagsViewSubpage
                        } else {
                            // Calendar Days Grid
                            calendarGridSection
                                .padding(.horizontal, 4) // Expand calendar closer to edges
                                .padding(.top, 12)
                            
                            Divider()
                                .padding(.horizontal, 16)

                            // Selected Date Notes Section
                            selectedDateNotesSection
                                .padding(.horizontal, 16)
                                .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                fetchNotes()
                fetchHolidays()
                fetchNoteTags()
                fetchNotesSettings()
            }
            .onDisappear {
                listenerRegistration?.remove()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenNoteDetailInternal"))) { notification in
                guard let noteId = notification.object as? String, !noteId.isEmpty else { return }
                
                // If notes are already fetched, display the detail immediately
                if let matched = self.notes.first(where: { $0.id == noteId }) {
                    self.initialSelectedNoteId = nil
                    UserDefaults.standard.removeObject(forKey: "pendingDeepLinkNoteId")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.selectedNoteForDetail = matched
                    }
                } else {
                    // Otherwise queue it for when fetchNotes completes
                    self.initialSelectedNoteId = noteId
                }
            }
            .sheet(item: $selectedNoteForDetail, onDismiss: {
                self.initialSelectedNoteId = nil
                self.selectedNoteForDetail = nil
                UserDefaults.standard.removeObject(forKey: "pendingDeepLinkNoteId")
            }) { _ in
                NoteDetailSheetView(note: $selectedNoteForDetail, allNotes: notes)
            }
            .sheet(isPresented: $isAddNotePresented) {
                let sortedActiveTags = noteTags.filter { !hiddenTags.contains($0.name) }.sorted { (tag1, tag2) -> Bool in
                    let date1 = getTagLatestDate(tagName: tag1.name)
                    let date2 = getTagLatestDate(tagName: tag2.name)
                    return date1 > date2
                }
                let currentActiveTag = selectedTag ?? sortedActiveTags.first?.name
                let initTags: [String] = (isShowingTagsView && currentActiveTag != nil) ? [currentActiveTag!] : []
                AddEditNoteSheetView(noteToEdit: nil, initialDate: selectedDate, allNotes: notes, initialTags: initTags)
            }
            .sheet(isPresented: $isTagSettingsPresented) {
                TagSettingsSheetView(tags: $noteTags, hiddenTags: $hiddenTags)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Custom Navigation Bar (Title & Actions)

    private var customNavBar: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isShowingTagsView.toggle()
            }
        }) {
            HStack(alignment: .center) {
                Text(isShowingTagsView ? "Etiketler" : "Takvim & Notlar")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Header Controls View
    
    private var headerView: some View {
        HStack {
            // Month & Year Title
            Text(monthYearString(from: currentMonthDate))
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 12) {
                // Today Button
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        currentMonthDate = Date()
                        selectedDate = Date()
                        isSearching = false
                        searchQuery = ""
                    }
                }) {
                    Text("BUGÜN")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.12))
                        )
                }

                // Month Chevrons
                HStack(spacing: 8) {
                    Button(action: { changeMonth(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
                    }

                    Button(action: { changeMonth(by: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
                    }
                }
            }
        }
    }

    // MARK: - Search Bar Section
    
    private var searchBarSection: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Notlarda başlık, içerik veya etiket ara...", text: $searchQuery)
                    .font(.system(size: 15))
                    .autocapitalization(.none)

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(UIColor.systemBackground))
            )

            Button(action: {
                withAnimation {
                    isSearching = false
                    searchQuery = ""
                }
            }) {
                Text("Kapat")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Search Results Section
    
    private var searchResultsSection: some View {
        let filteredResults = filteredAndSortedNotes
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "ARAMAK İÇİN YAZIN..."
                     : "ARAMA SONUÇLARI (\(filteredResults.count))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)

                Spacer()
            }

            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.3))

                    Text("Aramak istediğiniz metni yazın")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if filteredResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("\"\(searchQuery)\" ile eşleşen not bulunamadı")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredResults) { note in
                        NoteCardRow(note: note, showDate: true)
                            .opacity(note.isPastNote ? 0.55 : 1.0)
                            .onTapGesture {
                                selectedNoteForDetail = note
                            }
                    }
                }
            }
        }
    }

    private var filteredAndSortedNotes: [NoteItem] {
        let sorted = notes.sorted { (n1, n2) -> Bool in
            let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
            let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
            return date1 > date2
        }

        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return sorted.filter { note in
            let titleMatch = (note.title ?? "").lowercased().contains(query)
            let contentMatch = (note.displayContent ?? "").strippedHTML.lowercased().contains(query)
            let tagMatch = note.tags?.contains(where: { $0.lowercased().contains(query) }) ?? false
            return titleMatch || contentMatch || tagMatch
        }
    }

    // MARK: - Calendar Grid Section
    
    private var calendarGridSection: some View {
        let days = generateDaysInMonth(for: currentMonthDate)
        return VStack(spacing: 10) {
            // Week Days Row
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(day == "CMT" || day == "PAZ" ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            // Month Days Grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
                ForEach(days, id: \.date) { monthDay in
                    dayCellView(for: monthDay)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -50 {
                            changeMonth(by: 1)
                        } else if value.translation.width > 50 {
                            changeMonth(by: -1)
                        }
                    }
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4) // Bring closer to edges
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }

    // MARK: - Single Day Cell View
    
    private func dayCellView(for monthDay: MonthDay) -> some View {
        let isToday = calendar.isDateInToday(monthDay.date)
        let isSelected = calendar.isDate(monthDay.date, inSameDayAs: selectedDate)
        let dayNotes = notesForDate(monthDay.date)
        let dayHolidays = holidaysForDate(monthDay.date)

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedDate = monthDay.date
                if !monthDay.isCurrentMonth {
                    currentMonthDate = monthDay.date
                }
            }
        }) {
            VStack(spacing: 4) {
                // Day Number Circle
                ZStack {
                    if isToday {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 26, height: 26)
                    } else if isSelected {
                        Circle()
                            .stroke(Color.blue, lineWidth: 2)
                            .background(Circle().fill(Color.blue.opacity(0.12)))
                            .frame(width: 26, height: 26)
                    }

                    Text("\(calendar.component(.day, from: monthDay.date))")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .regular))
                        .foregroundColor(
                            isToday ? .white :
                            (!monthDay.isCurrentMonth ? .secondary.opacity(0.3) : .primary)
                        )
                }

                if calendarViewMode == "stack" {
                    // Stack list mode (Title labels) - Show all notes and holidays
                    VStack(spacing: 2) {
                        ForEach(dayHolidays) { holiday in
                            Text(holiday.title)
                                .font(.system(size: 7, weight: .bold))
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hex: "#ffc107").opacity(0.15))
                                .foregroundColor(Color(hex: "#d39e00"))
                                .cornerRadius(2)
                        }
                        
                        ForEach(dayNotes) { note in
                            Text(note.title ?? "Not")
                                .font(.system(size: 7, weight: .bold))
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hex: note.colorHex).opacity(0.12))
                                .foregroundColor(Color(hex: note.colorHex))
                                .cornerRadius(2)
                        }
                    }
                    .padding(.horizontal, 2)
                } else {
                    // Dots list mode (render notes dots + one yellow holiday dot if present)
                    HStack(spacing: 3) {
                        if !dayHolidays.isEmpty {
                            Circle()
                                .fill(Color(hex: "#ffc107"))
                                .frame(width: 5, height: 5)
                        }
                        
                        if !dayNotes.isEmpty {
                            ForEach(Array(dayNotes.prefix(3).enumerated()), id: \.offset) { _, note in
                                Circle()
                                    .fill(Color(hex: note.colorHex))
                                    .frame(width: 5, height: 5)
                            }
                            if dayNotes.count > 3 {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 3, height: 3)
                            }
                        }
                        
                        if dayNotes.isEmpty && dayHolidays.isEmpty {
                            Color.clear.frame(height: 5)
                        }
                    }
                    .frame(height: 10)
                }
            }
            .frame(minHeight: calendarViewMode == "stack" ? 54 : 44)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Selected Date Notes Section
    
    private var selectedDateNotesSection: some View {
        let currentDayNotes = notesForDate(selectedDate)
        let currentDayHolidays = holidaysForDate(selectedDate)
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDateFormattedString.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)

                    Text("\(currentDayNotes.count) Not, \(currentDayHolidays.count) Tatil Bulundu")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()
                
                Button(action: {
                    isAddNotePresented = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.blue)
                }
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if currentDayNotes.isEmpty && currentDayHolidays.isEmpty {
                emptyNotesView
            } else {
                VStack(spacing: 10) {
                    // Holidays list first
                    ForEach(currentDayHolidays) { holiday in
                        HStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: "#ffc107"))
                                .frame(width: 5)
                                .frame(maxHeight: .infinity)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "flag.fill")
                                        .font(.system(size: 10))
                                    Text("RESMİ TATİL")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(Color(hex: "#d39e00"))
                                
                                Text(holiday.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                
                                Text("Türkiye Cumhuriyeti Resmi Tatili")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(hex: "#ffc107").opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(hex: "#ffc107").opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.01), radius: 6, x: 0, y: 3)
                    }

                    // Notes list
                    ForEach(currentDayNotes) { note in
                        NoteCardRow(note: note)
                            .onTapGesture {
                                selectedNoteForDetail = note
                            }
                    }
                }
            }
        }
    }

    // MARK: - Empty Notes View
    
    private var emptyNotesView: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.6))

            Text("Seçilen günde not bulunmuyor")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Firestore Sync
    
    private func fetchNotes() {
        guard let user = Auth.auth().currentUser else {
            isLoading = false
            return
        }

        let db = Firestore.firestore()
        listenerRegistration = db.collection("users")
            .document(user.uid)
            .collection("notes")
            .addSnapshotListener { snapshot, error in
                isLoading = false
                if let error = error {
                    print("Error fetching notes: \(error.localizedDescription)")
                    return
                }

                guard let documents = snapshot?.documents else { return }
                
                var fetchedNotes: [NoteItem] = []
                for doc in documents {
                    if let note = try? doc.data(as: NoteItem.self), note.deleted != true {
                        fetchedNotes.append(note)
                    }
                }
                
                withAnimation(.default) {
                    self.notes = fetchedNotes
                    
                    if let current = self.selectedNoteForDetail {
                        self.selectedNoteForDetail = fetchedNotes.first(where: { $0.id == current.id })
                    }

                    // Determine which note ID to open (initialSelectedNoteId OR UserDefaults deep link)
                    let pendingUD = UserDefaults.standard.string(forKey: "pendingDeepLinkNoteId") ?? ""
                    let targetId = self.initialSelectedNoteId ?? (pendingUD.isEmpty ? nil : pendingUD)

                    if let targetId = targetId, self.selectedNoteForDetail == nil {
                        if let matched = fetchedNotes.first(where: { $0.id == targetId }) {
                            // Clear states immediately so it only triggers once
                            self.initialSelectedNoteId = nil
                            UserDefaults.standard.removeObject(forKey: "pendingDeepLinkNoteId")
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                self.selectedNoteForDetail = matched
                            }
                            if let pDate = matched.parsedDate {
                                self.selectedDate = pDate
                                self.currentMonthDate = pDate
                            }
                        }
                    }
                }
            }
    }

    // MARK: - Helper Methods
    
    private func changeMonth(by value: Int) {
        if let newDate = calendar.date(byAdding: .month, value: value, to: currentMonthDate) {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentMonthDate = newDate
            }
        }
    }

    private func notesForDate(_ date: Date) -> [NoteItem] {
        let targetStr = dateString(from: date)
        return notes.filter { note in
            if let d = note.date, !d.isEmpty {
                return d == targetStr
            }
            if let parsed = note.parsedDate {
                return calendar.isDate(parsed, inSameDayAs: date)
            }
            return false
        }
    }

    private func monthYearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date).capitalized
    }

    private var selectedDateFormattedString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy, EEEE"
        return formatter.string(from: selectedDate)
    }

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func generateDaysInMonth(for date: Date) -> [MonthDay] {
        var cal = calendar
        cal.firstWeekday = 2 // Monday start
        
        guard let monthInterval = cal.dateInterval(of: .month, for: date),
              let monthFirstWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return []
        }

        var days: [MonthDay] = []
        var current = monthFirstWeek.start
        
        for _ in 0..<42 {
            let isCurrentMonth = cal.isDate(current, equalTo: date, toGranularity: .month)
            days.append(MonthDay(date: current, isCurrentMonth: isCurrentMonth))
            if let next = cal.date(byAdding: .day, value: 1, to: current) {
                current = next
            }
        }
        return days
    }

    private func holidaysForDate(_ date: Date) -> [HolidayItem] {
        let targetStr = dateString(from: date)
        return holidays.filter { $0.date == targetStr }
    }

    private func fetchHolidays() {
        let year = calendar.component(.year, from: Date())
        let years = [year - 1, year, year + 1]
        
        let religiousHolidays = [
            // 2024
            HolidayItem(date: "2024-04-10", title: "Ramazan Bayramı 1. Gün"),
            HolidayItem(date: "2024-04-11", title: "Ramazan Bayramı 2. Gün"),
            HolidayItem(date: "2024-04-12", title: "Ramazan Bayramı 3. Gün"),
            HolidayItem(date: "2024-06-16", title: "Kurban Bayramı 1. Gün"),
            HolidayItem(date: "2024-06-17", title: "Kurban Bayramı 2. Gün"),
            HolidayItem(date: "2024-06-18", title: "Kurban Bayramı 3. Gün"),
            HolidayItem(date: "2024-06-19", title: "Kurban Bayramı 4. Gün"),
            // 2025
            HolidayItem(date: "2025-03-30", title: "Ramazan Bayramı 1. Gün"),
            HolidayItem(date: "2025-03-31", title: "Ramazan Bayramı 2. Gün"),
            HolidayItem(date: "2025-04-01", title: "Ramazan Bayramı 3. Gün"),
            HolidayItem(date: "2025-06-06", title: "Kurban Bayramı 1. Gün"),
            HolidayItem(date: "2025-06-07", title: "Kurban Bayramı 2. Gün"),
            HolidayItem(date: "2025-06-08", title: "Kurban Bayramı 3. Gün"),
            HolidayItem(date: "2025-06-09", title: "Kurban Bayramı 4. Gün"),
            // 2026
            HolidayItem(date: "2026-03-20", title: "Ramazan Bayramı 1. Gün"),
            HolidayItem(date: "2026-03-21", title: "Ramazan Bayramı 2. Gün"),
            HolidayItem(date: "2026-03-22", title: "Ramazan Bayramı 3. Gün"),
            HolidayItem(date: "2026-05-27", title: "Kurban Bayramı 1. Gün"),
            HolidayItem(date: "2026-05-28", title: "Kurban Bayramı 2. Gün"),
            HolidayItem(date: "2026-05-29", title: "Kurban Bayramı 3. Gün"),
            HolidayItem(date: "2026-05-30", title: "Kurban Bayramı 4. Gün"),
            // 2027
            HolidayItem(date: "2027-03-09", title: "Ramazan Bayramı 1. Gün"),
            HolidayItem(date: "2027-03-10", title: "Ramazan Bayramı 2. Gün"),
            HolidayItem(date: "2027-03-11", title: "Ramazan Bayramı 3. Gün"),
            HolidayItem(date: "2027-05-16", title: "Kurban Bayramı 1. Gün"),
            HolidayItem(date: "2027-05-17", title: "Kurban Bayramı 2. Gün"),
            HolidayItem(date: "2027-05-18", title: "Kurban Bayramı 3. Gün"),
            HolidayItem(date: "2027-05-19", title: "Kurban Bayramı 4. Gün")
        ]
        
        self.holidays = religiousHolidays
        
        for y in years {
            guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(y)/TR") else { continue }
            URLSession.shared.dataTask(with: url) { data, response, error in
                guard let data = data, error == nil else { return }
                do {
                    let decoded = try JSONDecoder().decode([HolidayItem].self, from: data)
                    DispatchQueue.main.async {
                        var current = self.holidays
                        current.append(contentsOf: decoded)
                        var seen = Set<String>()
                        self.holidays = current.filter {
                            let key = "\($0.date)-\($0.title)"
                            if seen.contains(key) {
                                return false
                            } else {
                                seen.insert(key)
                                return true
                            }
                        }
                    }
                } catch {
                    print("Holiday decode error:", error)
                }
            }.resume()
        }
    }

    private var tagsViewSubpage: some View {
        let activeTags = noteTags.filter { !hiddenTags.contains($0.name) }
        
        // Sort tags by most recent note date (newest note tag first)
        let sortedActiveTags = activeTags.sorted { (tag1, tag2) -> Bool in
            let date1 = getTagLatestDate(tagName: tag1.name)
            let date2 = getTagLatestDate(tagName: tag2.name)
            return date1 > date2
        }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Notlarınızı etiketlerine göre görsel bir biçimde inceleyin ve yönetin.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            
            // Horizontal Scroll View of Tag Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(sortedActiveTags, id: \.id) { tag in
                        let isSelected = (selectedTag ?? sortedActiveTags.first?.name) == tag.name
                        TagCardWrapperView(
                            tag: tag,
                            notes: notes,
                            isSelected: isSelected,
                            lastUpdated: getTagLastUpdatedString(tagName: tag.name)
                        )
                        .scaleEffect(isSelected ? 1.05 : 0.95)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selectedTag = tag.name
                                tagNotesPage = 1 // Reset pagination page on active tag switch
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            
            // Active Tag Detail Notes
            if let activeTag = selectedTag ?? sortedActiveTags.first?.name {
                let activeTagNotes = notes.filter { ($0.tags ?? []).contains(activeTag) && $0.deleted != true }
                    .sorted { (n1, n2) -> Bool in
                        let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
                        let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
                        return date1 > date2
                    }
                
                let totalCount = activeTagNotes.count
                let limit = tagNotesLimit
                let displayedNotes = Array(activeTagNotes.prefix(tagNotesPage * limit))
                
                VStack(alignment: .leading, spacing: 12) {
                    Divider().padding(.vertical, 8)
                    
                    HStack {
                        Text(activeTag)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        
                        Text("etiketli notlar (\(totalCount) not)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            isAddNotePresented = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Yeni Not Ekle")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.blue))
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // List of Notes having the active tag
                    VStack(spacing: 10) {
                        ForEach(displayedNotes) { note in
                            HStack(spacing: 16) {
                                // Date
                                Text(formatDotsDate(from: note.date ?? ""))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                
                                // Image Poster
                                NoteImageView(urlString: note.imageUrl)
                                    .frame(width: 24, height: 36)
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                                
                                // Title
                                Text(note.title ?? "Başlıksız Not")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.gray.opacity(0.4))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
                            .onTapGesture {
                                selectedNoteForDetail = note
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Pagination controls (Daha fazla göster button)
                    if totalCount > displayedNotes.count {
                        Button(action: {
                            withAnimation {
                                tagNotesPage += 1
                            }
                        }) {
                            Text("Daha Fazla Göster")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.blue)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }
                    
                    // View Limit selector
                    HStack {
                        Text("GÖRÜNÜM LİMİTİ:")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            ForEach([5, 10, 25, 50, 9999], id: \.self) { size in
                                Button(action: {
                                    tagNotesLimit = size
                                    tagNotesPage = 1 // Reset page
                                }) {
                                    Text(size == 9999 ? "Tümü" : "\(size)")
                                        .font(.system(size: 11, weight: tagNotesLimit == size ? .bold : .semibold))
                                        .foregroundColor(tagNotesLimit == size ? .blue : .secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(tagNotesLimit == size ? Color.blue.opacity(0.12) : Color.clear)
                                        .cornerRadius(6)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func formatDotsDate(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        let display = DateFormatter()
        display.dateFormat = "dd.MM.yyyy"
        return display.string(from: date)
    }

    private func fetchNoteTags() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        db.collection("users").document(user.uid).collection("noteTags")
            .addSnapshotListener { snap, error in
                guard let docs = snap?.documents else { return }
                self.noteTags = docs.map { doc in
                    let data = doc.data()
                    return NoteTagItem(
                        id: doc.documentID,
                        name: data["name"] as? String ?? "",
                        color: data["color"] as? String,
                        visible: data["visible"] as? Bool ?? true,
                        imageUrl: data["imageUrl"] as? String,
                        useCollage: data["useCollage"] as? Bool ?? true,
                        order: data["order"] as? Int
                    )
                }
                .sorted { ($0.order ?? 99) < ($1.order ?? 99) }
            }
    }

    private func fetchNotesSettings() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        db.collection("users").document(user.uid).collection("config").document("notesSettings")
            .addSnapshotListener { snap, error in
                guard let data = snap?.data() else { return }
                self.hiddenTags = data["hiddenTags"] as? [String] ?? []
            }
    }

    private func getTagLatestDate(tagName: String) -> Date {
        let tagNotes = notes.filter { ($0.tags ?? []).contains(tagName) && $0.deleted != true }
        guard !tagNotes.isEmpty else { return Date.distantPast }
        let sorted = tagNotes.sorted { (n1, n2) -> Bool in
            let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
            let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
            return date1 > date2
        }
        return sorted.first?.createdAt ?? sorted.first?.parsedDate ?? Date.distantPast
    }

    private func getTagLastUpdatedString(tagName: String) -> String? {
        let tagNotes = notes.filter { ($0.tags ?? []).contains(tagName) && $0.deleted != true }
        guard !tagNotes.isEmpty else { return nil }
        
        let sorted = tagNotes.sorted { (n1, n2) -> Bool in
            let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
            let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
            return date1 > date2
        }
        
        guard let mostRecent = sorted.first else { return nil }
        let mostRecentDate = mostRecent.createdAt ?? mostRecent.parsedDate ?? Date()
        
        let calendar = Calendar.current
        if calendar.isDateInToday(mostRecentDate) {
            return "bugün"
        } else if calendar.isDateInYesterday(mostRecentDate) {
            return "dün"
        } else {
            let diffs = calendar.dateComponents([.day, .month], from: mostRecentDate, to: Date())
            if let months = diffs.month, months > 0 {
                return "\(months) ay önce"
            } else if let days = diffs.day, days > 0 {
                return "\(days) gün önce"
            }
            return "az önce"
        }
    }
}

// MARK: - Note Card Row Component

struct NoteCardRow: View {
    let note: NoteItem
    var showDate: Bool = false

    private var noteColor: Color { Color(hex: note.colorHex) }
    
    private var formattedNoteDate: String? {
        guard let dateStr = note.date, !dateStr.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        let display = DateFormatter()
        display.locale = Locale(identifier: "tr_TR")
        display.dateFormat = "d MMM yyyy"
        return display.string(from: date)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Thicker accent side bar
            RoundedRectangle(cornerRadius: 3)
                .fill(noteColor)
                .frame(width: 5)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.title ?? "Başlıksız Not")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if note.isPastNote {
                        Text("GEÇMİŞ")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                            .foregroundColor(.orange)
                    }
                }

                if let content = note.displayContent, !content.strippedHTML.isEmpty {
                    Text(content.strippedHTML)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                }

                HStack(spacing: 8) {
                    if showDate, let dateLabel = formattedNoteDate {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                            Text(note.time.flatMap { $0.isEmpty ? nil : "\(dateLabel) · \($0)" } ?? dateLabel)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(noteColor)
                    } else if let time = note.time, !time.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(time)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.gray)
                    }

                    if let tags = note.tags, !tags.isEmpty {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(noteColor.opacity(0.08)))
                                .foregroundColor(noteColor)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.gray.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(noteColor.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 3)
    }
}

struct NoteDetailSheetView: View {
    @Binding var note: NoteItem?
    var allNotes: [NoteItem]
    @Environment(\.presentationMode) var presentationMode
    @State private var contentHeight: CGFloat = 100
    @State private var appeared: Bool = false
    @State private var isEditPresented: Bool = false
    @State private var showDeleteAlert: Bool = false

    private var noteColor: Color {
        guard let note = note else { return .blue }
        return Color(hex: note.colorHex)
    }

    var body: some View {
        Group {
            if let actualNote = note {
                ZStack(alignment: .top) {
                    Color(UIColor.systemBackground).ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            // ── HERO HEADER ──────────────────────────────────
                            heroHeader(actualNote: actualNote)

                            // ── CONTENT BODY ─────────────────────────────────
                            VStack(spacing: 16) {
                                metaInfoRow(actualNote: actualNote)

                                if let tags = actualNote.tags, !tags.isEmpty {
                                    tagsCard(tags: tags, actualNote: actualNote)
                                }

                                contentCard(actualNote: actualNote)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                            .offset(y: -24)
                        }
                    }

                    // ── TOP BUTTONS ─────────────────────────────────────
                    topButtons
                }
                .ignoresSafeArea(edges: .top)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.1)) {
                        appeared = true
                    }
                }
                .sheet(isPresented: $isEditPresented) {
                    AddEditNoteSheetView(noteToEdit: actualNote, initialDate: actualNote.parsedDate ?? Date(), allNotes: allNotes)
                }
            } else {
                Color.clear.onAppear { presentationMode.wrappedValue.dismiss() }
            }
        }
    }

    // MARK: Hero Header

    private func heroHeader(actualNote: NoteItem) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Gradient background
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: noteColor.opacity(0.85), location: 0),
                        .init(color: noteColor.opacity(0.55), location: 0.6),
                        .init(color: noteColor.opacity(0.25), location: 1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Decorative circles
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 160, height: 160)
                    .offset(x: geo.size.width * 0.6, y: -20)

                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 100, height: 100)
                    .offset(x: geo.size.width * 0.75, y: -80)

                // Title block
                VStack(alignment: .leading, spacing: 10) {
                    if let itemType = actualNote.itemType, !itemType.isEmpty {
                        Text(itemType.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }

                    Text(actualNote.title ?? "Başlıksız Not")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let dateStr = actualNote.date, !dateStr.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 11, weight: .semibold))
                            Text(formattedShortDate(from: dateStr))
                                .font(.system(size: 13, weight: .medium))
                            if let timeStr = actualNote.time, !timeStr.isEmpty {
                                Text("·").font(.system(size: 13))
                                Image(systemName: "clock")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(timeStr).font(.system(size: 13, weight: .medium))
                            }
                        }
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
        }
        .frame(height: 220)
    }

    // MARK: Meta Info Row

    private func metaInfoRow(actualNote: NoteItem) -> some View {
        HStack(spacing: 12) {
            if let dateStr = actualNote.date, !dateStr.isEmpty {
                metaChip(
                    icon: "calendar",
                    label: "Tarih",
                    value: formattedShortDate(from: dateStr)
                )
            }

            if let timeStr = actualNote.time, !timeStr.isEmpty {
                metaChip(
                    icon: "clock",
                    label: "Saat",
                    value: timeStr
                )
            }

            if actualNote.isPastNote {
                metaChip(
                    icon: "exclamationmark.triangle",
                    label: "Durum",
                    value: "Geçmiş",
                    accent: Color.orange
                )
            }
        }
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)
    }

    private func metaChip(icon: String, label: String, value: String, accent: Color = Color(hex: "#007AFF")) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Tags Card

    private func tagsCard(tags: [String], actualNote: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(noteColor)
                Text("ETİKETLER")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.secondary)
            }

            SimpleTagWrap(tags: tags, accentColor: noteColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
    }

    // MARK: Content Card

    private func contentCard(actualNote: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header label
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(noteColor)
                Text("NOT İÇERİĞİ")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 14)

            // Content — rendered below the header, no fixed height
            if let content = actualNote.displayContent, !content.isEmpty {
                NoteHTMLTextView(htmlContent: content)
            } else {
                HStack {
                    Image(systemName: "text.badge.xmark")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("İçerik girilmemiş.")
                        .font(.system(size: 14))
                        .italic()
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appeared)
    }

    // MARK: Top Buttons (Edit, Delete & Close)

    private var topButtons: some View {
        HStack {
            // Edit & Delete buttons (leading)
            HStack(spacing: 12) {
                Button(action: { isEditPresented = true }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.28)))
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                }
                
                if let actualNote = note {
                    Button(action: { showDeleteAlert = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.red.opacity(0.7)))
                            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                    }
                    .alert(isPresented: $showDeleteAlert) {
                        Alert(
                            title: Text("Notu Sil"),
                            message: Text("Bu notu silmek istediğinize emin misiniz?"),
                            primaryButton: .destructive(Text("Sil")) {
                                deleteNote(actualNote: actualNote)
                            },
                            secondaryButton: .cancel(Text("Vazgeç"))
                        )
                    }
                }
            }
            .padding(.top, 54)
            .padding(.leading, 18)
            
            Spacer()
            
            // Close button (trailing)
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.28)))
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
            }
            .padding(.top, 54)
            .padding(.trailing, 18)
        }
    }

    // MARK: Helpers

    private func deleteNote(actualNote: NoteItem) {
        guard let user = Auth.auth().currentUser, let noteId = actualNote.id else { return }
        let db = Firestore.firestore()
        
        db.collection("users").document(user.uid).collection("notes").document(noteId).updateData([
            "deleted": true
        ]) { error in
            if error == nil {
                presentationMode.wrappedValue.dismiss()
                self.note = nil
            }
        }
    }

    private func formattedShortDate(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        let display = DateFormatter()
        display.locale = Locale(identifier: "tr_TR")
        display.dateFormat = "d MMM yyyy, EEEE"
        return display.string(from: date)
    }
}

// MARK: - Simple Tag Wrap (reliable, no GeometryReader)

struct SimpleTagWrap: View {
    let tags: [String]
    let accentColor: Color

    var body: some View {
        WrappingHStack(tags: tags, accentColor: accentColor)
    }
}

struct WrappingHStack: View {
    let tags: [String]
    let accentColor: Color

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for tag in tags {
            if current.count == 3 {
                result.append(current)
                current = [tag]
            } else {
                current.append(tag)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(rows[i], id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(accentColor.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(accentColor.opacity(0.25), lineWidth: 1))
                    }
                }
            }
        }
    }
}

// MARK: - Add / Edit Note Sheet View

struct AddEditNoteSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    var noteToEdit: NoteItem?
    var initialDate: Date
    var allNotes: [NoteItem]
    var initialTags: [String] = []
    
    @State private var title: String = ""
    @State private var noteText: String = "" // HTML content
    @State private var selectedColor: String = "blue"
    @State private var tagsList: [String] = []
    @State private var tagInput: String = ""
    @State private var itemType: String = ""
    @State private var noteDate: Date = Date()
    @State private var noteImageUrl: String = ""
    @State private var isContentExpanded: Bool = false
    
    // Rich Text State
    @State private var activeCommand: String = ""
    
    private let colors = ["blue", "red", "green", "yellow"]
    
    private var recentImages: [String] {
        var images: [String] = []
        var seen = Set<String>()
        // Sort notes chronologically based on date
        let sortedNotes = allNotes.sorted { (n1, n2) -> Bool in
            let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
            let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
            return date1 > date2
        }
        for note in sortedNotes {
            if let img = note.imageUrl, !img.isEmpty, !seen.contains(img) && note.deleted != true {
                seen.insert(img)
                images.append(img)
            }
        }
        return Array(images.prefix(15))
    }
    
    private var similarNotes: [NoteItem] {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if query.isEmpty { return [] }
        return allNotes.filter {
            let noteTitle = ($0.title ?? "").lowercased(with: Locale(identifier: "tr_TR"))
            return noteTitle.contains(query) && noteTitle != query
        }
        .sorted { (n1, n2) -> Bool in
            let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
            let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
            return date1 > date2
        }
        .prefix(4)
        .map { $0 }
    }
    
    private var globalTags: [String] {
        Array(Set(allNotes.flatMap { $0.tags ?? [] })).sorted()
    }
    
    private var filteredTagSuggestions: [String] {
        let query = tagInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        return globalTags.filter {
            let tagLower = $0.lowercased(with: Locale(identifier: "tr_TR"))
            if query.isEmpty {
                return !tagsList.contains($0)
            } else {
                return tagLower.contains(query) && !tagsList.contains($0) && tagLower != query
            }
        }
        .prefix(6)
        .map { $0 }
    }
    
    var body: some View {
        NavigationView {
            Group {
                if isContentExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        // Header Bar inside expanded mode
                        HStack {
                            Text("Not İçeriği (Tam Ekran)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isContentExpanded.toggle()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("Küçült")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        
                        // Rich text styling toolbar
                        RichTextToolbar(activeCommand: $activeCommand)
                            .padding(.horizontal, 12)
                        
                        // Expanded web editor wrapper filling entire sheet
                        RichTextEditorView(htmlContent: $noteText, activeCommand: $activeCommand)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground).ignoresSafeArea())
                } else {
                    Form {
                        Section(header: Text("Genel Bilgiler")) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Not başlığı girin...", text: $title)
                                    .font(.system(size: 16, weight: .bold))
                                
                                if !similarNotes.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("VAROLAN BAŞLIKLAR (Tıkla ve Kopyala)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.gray)
                                            .padding(.top, 4)
                                        
                                        ForEach(similarNotes) { note in
                                            Button(action: {
                                                title = note.title ?? ""
                                                selectedColor = note.color ?? "blue"
                                                tagsList = note.tags ?? []
                                                itemType = note.itemType ?? ""
                                            }) {
                                                HStack {
                                                    Circle()
                                                        .fill(Color(hex: getHexForColorName(note.color ?? "blue")))
                                                        .frame(width: 8, height: 8)
                                                    Text(note.title ?? "")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(.primary)
                                                    Spacer()
                                                }
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 8)
                                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                            
                            DatePicker("Tarih", selection: $noteDate, displayedComponents: .date)
                                .environment(\.locale, Locale(identifier: "tr_TR"))
                        }
                        
                        Section(header: Text("Etiketler")) {
                            VStack(alignment: .leading, spacing: 8) {
                                // Tag badges list
                                if !tagsList.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(tagsList, id: \.self) { tag in
                                                HStack(spacing: 4) {
                                                    Text(tag)
                                                        .font(.system(size: 11, weight: .medium))
                                                    Button(action: {
                                                        tagsList.removeAll { $0 == tag }
                                                    }) {
                                                        Image(systemName: "xmark")
                                                            .font(.system(size: 8, weight: .bold))
                                                            .foregroundColor(.blue.opacity(0.6))
                                                    }
                                                    .buttonStyle(PlainButtonStyle())
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Capsule().fill(Color.blue.opacity(0.1)))
                                                .foregroundColor(.blue)
                                            }
                                        }
                                    }
                                }
                                
                                // Tag input field
                                HStack {
                                    TextField("Etiket ekle...", text: $tagInput, onCommit: {
                                        addTag()
                                    })
                                    .textFieldStyle(PlainTextFieldStyle())
                                    
                                    Button(action: {
                                        addTag()
                                    }) {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 20))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                
                                // Tag suggestions list
                                if !filteredTagSuggestions.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(filteredTagSuggestions, id: \.self) { tag in
                                                Button(action: {
                                                    tagsList.append(tag)
                                                    tagInput = ""
                                                }) {
                                                    Text(tag)
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Capsule().fill(Color.gray.opacity(0.12)))
                                                        .foregroundColor(.primary)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        
                        Section(header: Text("Not Rengi")) {
                            HStack(spacing: 16) {
                                ForEach(colors, id: \.self) { colorName in
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: getHexForColorName(colorName)))
                                            .frame(width: 32, height: 32)
                                            .onTapGesture {
                                                selectedColor = colorName
                                            }
                                        
                                        if selectedColor == colorName {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.white)
                                                .font(.system(size: 12, weight: .bold))
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Section(header: Text("Afiş Görseli")) {
                            VStack(alignment: .leading, spacing: 10) {
                                if !recentImages.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("SON KULLANILAN AFİŞLER (Tıkla ve Seç)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.gray)
                                        
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(recentImages, id: \.self) { imgUrl in
                                                    let isSelected = noteImageUrl == imgUrl
                                                    NoteImageView(urlString: imgUrl)
                                                        .frame(width: 45, height: 65)
                                                        .cornerRadius(6)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 6)
                                                                .stroke(isSelected ? Color.blue : Color.gray.opacity(0.2), lineWidth: isSelected ? 2.5 : 1)
                                                        )
                                                        .scaleEffect(isSelected ? 1.05 : 1.0)
                                                        .onTapGesture {
                                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                                                if noteImageUrl == imgUrl {
                                                                    noteImageUrl = ""
                                                                } else {
                                                                    noteImageUrl = imgUrl
                                                                }
                                                            }
                                                        }
                                                }
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Section(header:
                            HStack {
                                Text("Not İçeriği")
                                Spacer()
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        isContentExpanded.toggle()
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Genişlet")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundColor(.blue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                // Rich text styling toolbar
                                RichTextToolbar(activeCommand: $activeCommand)
                                    .frame(maxWidth: .infinity)
                                
                                // Custom web editor wrapper
                                RichTextEditorView(htmlContent: $noteText, activeCommand: $activeCommand)
                                    .frame(minHeight: 300)
                                    .background(Color(UIColor.systemBackground))
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(noteToEdit == nil ? "Yeni Not Ekle" : "Notu Düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kaydet") {
                        saveNoteToFirestore()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let note = noteToEdit {
                    title = note.title ?? ""
                    noteText = note.displayContent ?? ""
                    selectedColor = note.color ?? "blue"
                    tagsList = note.tags ?? []
                    itemType = note.itemType ?? ""
                    noteImageUrl = note.imageUrl ?? ""
                    if let pDate = note.parsedDate {
                        noteDate = pDate
                    }
                } else {
                    noteDate = initialDate
                    tagsList = initialTags
                }
            }
        }
    }
    
    private func addTag() {
        let cleaned = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty && !tagsList.contains(cleaned) {
            tagsList.append(cleaned)
        }
        tagInput = ""
    }
    
    private func getHexForColorName(_ name: String) -> String {
        switch name.lowercased() {
        case "red": return "#ff4d4d"
        case "green": return "#2ecc71"
        case "yellow": return "#f1c40f"
        case "blue": return "#3498db"
        default: return "#3498db"
        }
    }
    
    private func saveNoteToFirestore() {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: noteDate)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: Date())
        
        let docRef: DocumentReference
        if let editNote = noteToEdit, let noteId = editNote.id {
            docRef = db.collection("users").document(user.uid).collection("notes").document(noteId)
        } else {
            docRef = db.collection("users").document(user.uid).collection("notes").document()
        }
        
        let data: [String: Any] = [
            "title": title,
            "text": noteText,
            "color": selectedColor,
            "tags": tagsList,
            "itemType": itemType,
            "date": dateStr,
            "time": timeStr,
            "imageUrl": noteImageUrl,
            "deleted": false,
            "createdAt": noteToEdit == nil ? FieldValue.serverTimestamp() : (noteToEdit?.createdAt ?? FieldValue.serverTimestamp())
        ]
        
        docRef.setData(data, merge: true)
    }
}

// MARK: - Rich Text Editor WKWebView Wrapper

struct RichTextEditorView: UIViewRepresentable {
    @Binding var htmlContent: String
    @Binding var activeCommand: String
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichTextEditorView
        
        init(_ parent: RichTextEditorView) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "editorContentChanged", let content = message.body as? String {
                DispatchQueue.main.async {
                    self.parent.htmlContent = content
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let escapedHTML = parent.htmlContent.replacingOccurrences(of: "\\", with: "\\\\")
                                                .replacingOccurrences(of: "'", with: "\\'")
                                                .replacingOccurrences(of: "\n", with: "\\n")
                                                .replacingOccurrences(of: "\r", with: "\\r")
            webView.evaluateJavaScript("setEditorContent('\(escapedHTML)')", completionHandler: nil)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "editorContentChanged")
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        
        let editorHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        body {
            font-family: -apple-system, system-ui;
            font-size: 16px;
            padding: 12px;
            margin: 0;
            outline: none;
            min-height: 280px;
            background-color: transparent;
            color: #000000;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #ffffff; }
        }
        #editor {
            min-height: 280px;
            outline: none;
        }
        #editor:empty:before {
            content: attr(placeholder);
            color: #c7c7cc;
        }
        blockquote {
            border-left: 3px solid #007aff;
            margin: 0 0 10px 0;
            padding-left: 10px;
            color: #666;
            font-style: italic;
        }
        </style>
        </head>
        <body>
        <div contenteditable="true" id="editor" placeholder="Not içeriği..."></div>
        <script>
        var editor = document.getElementById('editor');
        
        editor.addEventListener('input', function() {
            window.webkit.messageHandlers.editorContentChanged.postMessage(editor.innerHTML);
        });
        
        function setEditorContent(content) {
            editor.innerHTML = content;
        }
        
        function executeCommand(command, value = null) {
            document.execCommand(command, false, value);
            window.webkit.messageHandlers.editorContentChanged.postMessage(editor.innerHTML);
        }
        </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(editorHTML, baseURL: nil)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if !activeCommand.isEmpty {
            let commandParts = activeCommand.split(separator: ":")
            let cmd = String(commandParts[0])
            let val = commandParts.count > 1 ? String(commandParts[1]) : nil
            
            let js: String
            if let value = val {
                js = "executeCommand('\(cmd)', '\(value)')"
            } else {
                js = "executeCommand('\(cmd)')"
            }
            uiView.evaluateJavaScript(js, completionHandler: nil)
            
            DispatchQueue.main.async {
                activeCommand = ""
            }
        }
    }
}

// MARK: - Rich Text Formatting Toolbar

struct RichTextToolbar: View {
    @Binding var activeCommand: String
    @State private var showLinkAlert = false
    @State private var linkURL = ""
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button(action: { activeCommand = "formatBlock:p" }) {
                    Text("¶").font(.system(size: 16, weight: .bold))
                }
                Button(action: { activeCommand = "formatBlock:h1" }) {
                    Text("H1").font(.system(size: 13, weight: .bold))
                }
                Button(action: { activeCommand = "formatBlock:h2" }) {
                    Text("H2").font(.system(size: 13, weight: .bold))
                }
                Button(action: { activeCommand = "formatBlock:h3" }) {
                    Text("H3").font(.system(size: 13, weight: .bold))
                }
                
                Divider().frame(height: 18)
                
                Button(action: { activeCommand = "bold" }) {
                    Image(systemName: "bold")
                }
                Button(action: { activeCommand = "italic" }) {
                    Image(systemName: "italic")
                }
                Button(action: { activeCommand = "underline" }) {
                    Image(systemName: "underline")
                }
                Button(action: { activeCommand = "strikeThrough" }) {
                    Image(systemName: "strikethrough")
                }
                
                Divider().frame(height: 18)
                
                Button(action: {
                    linkURL = ""
                    showLinkAlert = true
                }) {
                    Image(systemName: "link")
                }
                
                Divider().frame(height: 18)
                
                Button(action: { activeCommand = "insertUnorderedList" }) {
                    Image(systemName: "list.bullet")
                }
                Button(action: { activeCommand = "insertOrderedList" }) {
                    Image(systemName: "list.number")
                }
                Button(action: { activeCommand = "formatBlock:blockquote" }) {
                    Image(systemName: "text.quote")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
            .foregroundColor(.primary)
            .font(.system(size: 14))
        }
        .alert("Link Ekle", isPresented: $showLinkAlert) {
            TextField("URL", text: $linkURL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            Button("İptal", role: .cancel) {}
            Button("Ekle") {
                if !linkURL.isEmpty {
                    activeCommand = "createLink:\(linkURL)"
                }
            }
        } message: {
            Text("Seçili kelimeye bağlanacak link adresini girin:")
        }
    }
}

// MARK: - Holiday Item Model
struct HolidayItem: Identifiable, Codable {
    var id: String { "holiday-\(date)-\(title)" }
    let date: String
    let title: String
    
    enum CodingKeys: String, CodingKey {
        case date
        case title = "localName"
    }
}

// MARK: - Note Tag Item Model
struct NoteTagItem: Identifiable, Codable {
    let id: String
    let name: String
    let color: String?
    let visible: Bool?
    let imageUrl: String?
    let useCollage: Bool?
    let order: Int?
}

// MARK: - Note Image View
struct NoteImageView: View {
    let urlString: String?
    
    var body: some View {
        if let urlString = urlString, !urlString.isEmpty {
            if urlString.starts(with: "data:image") {
                let base64 = urlString.components(separatedBy: ",").last ?? ""
                if let data = Data(base64Encoded: base64), let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    defaultPlaceholder
                }
            } else if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        defaultPlaceholder
                    }
                }
            } else {
                defaultPlaceholder
            }
        } else {
            defaultPlaceholder
        }
    }
    
    private var defaultPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: "photo")
                .foregroundColor(.gray.opacity(0.4))
                .font(.system(size: 14))
        }
    }
}

// MARK: - Tag Collage View
struct TagCollageView: View {
    let images: [String]
    
    var body: some View {
        if images.isEmpty {
            LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else if images.count == 1 {
            NoteImageView(urlString: images[0])
        } else {
            let showImages = Array(images.prefix(4))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 2), spacing: 2) {
                ForEach(0..<4) { index in
                    if index < showImages.count {
                        NoteImageView(urlString: showImages[index])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
}

// MARK: - Tag Card View
struct TagCardView: View {
    let tagName: String
    let noteCount: Int
    let images: [String]
    let isSelected: Bool
    let lastUpdated: String?
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    TagCollageView(images: images)
                        .frame(width: 170, height: 250) // Fixed card width for horizontal scrolling
                        .clipped()
                        .cornerRadius(14)
                    
                    // Label overlay
                    VStack {
                        Text(tagName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.85))
                            .cornerRadius(6)
                            .padding(.bottom, 6)
                        
                        Text("\(noteCount) Not")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black.opacity(0.8)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                
                // Top-left relative time badge
                if let relativeTime = lastUpdated {
                    Text(relativeTime)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(6)
                        .padding(.top, 10)
                        .padding(.leading, 10)
                }
            }
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
            )
            .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.black.opacity(0.12), radius: isSelected ? 10 : 6, x: 0, y: 4)
        }
    }
}

// MARK: - Tag Settings Sheet View
struct TagSettingsSheetView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var tags: [NoteTagItem]
    @Binding var hiddenTags: [String]
    
    var body: some View {
        NavigationView {
            List {
                ForEach(tags) { tag in
                    HStack {
                        Text(tag.name)
                            .font(.system(size: 16, weight: .medium))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !hiddenTags.contains(tag.name) },
                            set: { isVisible in
                                updateTagVisibility(tagName: tag.name, isVisible: isVisible)
                            }
                        ))
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Etiket Ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Tamam") { dismiss() }
                }
            }
        }
    }
    
    private func updateTagVisibility(tagName: String, isVisible: Bool) {
        guard let user = Auth.auth().currentUser else { return }
        let db = Firestore.firestore()
        let ref = db.collection("users").document(user.uid).collection("config").document("notesSettings")
        
        var nextHidden = hiddenTags
        if isVisible {
            nextHidden.removeAll { $0 == tagName }
        } else {
            if !nextHidden.contains(tagName) {
                nextHidden.append(tagName)
            }
        }
        
        // Update local state immediately for fast feedback
        self.hiddenTags = nextHidden
        
        ref.setData(["hiddenTags": nextHidden], merge: true)
    }
}

// MARK: - Tag Card Wrapper View
struct TagCardWrapperView: View {
    let tag: NoteTagItem
    let notes: [NoteItem]
    let isSelected: Bool
    let lastUpdated: String?
    
    var body: some View {
        let tagNotes = notes.filter { ($0.tags ?? []).contains(tag.name) && $0.deleted != true }
            .sorted { (n1, n2) -> Bool in
                let date1 = n1.createdAt ?? n1.parsedDate ?? Date.distantPast
                let date2 = n2.createdAt ?? n2.parsedDate ?? Date.distantPast
                return date1 > date2
            }
        let rawImages = tagNotes.compactMap { $0.imageUrl }.filter { !$0.isEmpty }
        
        let uniqueImages: [String] = {
            var images: [String] = []
            var seen = Set<String>()
            for img in rawImages {
                if !seen.contains(img) {
                    seen.insert(img)
                    images.append(img)
                }
            }
            return images
        }()
        
        return TagCardView(
            tagName: tag.name,
            noteCount: tagNotes.count,
            images: uniqueImages,
            isSelected: isSelected,
            lastUpdated: lastUpdated
        )
    }
}

