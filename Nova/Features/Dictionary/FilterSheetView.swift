//
//  FilterSheetView.swift
//  Nova
//

import SwiftUI

public struct FilterSheetView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var filterLanguage: String
    @Binding var filterStarredOnly: Bool
    @Binding var filterSortRules: [SortRule]
    @Binding var filterStatus: String
    @Binding var filterListId: String? // Selected Custom List filter ID
    
    public let customLists: [CustomListModel] // Loaded custom lists
    public let languages: [String]
    public let totalCount: Int
    public let languageCounts: [String: Int]
    public let starredCount: Int
    public let filteredCount: Int
    
    public init(
        filterLanguage: Binding<String>,
        filterStarredOnly: Binding<Bool>,
        filterSortRules: Binding<[SortRule]>,
        filterStatus: Binding<String>,
        filterListId: Binding<String?>,
        customLists: [CustomListModel],
        languages: [String],
        totalCount: Int,
        languageCounts: [String : Int],
        starredCount: Int,
        filteredCount: Int
    ) {
        self._filterLanguage = filterLanguage
        self._filterStarredOnly = filterStarredOnly
        self._filterSortRules = filterSortRules
        self._filterStatus = filterStatus
        self._filterListId = filterListId
        self.customLists = customLists
        self.languages = languages
        self.totalCount = totalCount
        self.languageCounts = languageCounts
        self.starredCount = starredCount
        self.filteredCount = filteredCount
    }
    
    public var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Results Count Bar at the top of the sheet
                    HStack {
                        Text("Filtrelenmiş Kelime Sayısı:")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(filteredCount) Kelime")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.06))
                    .cornerRadius(10)
                    .padding(.top, 8)
                    
                    // Section 1: Languages and Stars
                    Text("Diller & Yıldızlılar")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // Tüm Diller Button
                            filterChip(title: "Tüm Diller", count: totalCount, isSelected: filterLanguage == "all" && !filterStarredOnly) {
                                filterLanguage = "all"
                                filterStarredOnly = false
                            }
                            
                            // Dynamic Languages
                            ForEach(languages, id: \.self) { lang in
                                let count = languageCounts[lang] ?? 0
                                filterChip(title: lang.capitalized, count: count, isSelected: filterLanguage.lowercased() == lang.lowercased() && !filterStarredOnly) {
                                    filterLanguage = lang
                                    filterStarredOnly = false
                                }
                            }
                            
                            // Yıldızlılar Button
                            filterChip(title: "Yıldızlılar", count: starredCount, isSelected: filterStarredOnly) {
                                filterStarredOnly = true
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    
                    Divider()
                    
                    // Section 2: Multi-Level Sorting
                    HStack {
                        Text("Sıralama")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        Spacer()
                        
                        if !filterSortRules.isEmpty {
                            Button("Temizle") {
                                filterSortRules.removeAll()
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                        }
                    }
                    
                    VStack(spacing: 10) {
                        ForEach(Array(filterSortRules.enumerated()), id: \.offset) { index, rule in
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                
                                // Field Selector Menu
                                Menu {
                                    Button("Kelime (A-Z)") { updateRuleField(at: index, field: "term") }
                                    Button("Eklenme Tarihi") { updateRuleField(at: index, field: "createdAt") }
                                    Button("Öğrenim Aşaması") { updateRuleField(at: index, field: "learningStage") }
                                } label: {
                                    HStack {
                                        Text(fieldLabel(rule.field))
                                            .font(.system(size: 13, weight: .medium))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.04))
                                    .cornerRadius(8)
                                    .foregroundColor(.primary)
                                }
                                
                                Spacer()
                                
                                // Direction Selector Menu
                                Menu {
                                    Button(rule.field == "term" ? "A-Z (Artan)" : "Artan") { updateRuleDir(at: index, dir: "asc") }
                                    Button(rule.field == "term" ? "Z-A (Azalan)" : "Azalan") { updateRuleDir(at: index, dir: "desc") }
                                } label: {
                                    HStack {
                                        Text(rule.direction == "asc" ? (rule.field == "term" ? "A-Z" : "Artan") : (rule.field == "term" ? "Z-A" : "Azalan"))
                                            .font(.system(size: 13, weight: .medium))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.04))
                                    .cornerRadius(8)
                                    .foregroundColor(.primary)
                                }
                                
                                // Remove Rule Button
                                Button(action: {
                                    filterSortRules.remove(at: index)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .font(.system(size: 14))
                                }
                                .padding(.leading, 4)
                            }
                            .padding(8)
                            .background(Color.white)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
                            )
                        }
                        
                        // Dashed Button: + Yeni Kural Ekle
                        Button(action: {
                            filterSortRules.append(SortRule(field: "createdAt", direction: "desc"))
                        }) {
                            HStack {
                                Image(systemName: "plus")
                                Text("Yeni Kural Ekle")
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                    .foregroundColor(.blue.opacity(0.5))
                                    .background(Color.blue.opacity(0.02))
                            )
                        }
                    }
                    
                    Divider()
                    
                    // Section 3: Learning Status
                    Text("Öğrenim Durumu")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        statusTab(title: "Tümü", tag: "all", activeColor: .blue)
                        statusTab(title: "Yeni", tag: "yeni", activeColor: Color(hex: "3498db"))
                        statusTab(title: "Öğreniyor", tag: "ogreniyor", activeColor: Color.amber)
                        statusTab(title: "Öğrendi", tag: "ogrendi", activeColor: .green)
                    }
                    
                    Divider()
                    
                    // Section 4: Özel Listelerim
                    Text("Özel Listelerim")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // "Tüm Kelimeler" chip resets custom list filter
                            filterChip(title: "Tüm Kelimeler", count: totalCount, isSelected: filterListId == nil) {
                                filterListId = nil
                            }
                            
                            // Custom Lists chips
                            ForEach(customLists) { list in
                                filterChip(title: list.name, count: list.wordIds.count, isSelected: filterListId == list.id) {
                                    filterListId = list.id
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Filtrele & Sırala")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Tamam") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                }
            }
        }
    }
    
    private func fieldLabel(_ key: String) -> String {
        switch key {
        case "term": return "Kelime"
        case "createdAt": return "Eklenme Tarihi"
        case "learningStage": return "Öğrenim Aşaması"
        default: return "Sıralama"
        }
    }
    
    private func updateRuleField(at idx: Int, field: String) {
        if idx < filterSortRules.count {
            filterSortRules[idx].field = field
        }
    }
    
    private func updateRuleDir(at idx: Int, dir: String) {
        if idx < filterSortRules.count {
            filterSortRules[idx].direction = dir
        }
    }
    
    @ViewBuilder
    private func filterChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.black.opacity(0.06))
                    .cornerRadius(8)
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color.black.opacity(0.04))
            .cornerRadius(20)
        }
    }
    
    @ViewBuilder
    private func statusTab(title: String, tag: String, activeColor: Color) -> some View {
        Button(action: {
            filterStatus = tag
        }) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(filterStatus == tag ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(filterStatus == tag ? activeColor : Color.black.opacity(0.04))
                .cornerRadius(10)
        }
    }
}
