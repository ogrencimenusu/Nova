//
//  FinanceModels.swift
//  Nova
//

import SwiftUI
import FirebaseFirestore

// MARK: - Finance Models

public struct FinanceInstitutionItem: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var logo: String
    public var visible: Bool
    public var order: Int
    public var deleted: Bool
    
    public init(id: String, name: String, logo: String, visible: Bool, order: Int, deleted: Bool) {
        self.id = id
        self.name = name
        self.logo = logo
        self.visible = visible
        self.order = order
        self.deleted = deleted
    }
}

public struct FinanceStockItem: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var currentPrice: Double
    public var previousPrice: Double
    public var dailyChange: Double
    public var updatedAt: Date?
    public var createdAt: Date?
    
    public init(id: String, name: String, currentPrice: Double, previousPrice: Double, dailyChange: Double, updatedAt: Date? = nil, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.currentPrice = currentPrice
        self.previousPrice = previousPrice
        self.dailyChange = dailyChange
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

public struct FinanceTransactionItem: Identifiable, Codable, Equatable {
    public var id: String
    public var institutionId: String
    public var stockId: String
    public var type: String
    public var quantity: Double
    public var price: Double
    public var taxRate: Double
    public var date: String
    public var remainingQuantity: Double
    public var deleted: Bool
    public var createdAt: Date?
    
    public init(id: String, institutionId: String, stockId: String, type: String, quantity: Double, price: Double, taxRate: Double, date: String, remainingQuantity: Double, deleted: Bool, createdAt: Date? = nil) {
        self.id = id
        self.institutionId = institutionId
        self.stockId = stockId
        self.type = type
        self.quantity = quantity
        self.price = price
        self.taxRate = taxRate
        self.date = date
        self.remainingQuantity = remainingQuantity
        self.deleted = deleted
        self.createdAt = createdAt
    }
}

public struct ProcessedFinanceLot: Identifiable {
    public var id: String
    public var institutionId: String
    public var stockId: String
    public var type: String
    public var quantity: Double
    public var price: Double
    public var taxRate: Double
    public var date: String
    public var runningBalance: Double
    public var calculatedRemaining: Double
    public var calculatedTaxDeduction: Double
    public var totalBuyAmount: Double
    public var totalSaleAmount: Double
    public var grossProfit: Double
    public var totalProfit: Double
    public var costBasis: Double
    public var profitPercentage: Double
    public var holdingDurationDays: Int
    public var avgBuyPrice: Double
    public var createdAt: Date?
    
    public init(id: String, institutionId: String, stockId: String, type: String, quantity: Double, price: Double, taxRate: Double, date: String, runningBalance: Double, calculatedRemaining: Double, calculatedTaxDeduction: Double, totalBuyAmount: Double, totalSaleAmount: Double, grossProfit: Double, totalProfit: Double, costBasis: Double, profitPercentage: Double, holdingDurationDays: Int, avgBuyPrice: Double, createdAt: Date? = nil) {
        self.id = id
        self.institutionId = institutionId
        self.stockId = stockId
        self.type = type
        self.quantity = quantity
        self.price = price
        self.taxRate = taxRate
        self.date = date
        self.runningBalance = runningBalance
        self.calculatedRemaining = calculatedRemaining
        self.calculatedTaxDeduction = calculatedTaxDeduction
        self.totalBuyAmount = totalBuyAmount
        self.totalSaleAmount = totalSaleAmount
        self.grossProfit = grossProfit
        self.totalProfit = totalProfit
        self.costBasis = costBasis
        self.profitPercentage = profitPercentage
        self.holdingDurationDays = holdingDurationDays
        self.avgBuyPrice = avgBuyPrice
        self.createdAt = createdAt
    }
}

public struct PortfolioItem: Identifiable {
    public var id: String
    public var name: String
    public var currentPrice: Double
    public var previousPrice: Double
    public var dailyChange: Double
    public var quantity: Double
    public var totalCost: Double
    public var avgPrice: Double
    public var totalGrossProfit: Double
    public var totalTaxDeduction: Double
    public var totalProfit: Double
    public var profitPercentage: Double
    public var holdingDurationDays: Int
    public var dailyGain: Double
    public var institutionBreakdown: [String: Double]
    public var updatedAt: Date?
    
    public init(id: String, name: String, currentPrice: Double, previousPrice: Double, dailyChange: Double, quantity: Double, totalCost: Double, avgPrice: Double, totalGrossProfit: Double, totalTaxDeduction: Double, totalProfit: Double, profitPercentage: Double, holdingDurationDays: Int, dailyGain: Double, institutionBreakdown: [String : Double], updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.currentPrice = currentPrice
        self.previousPrice = previousPrice
        self.dailyChange = dailyChange
        self.quantity = quantity
        self.totalCost = totalCost
        self.avgPrice = avgPrice
        self.totalGrossProfit = totalGrossProfit
        self.totalTaxDeduction = totalTaxDeduction
        self.totalProfit = totalProfit
        self.profitPercentage = profitPercentage
        self.holdingDurationDays = holdingDurationDays
        self.dailyGain = dailyGain
        self.institutionBreakdown = institutionBreakdown
        self.updatedAt = updatedAt
    }
}

public struct InstitutionStats {
    public var unrealizedGross: Double = 0
    public var unrealizedNet: Double = 0
    public var totalInvestment: Double = 0
    public var currentValue: Double = 0
    public var dailyGain: Double = 0
    public var realizedGross: Double = 0
    public var realizedNet: Double = 0
    
    public init(unrealizedGross: Double = 0, unrealizedNet: Double = 0, totalInvestment: Double = 0, currentValue: Double = 0, dailyGain: Double = 0, realizedGross: Double = 0, realizedNet: Double = 0) {
        self.unrealizedGross = unrealizedGross
        self.unrealizedNet = unrealizedNet
        self.totalInvestment = totalInvestment
        self.currentValue = currentValue
        self.dailyGain = dailyGain
        self.realizedGross = realizedGross
        self.realizedNet = realizedNet
    }
}

public struct AnalysisItem: Identifiable {
    public var id: String
    public var name: String
    public var logo: String
    public var value: Double
    public var cost: Double
    public var profit: Double
    public var tax: Double
    public var quantity: Double
    public var dailyGain: Double
    public var percentage: Double
    public var isActive: Bool
    public var color: Color
    
    public init(id: String, name: String, logo: String, value: Double, cost: Double, profit: Double, tax: Double, quantity: Double, dailyGain: Double, percentage: Double, isActive: Bool, color: Color) {
        self.id = id
        self.name = name
        self.logo = logo
        self.value = value
        self.cost = cost
        self.profit = profit
        self.tax = tax
        self.quantity = quantity
        self.dailyGain = dailyGain
        self.percentage = percentage
        self.isActive = isActive
        self.color = color
    }
}
