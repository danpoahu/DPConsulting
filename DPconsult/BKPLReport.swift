//
//  BKPLReport.swift
//  DPconsult
//
//  Period maths and income rules for the Profit & Loss report (Reports tab):
//  any single month, each month of a year side by side, or calendar YTD.
//  Pure — no SwiftData — so it is covered by Swift Testing.
//
//  Income = invoices by issue date that have been billed (Sent, Partial, Paid).
//  Quotes, Billable (work in progress, not yet invoiced) and voided invoices
//  are not income. Expenses come
//  from the journal via BKCalculator.profitAndLoss(start:end:).
//

import Foundation

enum PLPeriodMode: String, CaseIterable, Identifiable, Sendable {
    case month = "Month"
    case eachMonth = "Each Month"
    case ytd = "YTD"
    var id: String { rawValue }
}

struct PLPeriod: Equatable, Sendable {
    /// First instant of the period.
    let start: Date
    /// Last instant included (inclusive), to match BKCalculator's `date <= end`.
    let end: Date
    let label: String

    static func month(year: Int, month: Int, calendar: Calendar = .current) -> PLPeriod {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let next = calendar.date(byAdding: .month, value: 1, to: start)!
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "MMMM yyyy"
        return PLPeriod(start: start, end: next.addingTimeInterval(-1), label: fmt.string(from: start))
    }

    /// Calendar year to date: Jan 1 through `asOf` for the current year,
    /// the whole year (to Dec 31) for a past year.
    static func ytd(year: Int, asOf now: Date = Date(), calendar: Calendar = .current) -> PLPeriod {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!.addingTimeInterval(-1)
        let end = min(yearEnd, now)
        let label = end < yearEnd ? "\(year) Year to Date" : "\(year) Full Year"
        return PLPeriod(start: start, end: end, label: label)
    }

    /// The months shown in the Each Month view: Jan through the current month
    /// for this year, Jan–Dec for a past year.
    static func months(in year: Int, asOf now: Date = Date(), calendar: Calendar = .current) -> [PLPeriod] {
        let thisYear = calendar.component(.year, from: now)
        let last = year < thisYear ? 12 : (year == thisYear ? calendar.component(.month, from: now) : 0)
        guard last > 0 else { return [] }
        return (1...last).map { month(year: year, month: $0, calendar: calendar) }
    }
}

enum PLIncome {
    /// Invoice statuses that count as income: billed invoices only. "draft" is a
    /// Quote and "billable" is work in progress — neither is income yet.
    /// "invoice" is the legacy name for Sent.
    static let earnedStatuses: Set<String> = ["invoice", "sent", "partial", "paid"]

    /// Same total the app has always used: guards against an invoice whose
    /// stored total lags its items.
    static func invoiceTotal(total: Double, subtotal: Double, tax: Double, itemsSum: Double) -> Double {
        max(total, subtotal + tax, itemsSum + tax)
    }

    struct InvoiceFigure: Sendable {
        let issueDate: Date
        let status: String
        let amount: Double
    }

    static func income(_ invoices: [InvoiceFigure], in period: PLPeriod) -> Double {
        invoices.reduce(0) { sum, inv in
            guard inv.issueDate >= period.start, inv.issueDate <= period.end,
                  earnedStatuses.contains(inv.status.lowercased()) else { return sum }
            return sum + inv.amount
        }
    }
}
