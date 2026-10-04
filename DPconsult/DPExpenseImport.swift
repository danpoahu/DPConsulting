//
//  DPExpenseImport.swift
//  DPconsult
//
//  Imports a CSV of expense payments as journal entries: each row debits an
//  expense account and credits Cash. Built for back-filling monthly bills
//  (Claude subscription, API credits, internet) from their receipts.
//
//  CSV header (required, any column order):  date,account,amount,memo
//    date     yyyy-MM-dd
//    account  expense account name; created as an expense account if missing
//    amount   total actually paid, tax included, e.g. 104.71
//    memo     entry memo; tag the client here, e.g. "[LDAH] Anthropic API - Sep 2026"
//
//  Nothing is saved until Confirm. A row is skipped when an entry with the same
//  date and memo already exists, so importing the same file twice is harmless.
//  Entries go through modelContext.insert (never raw SQLite) so they sync.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Parser (pure)

struct ExpenseImportRow: Identifiable, Equatable, Sendable {
    let id = UUID()
    let line: Int
    let date: Date
    let account: String
    let amount: Double
    let memo: String

    static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.date == b.date && a.account == b.account && a.amount == b.amount && a.memo == b.memo
    }
}

enum ExpenseImportError: Error, Equatable, LocalizedError {
    case empty
    case missingColumns([String])
    case badDate(line: Int, value: String)
    case badAmount(line: Int, value: String)
    case missingField(line: Int, field: String)
    case wrongFieldCount(line: Int, expected: Int, found: Int)

    var errorDescription: String? {
        switch self {
        case .empty: "The file has no rows."
        case .missingColumns(let cols): "Missing column(s): \(cols.joined(separator: ", ")). The first line must be: date,account,amount,memo"
        case .badDate(let line, let v): "Line \(line): \"\(v)\" is not a date (use yyyy-MM-dd)."
        case .badAmount(let line, let v): "Line \(line): \"\(v)\" is not a positive amount."
        case .missingField(let line, let f): "Line \(line): \(f) is empty."
        case .wrongFieldCount(let line, let e, let f): "Line \(line): expected \(e) fields, found \(f)."
        }
    }
}

enum ExpenseCSVParser {
    static let requiredColumns = ["date", "account", "amount", "memo"]

    static func parse(_ text: String, calendar: Calendar = .current) throws(ExpenseImportError) -> [ExpenseImportRow] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw .empty
        }
        let header = splitCSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let missing = requiredColumns.filter { !header.contains($0) }
        guard missing.isEmpty else { throw .missingColumns(missing) }
        let col = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })

        var rows: [ExpenseImportRow] = []
        var seenHeader = false
        for (index, raw) in lines.enumerated() {
            let lineNo = index + 1
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !seenHeader { seenHeader = true; continue }
            let fields = splitCSVLine(raw)
            guard fields.count == header.count else {
                throw .wrongFieldCount(line: lineNo, expected: header.count, found: fields.count)
            }
            func field(_ name: String) -> String { fields[col[name]!].trimmingCharacters(in: .whitespaces) }

            let dateText = field("date")
            guard let date = parseDate(dateText, calendar: calendar) else { throw .badDate(line: lineNo, value: dateText) }
            let account = field("account")
            guard !account.isEmpty else { throw .missingField(line: lineNo, field: "account") }
            let amountText = field("amount").replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            guard let amount = Double(amountText), amount > 0 else { throw .badAmount(line: lineNo, value: field("amount")) }
            let memo = field("memo")
            guard !memo.isEmpty else { throw .missingField(line: lineNo, field: "memo") }

            rows.append(ExpenseImportRow(line: lineNo, date: date, account: account,
                                         amount: (amount * 100).rounded() / 100, memo: memo))
        }
        guard !rows.isEmpty else { throw .empty }
        return rows
    }

    /// Local noon, so the entry shows on the same day in every time zone the devices use.
    static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var comps = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        comps.calendar = calendar
        guard let date = calendar.date(from: comps),
              calendar.component(.day, from: date) == parts[2] else { return nil }   // rejects 2026-02-30
        return date
    }

    /// Splits one CSV line, honouring double-quoted fields with commas and "" escapes.
    static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { current.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else { current.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == "," { fields.append(current); current = "" }
            else { current.append(c) }
        }
        fields.append(current)
        return fields
    }
}

// MARK: - Import sheet

struct DPExpenseImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SDAccount.name) private var accounts: [SDAccount]
    @Query private var entries: [SDJournalEntry]

    @State private var rows: [ExpenseImportRow] = []
    @State private var fileName = ""
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?

    private var newRows: [ExpenseImportRow] { rows.filter { !alreadyBooked($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("CSV file") {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(fileName.isEmpty ? "Choose CSV File\u{2026}" : "Choose a Different File\u{2026}",
                              systemImage: "doc.text.magnifyingglass")
                    }
                    if !fileName.isEmpty { LabeledContent("File", value: fileName) }
                    Text("Each row debits the expense account and credits Cash.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !rows.isEmpty {
                    Section("Entries (\(newRows.count) new of \(rows.count))") {
                        ForEach(rows) { row in
                            let booked = alreadyBooked(row)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.date, format: .dateTime.year().month(.abbreviated).day())
                                        .font(.subheadline.monospacedDigit())
                                    Spacer()
                                    Text(row.amount.currencyString()).font(.subheadline.bold().monospacedDigit())
                                }
                                Text(row.memo).font(.caption)
                                Text("Dr \(row.account)\(accountExists(row.account) ? "" : " (new account)")  \u{2022}  Cr Cash"
                                     + (booked ? "  \u{2022}  already in the books, skipped" : ""))
                                    .font(.caption2).foregroundStyle(booked ? .orange : .secondary)
                            }
                            .opacity(booked ? 0.5 : 1)
                        }
                    }
                    Section("Total") {
                        LabeledContent("New entries", value: newRows.reduce(0) { $0 + $1.amount }.currencyString())
                    }
                }
            }
            .navigationTitle("Import Expense Entries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { importRows() }.disabled(newRows.isEmpty)
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { load(url) }
                case .failure(let failure): errorMessage = failure.localizedDescription
                }
            }
            .alert("Import Problem",
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .alert("Imported",
                   isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil; dismiss() } })) {
                Button("OK") { resultMessage = nil; dismiss() }
            } message: { Text(resultMessage ?? "") }
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            rows = try ExpenseCSVParser.parse(text)
            fileName = url.lastPathComponent
        } catch let error as ExpenseImportError {
            rows = []; errorMessage = error.errorDescription
        } catch {
            rows = []; errorMessage = error.localizedDescription
        }
    }

    private func accountExists(_ name: String) -> Bool {
        accounts.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.type == .expense }
    }

    private func alreadyBooked(_ row: ExpenseImportRow) -> Bool {
        let cal = Calendar.current
        return entries.contains { cal.isDate($0.date, inSameDayAs: row.date) && $0.memo == row.memo }
    }

    private func importRows() {
        ensureDefaultAccounts(context: modelContext)
        guard let cash = accounts.first(where: { $0.name == "Cash" && $0.type == .asset }) else {
            errorMessage = "No Cash account found."
            return
        }
        var created: [String: UUID] = [:]     // lowercased name -> id
        var createdNames: [String] = []
        func expenseAccountId(_ name: String) -> UUID {
            if let existing = accounts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.type == .expense }) {
                return existing.id
            }
            if let id = created[name.lowercased()] { return id }
            let account = SDAccount(name: name, type: .expense)
            modelContext.insert(account)
            created[name.lowercased()] = account.id
            createdNames.append(name)
            return account.id
        }

        let toImport = newRows
        for row in toImport {
            let entry = SDJournalEntry(date: row.date, memo: row.memo)
            modelContext.insert(entry)
            let debit = SDEntryLine(accountId: expenseAccountId(row.account), debit: row.amount, credit: 0,
                                    memo: row.memo, sortOrder: 0)
            debit.journalEntry = entry
            modelContext.insert(debit)
            let credit = SDEntryLine(accountId: cash.id, debit: 0, credit: row.amount, memo: "Paid", sortOrder: 1)
            credit.journalEntry = entry
            modelContext.insert(credit)
        }
        do {
            try modelContext.save()
            let total = toImport.reduce(0) { $0 + $1.amount }
            resultMessage = "Added \(toImport.count) entries totalling \(total.currencyString())"
                + (createdNames.isEmpty ? "." : " and created \(createdNames.count) account(s): \(createdNames.joined(separator: ", ")).")
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
