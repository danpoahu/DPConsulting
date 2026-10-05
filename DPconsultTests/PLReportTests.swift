//
//  PLReportTests.swift
//  DPconsultTests
//

import Testing
import Foundation
@testable import DPconsult

struct PLReportTests {
    let cal: Calendar

    init() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        cal = c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func monthCoversFirstToLastSecond() {
        let feb = PLPeriod.month(year: 2026, month: 2, calendar: cal)
        #expect(feb.start == cal.date(from: DateComponents(year: 2026, month: 2, day: 1))!)
        #expect(cal.component(.day, from: feb.end) == 28)
        #expect(cal.component(.hour, from: feb.end) == 23)
        #expect(feb.label == "February 2026")
    }

    @Test func decemberRollsIntoNextYear() {
        let dec = PLPeriod.month(year: 2025, month: 12, calendar: cal)
        #expect(cal.component(.year, from: dec.end) == 2025)
        #expect(cal.component(.day, from: dec.end) == 31)
    }

    @Test func ytdCurrentYearEndsToday() {
        let now = date(2026, 10, 5, 9)
        let ytd = PLPeriod.ytd(year: 2026, asOf: now, calendar: cal)
        #expect(ytd.start == cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
        #expect(ytd.end == now)
        #expect(ytd.label == "2026 Year to Date")
    }

    @Test func ytdPastYearIsFullYear() {
        let ytd = PLPeriod.ytd(year: 2025, asOf: date(2026, 10, 5), calendar: cal)
        #expect(cal.component(.month, from: ytd.end) == 12)
        #expect(cal.component(.day, from: ytd.end) == 31)
        #expect(ytd.label == "2025 Full Year")
    }

    @Test func eachMonthStopsAtCurrentMonth() {
        let now = date(2026, 10, 5)
        #expect(PLPeriod.months(in: 2026, asOf: now, calendar: cal).count == 10)
        #expect(PLPeriod.months(in: 2025, asOf: now, calendar: cal).count == 12)
        #expect(PLPeriod.months(in: 2027, asOf: now, calendar: cal).isEmpty)
    }

    @Test func incomeIsBilledInvoicesOnly() {
        let sep = PLPeriod.month(year: 2026, month: 9, calendar: cal)
        let figures: [PLIncome.InvoiceFigure] = [
            .init(issueDate: date(2026, 9, 8), status: "sent", amount: 900),
            .init(issueDate: date(2026, 9, 8), status: "Paid", amount: 110),
            .init(issueDate: date(2026, 9, 10), status: "draft", amount: 5000),   // quote
            .init(issueDate: date(2026, 9, 11), status: "void", amount: 300),
            .init(issueDate: date(2026, 9, 25), status: "billable", amount: 75),  // in progress, not invoiced
        ]
        // Sep 2026 = LDAH #2073 $900 + Marie Borders #2074 $110
        #expect(PLIncome.income(figures, in: sep) == 1010)
    }

    @Test func incomeRespectsMonthEdges() {
        let sep = PLPeriod.month(year: 2026, month: 9, calendar: cal)
        let figures: [PLIncome.InvoiceFigure] = [
            .init(issueDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!, status: "sent", amount: 1),
            .init(issueDate: cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 59))!, status: "sent", amount: 2),
            .init(issueDate: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, status: "sent", amount: 4),
            .init(issueDate: cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23))!, status: "sent", amount: 8),
        ]
        #expect(PLIncome.income(figures, in: sep) == 3)
    }

    @Test func invoiceTotalUsesLargestFigure() {
        #expect(PLIncome.invoiceTotal(total: 100, subtotal: 100, tax: 0, itemsSum: 120) == 120)
        #expect(PLIncome.invoiceTotal(total: 150, subtotal: 100, tax: 5, itemsSum: 100) == 150)
    }
}
