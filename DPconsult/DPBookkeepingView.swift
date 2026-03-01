import SwiftUI
import SwiftData
import Foundation
import PDFKit
import UIKit

// MARK: - Views

struct DPBookkeepingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDAccount.name) private var accounts: [SDAccount]
    @Query(sort: \SDJournalEntry.date) private var entries: [SDJournalEntry]
    @Query(sort: \SDInvoice.issueDate, order: .reverse) private var invoices: [SDInvoice]

    @State private var selectedTab = 0
    @State private var showingNewAccount = false
    @State private var showingNewEntry = false

    @State private var journalCSVURL: URL? = nil
    @State private var balanceSheetCSVURL: URL? = nil
    @State private var pandlCSVURL: URL? = nil
    @State private var showShareAlert = false
    @State private var shareAlertMessage = ""
    @State private var shareItemURL: URL? = nil
    @State private var showingShareSheet = false

    private var calculator: BKCalculator {
        BKCalculator(accounts: accounts, entries: entries)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Select Tab", selection: $selectedTab) {
                    Text("Accounts").tag(0)
                    Text("Journal").tag(1)
                    Text("Reports").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch selectedTab {
                    case 0: accountsView
                    case 1: journalView
                    case 2: reportsView
                    default: EmptyView()
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Bookkeeping")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    switch selectedTab {
                    case 0:
                        Button("Add Account") { showingNewAccount = true }
                    case 1:
                        Button("Add Entry") { showingNewEntry = true }
                    case 2:
                        Menu {
                            Section("Print") {
                                Button { printBalanceSheet() } label: { Label("Print Balance Sheet", systemImage: "printer") }
                                Button { printJournal() } label: { Label("Print Journal", systemImage: "printer") }
                            }
                            Section("Share") {
                                Button("Share Journal CSV") { shareJournalCSV() }
                                Button("Share Balance Sheet CSV") { shareBalanceSheetCSV() }
                                Button("Share P&L CSV") { sharePandLCSV() }
                                Button("Share Balance Sheet PDF") { shareBalanceSheetPDF() }
                                Button("Share Journal PDF") { shareJournalPDF() }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .onAppear {
                ensureDefaultAccounts(context: modelContext)
            }
            .sheet(isPresented: $showingNewAccount) {
                BKNewAccountView(isPresented: $showingNewAccount)
                    .presentationSizing(.form)
            }
            .sheet(isPresented: $showingNewEntry) {
                BKNewEntryView(isPresented: $showingNewEntry)
                    .presentationSizing(.form)
            }
            .alert("Export/Share", isPresented: $showShareAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareAlertMessage)
            }
            .sheet(isPresented: $showingShareSheet, onDismiss: {
                shareItemURL = nil
            }) {
                if let url = shareItemURL {
                    DPShareSheetView(activityItems: [url]) { _ in
                        showingShareSheet = false
                        shareItemURL = nil
                    }
                    .presentationSizing(.form)
                } else {
                    Color.clear.onAppear {
                        showingShareSheet = false
                        shareAlertMessage = "No file to share. Please export again."
                        showShareAlert = true
                    }
                }
            }
        }
    }

    // MARK: Accounts Tab

    var accountsView: some View {
        List {
            ForEach(accounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.name).font(.headline)
                        Text(account.type.displayName).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(balanceFormatted(account: account))
                        .bold()
                        .foregroundColor(balanceColor(account: account))
                }
                .padding(.vertical, 4)
            }
            // Retained Earnings (computed)
            HStack {
                VStack(alignment: .leading) {
                    Text("Retained Earnings").font(.headline)
                    Text("Equity").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(calculator.retainedEarnings().currencyString())
                    .bold()
                    .foregroundColor(calculator.retainedEarnings() >= 0 ? .green : .red)
            }
            .padding(.vertical, 4)
        }
    }

    func balanceFormatted(account: SDAccount) -> String {
        calculator.balance(for: account.id).currencyString()
    }

    func balanceColor(account: SDAccount) -> Color {
        let bal = calculator.balance(for: account.id)
        if bal == 0 { return .primary }
        return bal >= 0 ? .green : .red
    }

    // MARK: Journal Tab

    var journalView: some View {
        List {
            ForEach(entries.sorted { $0.date > $1.date }) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.date.formatted(date: .numeric, time: .omitted)).font(.headline)
                        Spacer()
                        Text(entry.isBalanced ? "Balanced" : "Unbalanced")
                            .font(.caption)
                            .foregroundColor(entry.isBalanced ? .green : .red)
                    }
                    if !entry.memo.isEmpty {
                        Text(entry.memo).font(.subheadline).foregroundColor(.secondary)
                    }
                    ForEach(entry.sortedLines) { line in
                        if let account = accounts.first(where: { $0.id == line.accountId }) {
                            HStack {
                                Text(account.name)
                                Spacer()
                                if line.debit > 0 {
                                    Text("+\(line.debit.currencyString())").foregroundColor(.green)
                                } else if line.credit > 0 {
                                    Text("-\(line.credit.currencyString())").foregroundColor(.red)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Retained Earnings (all time)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Retained Earnings (All Time)").font(.headline)
                    Spacer()
                    let re = calculator.retainedEarnings()
                    Text(re.currencyString())
                        .font(.headline)
                        .foregroundColor(re >= 0 ? .green : .red)
                }
                Text("Computed from all income and expense entries")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Reports Tab

    var reportsView: some View {
        ScrollView {
            let cal = Calendar.current
            let now = Date()
            let currentYear = cal.component(.year, from: now)
            let augFirstThisYear = cal.date(from: DateComponents(year: currentYear, month: 8, day: 1)) ?? now
            let ytdStart = (now >= augFirstThisYear) ? augFirstThisYear : (cal.date(from: DateComponents(year: currentYear - 1, month: 8, day: 1)) ?? augFirstThisYear)

            let allowedStatuses = Set(["draft", "billable", "invoice", "sent", "partial", "paid"])
            let fyInvoices = invoices.filter { inv in
                let inWindow = inv.issueDate >= ytdStart && inv.issueDate <= Date()
                return inWindow && allowedStatuses.contains(inv.status.lowercased())
            }
            let salesFromInvoicesFY: Double = fyInvoices.reduce(0) { sum, inv in
                let itemsSum = (inv.items ?? []).reduce(0) { $0 + $1.amount }
                let correctedTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
                return sum + correctedTotal
            }

            VStack(alignment: .leading, spacing: 20) {
                Text("Balance Sheet").font(.title2).bold().padding(.bottom, 4)

                let bs = calculator.balanceSheetDetailed()

                Group {
                    Text("Assets").font(.headline)
                    ForEach(bs.assets, id: \.0.id) { (account, balance) in
                        HStack { Text(account.name); Spacer(); Text(balance.currencyString()) }.font(.subheadline)
                    }
                    Divider()
                    Text("Liabilities").font(.headline)
                    ForEach(bs.liabilities, id: \.0.id) { (account, balance) in
                        HStack { Text(account.name); Spacer(); Text(balance.currencyString()) }.font(.subheadline)
                    }
                    Divider()
                    Text("Equity").font(.headline)
                    ForEach(bs.equity, id: \.0.id) { (account, balance) in
                        HStack { Text(account.name); Spacer(); Text(balance.currencyString()) }.font(.subheadline)
                    }
                }

                let totals = bs.totals
                Divider()
                HStack { Text("Total Assets").font(.headline); Spacer(); Text(totals.assets.currencyString()) }
                HStack { Text("Total Liabilities").font(.headline); Spacer(); Text(totals.liabilities.currencyString()) }
                HStack { Text("Retained Earnings").font(.headline); Spacer(); Text(bs.retainedEarnings.currencyString()) }
                HStack { Text("Total Equity (incl. Retained)").font(.headline); Spacer(); Text(totals.equity.currencyString()) }
                let rhs = totals.liabilities + totals.equity
                HStack {
                    Text("Check: Assets vs Liab+Equity")
                    Spacer()
                    Text((totals.assets - rhs).currencyString())
                        .foregroundColor(abs(totals.assets - rhs) < 0.005 ? .green : .red)
                }

                Divider().padding(.vertical, 10)

                Text("Profit & Loss (YTD)").font(.title2).bold().padding(.bottom, 4)

                let pAndL = calculator.profitAndLoss(start: ytdStart, end: Date())

                Group {
                    Text("Income").font(.headline)
                    HStack {
                        Text("Sales Revenue (Invoices FY YTD)")
                        Spacer()
                        Text(salesFromInvoicesFY.currencyString())
                    }
                    .font(.subheadline)
                    Divider()
                    Text("Expenses").font(.headline)
                    ForEach(pAndL.expenses, id: \.0.id) { (account, val) in
                        HStack { Text(account.name); Spacer(); Text(val.currencyString()) }.font(.subheadline)
                    }
                    Divider()
                    HStack {
                        Text("Net Profit/Loss").font(.headline)
                        Spacer()
                        let totalExpenses = pAndL.expenses.reduce(0) { $0 + $1.1 }
                        let netFY = salesFromInvoicesFY - totalExpenses
                        Text(netFY.currencyString())
                            .font(.headline)
                            .foregroundColor(netFY >= 0 ? .green : .red)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    // MARK: - PDF Export & Share

    private func presentShare(for url: URL) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            shareAlertMessage = "CSV file is missing. Please export again."
            showShareAlert = true
            return
        }
        self.shareItemURL = url
        self.showingShareSheet = true
    }

    // MARK: - Journal CSV

    private func exportJournalCSV() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        struct JournalRow: JournalEntryRepresentable {
            let dateString: String
            let account: String
            let descriptionText: String
            let debit: String
            let credit: String
        }

        var rows: [JournalRow] = []
        for entry in entries {
            let dateStr = df.string(from: entry.date)
            for line in entry.sortedLines {
                let accountName = accounts.first(where: { $0.id == line.accountId })?.name ?? "Account"
                let memo = line.memo.isEmpty ? entry.memo : line.memo
                let debitStr = line.debit > 0 ? String(format: "%.2f", line.debit) : ""
                let creditStr = line.credit > 0 ? String(format: "%.2f", line.credit) : ""
                rows.append(JournalRow(dateString: dateStr, account: accountName, descriptionText: memo, debit: debitStr, credit: creditStr))
            }
        }

        let retained = calculator.retainedEarnings()
        let todayStr = df.string(from: Date())
        let reDebit = retained < 0 ? String(format: "%.2f", abs(retained)) : ""
        let reCredit = retained >= 0 ? String(format: "%.2f", retained) : ""
        rows.append(JournalRow(dateString: todayStr, account: "Retained Earnings", descriptionText: "Cumulative Net Income", debit: reDebit, credit: reCredit))

        let exporter = JournalCSVExporter()
        let data = exporter.makeCSV(entries: rows)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("Journal.csv")
        do {
            try data.write(to: url, options: .atomic)
            journalCSVURL = url
        } catch {
            shareAlertMessage = "Failed to write Journal CSV: \(error.localizedDescription)"
            showShareAlert = true
        }
    }

    private func shareJournalCSV() {
        if let url = journalCSVURL, FileManager.default.fileExists(atPath: url.path) {
            presentShare(for: url)
            return
        }
        exportJournalCSV()
        if let url = journalCSVURL, FileManager.default.fileExists(atPath: url.path) {
            presentShare(for: url)
        } else {
            shareAlertMessage = "Failed to prepare Journal CSV for sharing."
            showShareAlert = true
        }
    }

    // MARK: - Balance Sheet CSV

    private func exportBalanceSheetCSV() -> URL? {
        let bs = calculator.balanceSheetDetailed()
        var rows: [[String]] = []

        func add(_ section: String, items: [(SDAccount, Double)]) {
            for (acct, amt) in items {
                rows.append([section, acct.name, String(format: "%.2f", amt)])
            }
        }

        add("Assets", items: bs.assets)
        add("Liabilities", items: bs.liabilities)
        add("Equity", items: bs.equity)
        rows.append(["Total Assets", "", String(format: "%.2f", bs.totals.assets)])
        rows.append(["Total Liabilities", "", String(format: "%.2f", bs.totals.liabilities)])
        rows.append(["Retained Earnings", "", String(format: "%.2f", bs.retainedEarnings)])
        rows.append(["Total Equity", "", String(format: "%.2f", bs.totals.equity)])
        rows.append(["Check (Assets - (L+E))", "", String(format: "%.2f", bs.totals.assets - (bs.totals.liabilities + bs.totals.equity))])

        let exporter = JournalCSVExporter()
        let data = exporter.makeCSV(headers: ["Section", "Account", "Amount"], rows: rows)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("BalanceSheet.csv")
        do {
            try data.write(to: url, options: .atomic)
            balanceSheetCSVURL = url
            return url
        } catch {
            shareAlertMessage = "Failed to write Balance Sheet CSV: \(error.localizedDescription)"
            showShareAlert = true
            return nil
        }
    }

    private func shareBalanceSheetCSV() {
        if let url = exportBalanceSheetCSV() {
            presentShare(for: url)
        }
    }

    // MARK: - P&L CSV

    private func exportPandLCSV() -> URL? {
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)
        let augFirstThisYear = cal.date(from: DateComponents(year: currentYear, month: 8, day: 1)) ?? now
        let ytdStart: Date = (now >= augFirstThisYear) ? augFirstThisYear : (cal.date(from: DateComponents(year: currentYear - 1, month: 8, day: 1)) ?? augFirstThisYear)

        let allowedStatuses = Set(["draft", "billable", "invoice", "sent", "partial", "paid"])
        let ytdInvoices = invoices.filter { inv in
            inv.issueDate >= ytdStart && inv.issueDate <= Date() && allowedStatuses.contains(inv.status.lowercased())
        }
        var salesFromInvoicesYTD: Double = 0
        for inv in ytdInvoices {
            let itemsSum = (inv.items ?? []).reduce(0) { $0 + $1.amount }
            let correctedTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
            salesFromInvoicesYTD += correctedTotal
        }

        var rows: [[String]] = []
        rows.append(["INCOME", "", ""])
        rows.append(["Income", "Sales Revenue (Invoices YTD)", String(format: "%.2f", salesFromInvoicesYTD)])
        rows.append(["Total Income", "", String(format: "%.2f", salesFromInvoicesYTD)])
        rows.append(["", "", ""])

        rows.append(["EXPENSES", "", ""])
        let pl = calculator.profitAndLoss(start: ytdStart, end: Date())
        for (account, amount) in pl.expenses {
            rows.append(["Expense", account.name, String(format: "%.2f", amount)])
        }
        let totalExpenses = pl.expenses.reduce(0) { $0 + $1.1 }
        rows.append(["Total Expenses", "", String(format: "%.2f", totalExpenses)])
        rows.append(["", "", ""])
        rows.append(["NET INCOME", "", String(format: "%.2f", salesFromInvoicesYTD - totalExpenses)])

        let exporter = JournalCSVExporter()
        let data = exporter.makeCSV(headers: ["Category", "Account", "Amount"], rows: rows)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("ProfitAndLoss.csv")
        do {
            try data.write(to: url, options: .atomic)
            pandlCSVURL = url
            return url
        } catch {
            shareAlertMessage = "Failed to write P&L CSV: \(error.localizedDescription)"
            showShareAlert = true
            return nil
        }
    }

    private func sharePandLCSV() {
        if let url = exportPandLCSV() {
            presentShare(for: url)
        }
    }

    // MARK: - Bookkeeping PDF Exports

    private func exportBalanceSheetPDF() -> URL? {
        let bs = calculator.balanceSheetDetailed()
        let data = BKReportsPDF.renderBalanceSheet(bs: bs)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("BalanceSheet.pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            shareAlertMessage = "Failed to write Balance Sheet PDF: \(error.localizedDescription)"
            showShareAlert = true
            return nil
        }
    }

    private func shareBalanceSheetPDF() {
        if let url = exportBalanceSheetPDF() {
            presentShare(for: url)
        }
    }

    private func exportJournalPDF() -> URL? {
        let data = BKReportsPDF.renderJournal(entries: entries, accounts: accounts)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("Journal.pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            shareAlertMessage = "Failed to write Journal PDF: \(error.localizedDescription)"
            showShareAlert = true
            return nil
        }
    }

    private func shareJournalPDF() {
        if let url = exportJournalPDF() {
            presentShare(for: url)
        }
    }

    private func printBalanceSheet() {
        let bs = calculator.balanceSheetDetailed()
        let data = BKReportsPDF.renderBalanceSheet(bs: bs)
        dpPrint(data: data, jobName: "Balance Sheet")
    }

    private func printJournal() {
        let data = BKReportsPDF.renderJournal(entries: entries, accounts: accounts)
        dpPrint(data: data, jobName: "Journal")
    }
}


// MARK: - New Account Editor

struct BKNewAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var selectedType: BKAccountType = .asset

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Name") {
                    TextField("Name", text: $name)
                        .autocapitalization(.words)
                }
                Section("Account Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(BKAccountType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { return }
                        let account = SDAccount(name: trimmedName, type: selectedType)
                        modelContext.insert(account)
                        isPresented = false
                    }
                    .disabled(!isValid)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - New Entry Editor

struct BKNewEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDAccount.name) private var accounts: [SDAccount]
    @Binding var isPresented: Bool

    @State private var date: Date = Date()
    @State private var memo: String = ""
    @State private var lines: [DraftEntryLine] = []

    struct DraftEntryLine: Identifiable {
        let id = UUID()
        var accountId: UUID
        var debit: Double = 0
        var credit: Double = 0
        var memo: String = ""
    }

    var totalDebits: Double {
        lines.reduce(0) { $0 + $1.debit }
    }

    var totalCredits: Double {
        lines.reduce(0) { $0 + $1.credit }
    }

    var isBalanced: Bool {
        abs(totalDebits - totalCredits) < 0.0001 && lines.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Entry Date", selection: $date, displayedComponents: .date)
                }
                Section("Memo") {
                    TextField("Memo", text: $memo)
                }
                Section("Lines") {
                    ForEach($lines) { $line in
                        BKEntryLineEditor(accounts: accounts, line: $line, onDelete: {
                            if let idx = lines.firstIndex(where: { $0.id == line.id }) {
                                lines.remove(at: idx)
                            }
                        })
                    }
                    Button {
                        let firstAccountId = accounts.first?.id ?? UUID()
                        lines.append(DraftEntryLine(accountId: firstAccountId))
                    } label: {
                        Label("Add Line", systemImage: "plus.circle")
                    }
                }
                Section("Totals") {
                    HStack {
                        Text("Total Debits"); Spacer()
                        Text(totalDebits.currencyString()).foregroundColor(.green)
                    }
                    HStack {
                        Text("Total Credits"); Spacer()
                        Text(totalCredits.currencyString()).foregroundColor(.red)
                    }
                    if !isBalanced {
                        Text("Entry must be balanced and have at least 2 lines to save")
                            .font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Journal Entry")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = SDJournalEntry(date: date, memo: memo)
                        modelContext.insert(entry)

                        for (idx, draft) in lines.enumerated() {
                            let line = SDEntryLine(
                                accountId: draft.accountId,
                                debit: draft.debit,
                                credit: draft.credit,
                                memo: draft.memo,
                                sortOrder: idx
                            )
                            line.journalEntry = entry
                            modelContext.insert(line)
                        }

                        isPresented = false
                    }
                    .disabled(!isBalanced)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .onAppear {
                if accounts.isEmpty {
                    ensureDefaultAccounts(context: modelContext)
                }
                if lines.isEmpty && !accounts.isEmpty {
                    let firstAccountId = accounts.first!.id
                    lines = [DraftEntryLine(accountId: firstAccountId)]
                }
            }
        }
    }
}

// MARK: - BKEntryLine Editor Row

struct BKEntryLineEditor: View {
    let accounts: [SDAccount]
    @Binding var line: BKNewEntryView.DraftEntryLine
    var onDelete: () -> Void

    @State private var debitText: String = ""
    @State private var creditText: String = ""

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Picker("Account", selection: $line.accountId) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Debit").font(.caption)
                    TextField("0.00", text: Binding(
                        get: { debitText },
                        set: { val in
                            debitText = val
                            if let dbl = Double(val), dbl >= 0 {
                                line.debit = dbl
                                if dbl > 0 { line.credit = 0; creditText = "" }
                            } else { line.debit = 0 }
                        }
                    ))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("Credit").font(.caption)
                    TextField("0.00", text: Binding(
                        get: { creditText },
                        set: { val in
                            creditText = val
                            if let dbl = Double(val), dbl >= 0 {
                                line.credit = dbl
                                if dbl > 0 { line.debit = 0; debitText = "" }
                            } else { line.credit = 0 }
                        }
                    ))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                }
            }

            TextField("Memo (optional)", text: $line.memo)
                .textFieldStyle(.roundedBorder)
        }
        .onAppear {
            debitText = line.debit == 0 ? "" : String(format: "%.2f", line.debit)
            creditText = line.credit == 0 ? "" : String(format: "%.2f", line.credit)
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Preview

#Preview {
    DPBookkeepingView()
}

// MARK: - UIKit ActivityView Wrapper for SwiftUI

struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var completion: ((UIActivity.ActivityType?) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion?(nil)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
