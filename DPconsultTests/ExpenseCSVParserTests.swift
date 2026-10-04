//
//  ExpenseCSVParserTests.swift
//  DPconsultTests
//

import Testing
import Foundation
@testable import DPconsult

struct ExpenseCSVParserTests {
    let cal: Calendar

    init() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        cal = c
    }

    @Test func parsesRowsAndRoundsToCents() throws {
        let csv = """
        date,account,amount,memo
        2026-04-21,Software & Subscriptions,104.71,[General] Claude Max - Apr 2026
        2026-09-03,Software & Subscriptions,$20.944,[LDAH] Anthropic API credits
        """
        let rows = try ExpenseCSVParser.parse(csv, calendar: cal)
        #expect(rows.count == 2)
        #expect(rows[0].amount == 104.71)
        #expect(rows[1].amount == 20.94)
        #expect(rows[0].account == "Software & Subscriptions")
        #expect(rows[1].memo == "[LDAH] Anthropic API credits")
        #expect(cal.component(.hour, from: rows[0].date) == 12)
        #expect(cal.component(.day, from: rows[0].date) == 21)
    }

    @Test func columnsInAnyOrderAndQuotedCommas() throws {
        let csv = "memo,amount,date,account\n\"Spectrum, Jan 2026\",70,2026-01-21,Internet & Utilities\n"
        let rows = try ExpenseCSVParser.parse(csv, calendar: cal)
        #expect(rows.count == 1)
        #expect(rows[0].memo == "Spectrum, Jan 2026")
        #expect(rows[0].amount == 70)
    }

    @Test func handlesWindowsLineEndingsAndBlankLines() throws {
        let csv = "date,account,amount,memo\r\n\r\n2026-02-21,Software & Subscriptions,90.33,Upgrade\r\n"
        #expect(try ExpenseCSVParser.parse(csv, calendar: cal).count == 1)
    }

    @Test func rejectsMissingColumns() {
        #expect(throws: ExpenseImportError.missingColumns(["memo"])) {
            try ExpenseCSVParser.parse("date,account,amount\n2026-01-01,X,1", calendar: cal)
        }
    }

    @Test func rejectsBadDate() {
        #expect(throws: ExpenseImportError.badDate(line: 2, value: "2026-02-30")) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n2026-02-30,X,1,m", calendar: cal)
        }
    }

    @Test func rejectsZeroOrTextAmount() {
        #expect(throws: ExpenseImportError.badAmount(line: 2, value: "0")) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n2026-01-01,X,0,m", calendar: cal)
        }
        #expect(throws: ExpenseImportError.badAmount(line: 2, value: "abc")) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n2026-01-01,X,abc,m", calendar: cal)
        }
    }

    @Test func rejectsEmptyMemoAndWrongFieldCount() {
        #expect(throws: ExpenseImportError.missingField(line: 2, field: "memo")) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n2026-01-01,X,5, ", calendar: cal)
        }
        #expect(throws: ExpenseImportError.wrongFieldCount(line: 2, expected: 4, found: 3)) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n2026-01-01,X,5", calendar: cal)
        }
    }

    @Test func rejectsHeaderOnly() {
        #expect(throws: ExpenseImportError.empty) {
            try ExpenseCSVParser.parse("date,account,amount,memo\n", calendar: cal)
        }
    }
}
