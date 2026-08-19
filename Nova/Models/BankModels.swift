//
//  BankModels.swift
//  Nova
//

import Foundation
import SwiftUI

// MARK: - Bank Data Models

public struct BankItem: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var logo: String
    public var visible: Bool
    public var order: Int
    public var deleted: Bool
    public var balance: Double = 0.0
    
    public init(id: String, name: String, logo: String, visible: Bool, order: Int, deleted: Bool, balance: Double = 0.0) {
        self.id = id
        self.name = name
        self.logo = logo
        self.visible = visible
        self.order = order
        self.deleted = deleted
        self.balance = balance
    }
}

public struct BankTransactionItem: Identifiable, Codable, Equatable {
    public var id: String
    public var bankId: String
    public var title: String
    public var quickActions: [String]
    public var type: String
    public var amount: Double
    public var date: String
    public var createdAt: Date?
    public var deleted: Bool
    public var receiptUrl: String?
    
    public init(id: String, bankId: String, title: String, quickActions: [String], type: String, amount: Double, date: String, createdAt: Date? = nil, deleted: Bool, receiptUrl: String? = nil) {
        self.id = id
        self.bankId = bankId
        self.title = title
        self.quickActions = quickActions
        self.type = type
        self.amount = amount
        self.date = date
        self.createdAt = createdAt
        self.deleted = deleted
        self.receiptUrl = receiptUrl
    }
}

public struct TagItem: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var color: String
    public var order: Int
    
    public init(id: String, name: String, color: String, order: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
    }
}

public struct TransactionGroup: Identifiable {
    public var id: String
    public var label: String
    public var color: String
    public var items: [BankTransactionItem]
    
    public var total: Double {
        items.reduce(0.0) { $0 + $1.amount }
    }
    
    public init(id: String, label: String, color: String, items: [BankTransactionItem]) {
        self.id = id
        self.label = label
        self.color = color
        self.items = items
    }
}

public struct IdentifiableURL: Identifiable {
    public let id = UUID()
    public let url: URL
    
    public init(url: URL) {
        self.url = url
    }
}
