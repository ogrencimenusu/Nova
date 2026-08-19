//
//  NoteCardRow.swift
//  Nova
//

import SwiftUI

public struct NoteCardRow: View {
    public let note: NoteItem
    public var showDate: Bool = false

    public init(note: NoteItem, showDate: Bool = false) {
        self.note = note
        self.showDate = showDate
    }

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
    
    public var body: some View {
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
