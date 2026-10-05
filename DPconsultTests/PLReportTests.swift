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

    private func payment(_ d: Date, _ amt: Double) -> PLIncome.Entry {
        .init(date: d, lines: [.init(kind: .cash, debit: amt, credit: 0), .init(kind: .receivable, debit: 0, credit: amt)])
    }

    @Test func cashBasisCountsPaymentInMonthReceived() {
        // LDAH #2073: August work, invoiced Sep 8, paid Oct 3 -> October income
        let entries: [PLIncome.Entry] = [
            .init(date: date(2026, 9, 8), lines: [.init(kind: .receivable, debit: 900, credit: 0), .init(kind: .income, debit: 0, credit: 900)]),
            payment(date(2026, 10, 3), 900),
        ]
        #expect(PLIncome.cashReceived(entries, in: .month(year: 2026, month: 9, calendar: cal)) == 0)
        #expect(PLIncome.cashReceived(entries, in: .month(year: 2026, month: 10, calendar: cal)) == 900)
    }

    @Test func cashBasisIgnoresOwnerDepositsAndExpenses() {
        let entries: [PLIncome.Entry] = [
            .init(date: date(2026, 9, 1), lines: [.init(kind: .cash, debit: 10_000, credit: 0), .init(kind: .other, debit: 0, credit: 10_000)]),  // owner
            .init(date: date(2026, 9, 21), lines: [.init(kind: .other, debit: 70, credit: 0), .init(kind: .cash, debit: 0, credit: 70)]),           // Spectrum
            payment(date(2026, 9, 15), 110),
        ]
        #expect(PLIncome.cashReceived(entries, in: .month(year: 2026, month: 9, calendar: cal)) == 110)
    }

    @Test func cashBasisCountsDirectSales() {
        let sale = PLIncome.Entry(date: date(2026, 3, 2), lines: [.init(kind: .cash, debit: 50, credit: 0), .init(kind: .income, debit: 0, credit: 50)])
        #expect(PLIncome.cashReceived([sale], in: .ytd(year: 2026, asOf: date(2026, 10, 5), calendar: cal)) == 50)
    }

    @Test func cashBasisRespectsMonthEdges() {
        let entries = [payment(cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!, 1),
                       payment(cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 59))!, 2),
                       payment(cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, 4),
                       payment(cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23))!, 8)]
        #expect(PLIncome.cashReceived(entries, in: .month(year: 2026, month: 9, calendar: cal)) == 3)
    }
}
