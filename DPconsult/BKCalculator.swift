//
//  BKCalculator.swift
//  DPconsult
//
//  Bookkeeping calculation logic extracted from BKBookStore.
//  Pure functions operating on SDAccount and SDJournalEntry arrays.
//

import Foundation
import SwiftData

// MARK: - Account Type Enum (shared across app)

enum BKAccountType: String, CaseIterable, Identifiable, Codable {
    case asset
    case liability
    case equity
    case income
    case expense

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asset: return "Asset"
        case .liability: return "Liability"
        case .equity: return "Equity"
        case .income: return "Income"
        case .expense: return "Expense"
        }
    }
}

// MARK: - Calculator

struct BKCalculator {
    let accounts: [SDAccount]
    let entries: [SDJournalEntry]

    // Balance for an account: assets/expenses increase with debit, others with credit
    func balance(for accountId: UUID) -> Double {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return 0 }
        var balance: Double = 0
        for entry in entries {
            for line in (entry.lines ?? []) where line.accountId == accountId {
                switch account.type {
                case .asset, .expense:
                    balance += line.debit - line.credit
                case .liability, .equity, .income:
                    balance += line.credit - line.debit
                }
            }
        }
        return balance
    }

    func balanceSheetDetailed() -> (assets: [(SDAccount, Double)], liabilities: [(SDAccount, Double)], equity: [(SDAccount, Double)], totals: (assets: Double, liabilities: Double, equity: Double), retainedEarnings: Double) {
        let assets = accounts.filter { $0.type == .asset }.map { ($0, balance(for: $0.id)) }
        let liabilities = accounts.filter { $0.type == .liability }.map { ($0, balance(for: $0.id)) }
        let equityAccounts = accounts.filter { $0.type == .equity }.map { ($0, balance(for: $0.id)) }

        let tAssets = assets.reduce(0) { $0 + $1.1 }
        let tLiab = liabilities.reduce(0) { $0 + $1.1 }
        let retained = retainedEarnings()
        let tEquityAccounts = equityAccounts.reduce(0) { $0 + $1.1 }
        let tEquity = tEquityAccounts + retained

        return (assets, liabilities, equityAccounts, (tAssets, tLiab, tEquity), retained)
    }

    func balanceSheet() -> (assets: [(SDAccount, Double)], liabilities: [(SDAccount, Double)], equity: [(SDAccount, Double)]) {
        let assets = accounts.filter { $0.type == .asset }.map { ($0, balance(for: $0.id)) }
        let liabilities = accounts.filter { $0.type == .liability }.map { ($0, balance(for: $0.id)) }
        let equity = accounts.filter { $0.type == .equity }.map { ($0, balance(for: $0.id)) }
        return (assets, liabilities, equity)
    }

    func profitAndLoss(start: Date, end: Date) -> (income: [(SDAccount, Double)], expenses: [(SDAccount, Double)], net: Double) {
        let filteredEntries = entries.filter { $0.date >= start && $0.date <= end }
        let incomeAccounts = accounts.filter { $0.type == .income }
        let expenseAccounts = accounts.filter { $0.type == .expense }

        func sumFor(accounts: [SDAccount]) -> [(SDAccount, Double)] {
            accounts.map { account in
                var balance: Double = 0
                for entry in filteredEntries {
                    for line in (entry.lines ?? []) where line.accountId == account.id {
                        switch account.type {
                        case .income:
                            balance += line.credit - line.debit
                        case .expense:
                            balance += line.debit - line.credit
                        default:
                            break
                        }
                    }
                }
                return (account, balance)
            }
        }

        let income = sumFor(accounts: incomeAccounts)
        let expenses = sumFor(accounts: expenseAccounts)
        let totalIncome = income.reduce(0) { $0 + $1.1 }
        let totalExpenses = expenses.reduce(0) { $0 + $1.1 }

        return (income, expenses, totalIncome - totalExpenses)
    }

    func retainedEarnings(until end: Date? = nil) -> Double {
        let start = Date.distantPast
        let endDate = end ?? Date()
        let pl = profitAndLoss(start: start, end: endDate)
        return pl.net
    }

    // Record invoice payment: Debit Cash, Credit A/R
    func recordInvoicePayment(amount: Double, date: Date, memo: String, context: ModelContext) {
        guard amount > 0 else { return }

        let cashId = findOrCreateAccount(name: "Cash", type: .asset, context: context)
        let arId = findOrCreateAccount(name: "Accounts Receivable", type: .asset, context: context)

        let entry = SDJournalEntry(date: date, memo: memo)
        context.insert(entry)

        let debitLine = SDEntryLine(accountId: cashId, debit: amount, credit: 0, memo: "Payment received", sortOrder: 0)
        debitLine.journalEntry = entry
        context.insert(debitLine)

        let creditLine = SDEntryLine(accountId: arId, debit: 0, credit: amount, memo: "Reduce A/R", sortOrder: 1)
        creditLine.journalEntry = entry
        context.insert(creditLine)
    }

    private func findOrCreateAccount(name: String, type: BKAccountType, context: ModelContext) -> UUID {
        if let existing = accounts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.type == type }) {
            return existing.id
        }
        let account = SDAccount(name: name, type: type)
        context.insert(account)
        return account.id
    }
}
