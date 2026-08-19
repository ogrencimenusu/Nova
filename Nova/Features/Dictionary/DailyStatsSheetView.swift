//
//  DailyStatsSheetView.swift
//  Nova
//

import SwiftUI

public struct DailyStatsSheetView: View {
    @Environment(\.dismiss) var dismiss
    public let dailyStatsMap: [String: Any]
    public let allWords: [LocalWord]
    
    @State private var viewMode: String = "daily" // "daily" | "monthly"
    @State private var selectedDate: Date = Date()
    @State private var calendarMonth: Date = Date()
    
    public init(dailyStatsMap: [String : Any], allWords: [LocalWord]) {
        self.dailyStatsMap = dailyStatsMap
        self.allWords = allWords
    }
    
    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    
    private var selectedDateStr: String {
        dateFormatter.string(from: selectedDate)
    }
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // View Mode Toggle (Günlük Detay vs Aylık Takvim)
                HStack(spacing: 0) {
                    Button(action: { withAnimation { viewMode = "daily" } }) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.clipboard.fill")
                            Text("Günlük Detay")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(viewMode == "daily" ? Color.blue : Color.clear)
                        .foregroundColor(viewMode == "daily" ? .white : .primary)
                        .cornerRadius(20)
                    }
                    
                    Button(action: { withAnimation { viewMode = "monthly" } }) {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                            Text("Aylık Takvim")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(viewMode == "monthly" ? Color.blue : Color.clear)
                        .foregroundColor(viewMode == "monthly" ? .white : .primary)
                        .cornerRadius(20)
                    }
                }
                .padding(4)
                .background(Color.black.opacity(0.05))
                .cornerRadius(24)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
                if viewMode == "daily" {
                    dailyDetailView
                } else {
                    monthlyCalendarView
                }
            }
            .navigationTitle("Seri ve İstatistikler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                }
            }
        }
    }
    
    private var dailyDetailView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // Date Navigator Row
                HStack {
                    Button(action: {
                        if let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) {
                            selectedDate = prev
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .foregroundColor(.blue)
                        Text(selectedDate.formatted(date: .complete, time: .omitted))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        if let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) {
                            selectedDate = next
                        }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                let statsData = dailyStatsMap[selectedDateStr] as? [String: Any] ?? [:]
                let correctCount = (statsData["correctCount"] as? NSNumber)?.intValue ?? (statsData["correctCount"] as? Int ?? 0)
                let wrongCount = statsData["wrongCount"] as? Int ?? 0
                let totalCount = correctCount + wrongCount
                let accuracy = totalCount > 0 ? Int(Double(correctCount) / Double(totalCount) * 100) : 0
                
                // 4 Metric Cards Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metricCard(title: "ÇÖZÜLEN SORU", value: "\(totalCount)", icon: "number", color: .blue)
                    metricCard(title: "DOĞRU CEVAP", value: "\(correctCount)", icon: "checkmark.circle.fill", color: .green)
                    metricCard(title: "YANLIŞ CEVAP", value: "\(wrongCount)", icon: "xmark.circle.fill", color: .red)
                    metricCard(title: "BAŞARI ORANI", value: "%\(accuracy)", icon: "chart.line.uptrend.xyaxis", color: .purple)
                }
                .padding(.horizontal, 16)
                
                if totalCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Bu tarihte herhangi bir test çözülmemiş.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ÇALIŞILAN KELİMELER")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                        
                        if let wordsMap = statsData["words"] as? [String: Any] {
                            ForEach(Array(wordsMap.keys).sorted(), id: \.self) { wKey in
                                let item = wordsMap[wKey] as? [String: Any] ?? [:]
                                let c = item["correct"] as? Int ?? 0
                                let w = item["incorrect"] as? Int ?? 0
                                let wordTerm = item["term"] as? String ?? (allWords.first(where: { $0.id == wKey })?.term ?? wKey)
                                
                                HStack {
                                    Text(wordTerm)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Spacer()
                                    HStack(spacing: 12) {
                                        if c > 0 {
                                            Text("\(c) Doğru")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.green)
                                        }
                                        if w > 0 {
                                            Text("\(w) Yanlış")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.white)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
    }
    
    private var monthlyCalendarView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // Month Navigator Row
                HStack {
                    Button(action: {
                        if let prev = Calendar.current.date(byAdding: .month, value: -1, to: calendarMonth) {
                            calendarMonth = prev
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    Text(calendarMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    
                    Spacer()
                    
                    Button(action: {
                        if let next = Calendar.current.date(byAdding: .month, value: 1, to: calendarMonth) {
                            calendarMonth = next
                        }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // Days of week header
                HStack {
                    ForEach(["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"], id: \.self) { day in
                        Text(day)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                
                // Calendar Grid
                let days = getDaysInMonth(calendarMonth)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, dateOpt in
                        if let date = dateOpt {
                            let key = dateFormatter.string(from: date)
                            let stats = dailyStatsMap[key] as? [String: Any] ?? [:]
                            let correct = (stats["correctCount"] as? NSNumber)?.intValue ?? (stats["correctCount"] as? Int ?? 0)
                            let isStreak = correct >= 100
                            let dayNum = Calendar.current.component(.day, from: date)
                            
                            VStack(spacing: 2) {
                                Text("\(dayNum)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(isStreak ? .white : .primary)
                                
                                if isStreak {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                } else if correct > 0 {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 4, height: 4)
                                }
                            }
                            .frame(height: 42)
                            .frame(maxWidth: .infinity)
                            .background(
                                Group {
                                    if isStreak {
                                        LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom)
                                    } else if correct > 0 {
                                        Color.orange.opacity(0.12)
                                    } else {
                                        Color.black.opacity(0.02)
                                    }
                                }
                            )
                            .cornerRadius(10)
                            .onTapGesture {
                                selectedDate = date
                                withAnimation { viewMode = "daily" }
                            }
                        } else {
                            Color.clear
                                .frame(height: 42)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder
    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.03), lineWidth: 1)
        )
    }
    
    private func getDaysInMonth(_ monthDate: Date) -> [Date?] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthDate)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }
        
        let weekday = cal.component(.weekday, from: firstDay) // 1 = Sun, 2 = Mon ...
        let offset = (weekday == 1 ? 6 : weekday - 2) // Mon = 0
        
        var result: [Date?] = Array(repeating: nil, count: offset)
        for day in 1...range.count {
            if let date = cal.date(byAdding: .day, value: day - 1, to: firstDay) {
                result.append(date)
            }
        }
        return result
    }
}
