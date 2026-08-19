//
//  NoteModels.swift
//  Nova
//

import Foundation
import SwiftUI
import FirebaseFirestore

// MARK: - Note Item Model

public struct NoteItem: Codable, Identifiable {
    @DocumentID public var id: String?
    public var title: String?
    public var text: String?
    public var content: String?
    public var date: String? // "YYYY-MM-DD"
    public var time: String?
    public var color: String?
    public var deleted: Bool?
    public var createdAt: Date?
    public var tags: [String]?
    public var itemType: String?
    public var isRecurring: Bool?
    public var recurringGroupId: String?
    public var imageUrl: String?
    
    public init(
        id: String? = nil,
        title: String? = nil,
        text: String? = nil,
        content: String? = nil,
        date: String? = nil,
        time: String? = nil,
        color: String? = nil,
        deleted: Bool? = nil,
        createdAt: Date? = nil,
        tags: [String]? = nil,
        itemType: String? = nil,
        isRecurring: Bool? = nil,
        recurringGroupId: String? = nil,
        imageUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.content = content
        self.date = date
        self.time = time
        self.color = color
        self.deleted = deleted
        self.createdAt = createdAt
        self.tags = tags
        self.itemType = itemType
        self.isRecurring = isRecurring
        self.recurringGroupId = recurringGroupId
        self.imageUrl = imageUrl
    }

    public var displayContent: String? {
        if let t = text, !t.strippedHTML.isEmpty { return t }
        if let c = content, !c.strippedHTML.isEmpty { return c }
        return nil
    }

    public var parsedDate: Date? {
        guard let dateString = date, !dateString.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }

    public var isPastNote: Bool {
        guard let pDate = parsedDate else { return false }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfNoteDate = Calendar.current.startOfDay(for: pDate)
        return startOfNoteDate < startOfToday
    }

    public var colorHex: String {
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

public struct MonthDay: Identifiable {
    public var id: String { date.description }
    public let date: Date
    public let isCurrentMonth: Bool
    
    public init(date: Date, isCurrentMonth: Bool) {
        self.date = date
        self.isCurrentMonth = isCurrentMonth
    }
}

// MARK: - Holiday Item Model

public struct HolidayItem: Identifiable, Codable {
    public var id: String { "holiday-\(date)-\(title)" }
    public let date: String
    public let title: String
    
    enum CodingKeys: String, CodingKey {
        case date
        case title = "localName"
    }
    
    public init(date: String, title: String) {
        self.date = date
        self.title = title
    }
}

// MARK: - Note Tag Item Model

public struct NoteTagItem: Identifiable, Codable {
    public let id: String
    public let name: String
    public let color: String?
    public let visible: Bool?
    public let imageUrl: String?
    public let useCollage: Bool?
    public let order: Int?
    
    public init(id: String, name: String, color: String? = nil, visible: Bool? = nil, imageUrl: String? = nil, useCollage: Bool? = nil, order: Int? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.visible = visible
        self.imageUrl = imageUrl
        self.useCollage = useCollage
        self.order = order
    }
}
