//
//  BKPLReport.swift
//  DPconsult
//
//  Period maths and income rules for the Profit & Loss report (Reports tab):
//  any single month, each month of a year side by side, or calendar YTD.
//  Pure — no SwiftData — so it is covered by Swift Testing.
//
//  CASH BASIS (Daniel, 2026-10-05): income is counted in the month the money
//  was received (Payment received entries), not the invoice date. Expenses come
//  from the journal via BKCalculator.profitAndLoss(start:end:) and are entered on
//  the date they were paid, so both sides are cash basis.
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

/// Cash-basis income: money received in the period.
///
/// A journal entry counts when it debits Cash and credits Accounts Receivable
/// (a payment against an invoice) or an income account (a direct sale). The
/// amount is the Cash debit. Owner deposits (credit Owners Equity) and transfers
/// are not income. Expenses are already recorded on the date they were paid.
enum PLIncome {
    struct Line: Sendable {
        enum Kind: Sendable { case cash, receivable, income, other }
        let kind: Kind
        let debit: Double
        let credit: Double
    }

    struct Entry: Sendable {
        let date: Date
        let lines: [Line]
    }

    static func cashReceived(_ entries: [Entry], in period: PLPeriod) -> Double {
        entries.reduce(0) { sum, entry in
            guard entry.date >= period.start, entry.date <= period.end,
                  entry.lines.contains(where: { ($0.kind == .receivable || $0.kind == .income) && $0.credit > 0 })
            else { return sum }
            return sum + entry.lines.filter { $0.kind == .cash }.reduce(0) { $0 + $1.debit - $1.credit }
        }
    }
}
