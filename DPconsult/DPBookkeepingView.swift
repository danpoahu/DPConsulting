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
    @State private var showingExpenseImport = false
    @State private var editingEntry: SDJournalEntry? = nil

    @State private var journalCSVURL: URL? = nil
    @State private var balanceSheetCSVURL: URL? = nil
    @State private var pandlCSVURL: URL? = nil
    @State private var showShareAlert = false
    @State private var shareAlertMessage = ""
    @State private var shareItemURL: URL? = nil
    @State private var showingShareSheet = false
    @State private var showReconcileConfirm = false
    @State private var reconcileMessage = ""
    @State private var showReconcileResult = false
    // P&L period (Reports tab)
    @State private var plMode: PLPeriodMode = .month
    @State private var plYear: Int = Calendar.current.component(.year, from: Date())
    @State private var plMonth: Int = Calendar.current.component(.month, from: Date())

    private var calculator: BKCalculator {
        BKCalculator(accounts: accounts, entries: entries)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Select Tab", selection: $selectedTab) {
                    Text("Accounts").tag(0)
                    Text("Journal").tag(1)
                    Text("Balance Sheet").tag(2)
                    Text("P&L").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch selectedTab {
                    case 0: accountsView
                    case 1: journalView
                    case 2: reportsView
                    case 3: plView
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
                        HStack {
                            Button { showingExpenseImport = true } label: {
                                Label("Import Expenses", systemImage: "square.and.arrow.down")
                            }
                            Button("Add Entry") { showingNewEntry = true }
                        }
                    case 2, 3:
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
                            Section("Maintenance") {
                                Button("Reconcile A/R from Invoices", role: .destructive) {
                                    showReconcileConfirm = true
                                }
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
            .sheet(item: $editingEntry) { entry in
                BKEditEntryView(entry: entry)
                    .presentationSizing(.form)
            }
            .sheet(isPresented: $showingExpenseImport) {
                DPExpenseImportView()
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
            .alert("Reconcile A/R", isPresented: $showReconcileConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reconcile", role: .destructive) { reconcileAR() }
            } message: {
                Text("This will delete ALL journal entries touching A/R and re-create them from actual invoice data. Continue?")
            }
            .alert("Reconciliation Complete", isPresented: $showReconcileResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reconcileMessage)
            }
        }
    }

    // MARK: - Reconcile A/R

    private func reconcileAR() {
        // 1. Find A/R account
        ensureDefaultAccounts(context: modelContext)
        let accountsDescriptor = FetchDescriptor<SDAccount>()
        let accts = (try? modelContext.fetch(accountsDescriptor)) ?? []

        guard let ar = accts.first(where: { $0.name.caseInsensitiveCompare("Accounts Receivable") == .orderedSame && $0.type == .asset }),
              let revenue = accts.first(where: { $0.name.caseInsensitiveCompare("Sales Revenue") == .orderedSame && $0.type == .income }),
              let cash = accts.first(where: { $0.name.caseInsensitiveCompare("Cash") == .orderedSame && $0.type == .asset })
        else {
            reconcileMessage = "Could not find required accounts."
            showReconcileResult = true
            return
        }

        // 2. Delete ALL journal entries that touch A/R (clean slate)
        var deleted = 0
        for entry in entries {
            let lines = entry.lines ?? []
            let touchesAR = lines.contains { $0.accountId == ar.id }
            if touchesAR {
                for line in lines { modelContext.delete(line) }
                modelContext.delete(entry)
                deleted += 1
            }
        }

        // 3. Re-post from actual invoices
        var posted = 0
        var expectedAR: Double = 0
        for inv in invoices {
            let status = inv.status.lowercased()
            guard status == "sent" || status == "partial" || status == "paid" else {
                inv.journalPosted = false
                inv.lastPostedPayment = 0
                continue
            }

            // Post A/R debit + Revenue credit for invoice total
            let arEntry = SDJournalEntry(date: inv.issueDate, memo: "Invoice #\(inv.invoiceNumber) sent")
            modelContext.insert(arEntry)

            let debitLine = SDEntryLine(accountId: ar.id, debit: inv.total, credit: 0, memo: "A/R", sortOrder: 0)
            debitLine.journalEntry = arEntry
            modelContext.insert(debitLine)

            let creditLine = SDEntryLine(accountId: revenue.id, debit: 0, credit: inv.total, memo: "Revenue", sortOrder: 1)
            creditLine.journalEntry = arEntry
            modelContext.insert(creditLine)

            inv.journalPosted = true
            posted += 1

            // Post payment if any (capped at invoice total to prevent over-credit)
            let payment = min(inv.amountPaid, inv.total)
            if payment > 0.005 {
                let payEntry = SDJournalEntry(date: inv.updatedAt, memo: "Payment received – Invoice #\(inv.invoiceNumber)")
                modelContext.insert(payEntry)

                let cashDebit = SDEntryLine(accountId: cash.id, debit: payment, credit: 0, memo: "Cash received", sortOrder: 0)
                cashDebit.journalEntry = payEntry
                modelContext.insert(cashDebit)

                let arCredit = SDEntryLine(accountId: ar.id, debit: 0, credit: payment, memo: "Reduce A/R", sortOrder: 1)
                arCredit.journalEntry = payEntry
                modelContext.insert(arCredit)
            }
            inv.lastPostedPayment = inv.amountPaid

            let netBalance = inv.total - min(inv.amountPaid, inv.total)
            expectedAR += netBalance
        }

        reconcileMessage = "Removed \(deleted) old entries, re-posted \(posted) invoices. Expected A/R: \(String(format: "$%.2f", expectedAR))"
        showReconcileResult = true
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
                .contentShape(Rectangle())
                .onTapGesture { editingEntry = entry }
                .contextMenu {
                    Button { editingEntry = entry } label: { Label("Edit Date & Memo\u{2026}", systemImage: "calendar") }
                }
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

            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Profit & Loss (any month, each month, calendar YTD)

    /// Journal entries reduced to what cash-basis income needs.
    private var plEntries: [PLIncome.Entry] {
        let kinds: [UUID: PLIncome.Line.Kind] = Dictionary(uniqueKeysWithValues: accounts.map { acct in
            let kind: PLIncome.Line.Kind
            if acct.type == .income { kind = .income }
            else if acct.type == .asset && acct.name == "Cash" { kind = .cash }
            else if acct.type == .asset && acct.name == "Accounts Receivable" { kind = .receivable }
            else { kind = .other }
            return (acct.id, kind)
        })
        return entries.map { entry in
            PLIncome.Entry(date: entry.date, lines: (entry.lines ?? []).map {
                PLIncome.Line(kind: kinds[$0.accountId] ?? .other, debit: $0.debit, credit: $0.credit)
            })
        }
    }

    /// Years that have any invoice or journal entry, always including this year.
    private var plYears: [Int] {
        let cal = Calendar.current
        var years = Set(invoices.map { cal.component(.year, from: $0.issueDate) })
        years.formUnion(entries.map { cal.component(.year, from: $0.date) })
        years.insert(cal.component(.year, from: Date()))
        return years.sorted(by: >)
    }

    /// The single period shown for Month and YTD, and used for Each Month's total column.
    private var selectedPLPeriod: PLPeriod {
        plMode == .month ? .month(year: plYear, month: plMonth) : .ytd(year: plYear)
    }

    private struct PLFigures {
        let income: Double
        let expenses: [(SDAccount, Double)]
        var totalExpenses: Double { expenses.reduce(0) { $0 + $1.1 } }
        var net: Double { income - totalExpenses }
    }

    private func plFigures(_ period: PLPeriod) -> PLFigures {
        let pl = calculator.profitAndLoss(start: period.start, end: period.end)
        return PLFigures(income: PLIncome.cashReceived(plEntries, in: period), expenses: pl.expenses)
    }

    @ViewBuilder
    private var plSection: some View {
        Text("Profit & Loss").font(.title2).bold()

        Picker("Period", selection: $plMode) {
            ForEach(PLPeriodMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        HStack {
            Picker("Year", selection: $plYear) {
                ForEach(plYears, id: \.self) { Text(String($0)).tag($0) }
            }
            if plMode == .month {
                Picker("Month", selection: $plMonth) {
                    ForEach(1...12, id: \.self) { m in
                        Text(Calendar.current.monthSymbols[m - 1]).tag(m)
                    }
                }
            }
            Spacer()
        }

        if plMode == .eachMonth {
            plEachMonthGrid
        } else {
            plSingle(selectedPLPeriod)
        }
        Text("Cash basis: income is counted when payment is received (Payment received entries); expenses when paid.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func plSingle(_ period: PLPeriod) -> some View {
        let f = plFigures(period)
        Text(period.label).font(.headline).foregroundStyle(.secondary)
        Group {
            Text("Income").font(.headline)
            HStack { Text("Payments Received"); Spacer(); Text(f.income.currencyString()) }.font(.subheadline)
            Divider()
            Text("Expenses").font(.headline)
            ForEach(f.expenses.filter { abs($0.1) >= 0.005 }, id: \.0.id) { (account, val) in
                HStack { Text(account.name); Spacer(); Text(val.currencyString()) }.font(.subheadline)
            }
            HStack { Text("Total Expenses"); Spacer(); Text(f.totalExpenses.currencyString()) }.font(.subheadline.bold())
            Divider()
            HStack {
                Text("Net Profit/Loss").font(.headline)
                Spacer()
                Text(f.net.currencyString()).font(.headline).foregroundColor(f.net >= 0 ? .green : .red)
            }
        }
    }

    /// The P&L tab: its own vertical scroll, no sideways scrolling anywhere
    /// (a horizontal ScrollView inside a vertical one swallows the scroll wheel on Mac).
    var plView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                plSection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    /// Each Month: one row per month (Income / Expenses / Net), click a month to see
    /// its expenses by account, then a YTD total row.
    @ViewBuilder
    private var plEachMonthGrid: some View {
        let months = PLPeriod.months(in: plYear)
        let total = plFigures(.ytd(year: plYear))

        VStack(spacing: 0) {
            HStack {
                Text("Month").frame(maxWidth: .infinity, alignment: .leading)
                Text("Income").frame(width: 110, alignment: .trailing)
                Text("Expenses").frame(width: 110, alignment: .trailing)
                Text("Net").frame(width: 110, alignment: .trailing)
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            ForEach(months, id: \.start) { period in
                let f = plFigures(period)
                DisclosureGroup {
                    VStack(spacing: 4) {
                        ForEach(f.expenses.filter { abs($0.1) >= 0.005 }, id: \.0.id) { (account, val) in
                            HStack {
                                Text(account.name)
                                Spacer()
                                Text(val.currencyString()).monospacedDigit()
                            }
                            .font(.caption)
                        }
                        if f.expenses.allSatisfy({ abs($0.1) < 0.005 }) {
                            Text("No expenses").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.leading, 8).padding(.vertical, 4)
                } label: {
                    plMonthRow(Calendar.current.monthSymbols[Calendar.current.component(.month, from: period.start) - 1], f)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }

            plMonthRow("\(plYear) YTD", total).font(.subheadline.bold())
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12))
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func plMonthRow(_ name: String, _ f: PLFigures) -> some View {
        HStack {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(f.income.currencyString()).frame(width: 110, alignment: .trailing)
            Text(f.totalExpenses.currencyString()).frame(width: 110, alignment: .trailing)
            Text(f.net.currencyString()).frame(width: 110, alignment: .trailing)
                .foregroundColor(f.net >= 0 ? .green : .red)
        }
        .font(.subheadline.monospacedDigit())
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
        var rows: [[String]] = []
        var headers: [String]
        let money: (Double) -> String = { String(format: "%.2f", $0) }
        if plMode == .eachMonth {
            let months = PLPeriod.months(in: plYear)
            let columns = months.map { plFigures($0) }
            let total = plFigures(.ytd(year: plYear))
            let names = months.map { Calendar.current.shortMonthSymbols[Calendar.current.component(.month, from: $0.start) - 1] }
            headers = ["\(plYear)"] + names + ["YTD"]
            rows.append(["Payments Received"] + columns.map { money($0.income) } + [money(total.income)])
            for (account, _) in total.expenses where abs(total.expenses.first { $0.0.id == account.id }?.1 ?? 0) >= 0.005 {
                rows.append([account.name] + columns.map { c in money(c.expenses.first { $0.0.id == account.id }?.1 ?? 0) }
                            + [money(total.expenses.first { $0.0.id == account.id }?.1 ?? 0)])
            }
            rows.append(["Total Expenses"] + columns.map { money($0.totalExpenses) } + [money(total.totalExpenses)])
            rows.append(["NET INCOME"] + columns.map { money($0.net) } + [money(total.net)])
        } else {
            let period = selectedPLPeriod
            let f = plFigures(period)
            headers = ["Category", "Account", "Amount"]
            rows.append(["PERIOD", period.label, ""])
            rows.append(["", "", ""])
            rows.append(["INCOME", "", ""])
            rows.append(["Income", "Payments Received (cash basis)", money(f.income)])
            rows.append(["Total Income", "", money(f.income)])
            rows.append(["", "", ""])
            rows.append(["EXPENSES", "", ""])
            for (account, amount) in f.expenses where abs(amount) >= 0.005 {
                rows.append(["Expense", account.name, money(amount)])
            }
            rows.append(["Total Expenses", "", money(f.totalExpenses)])
            rows.append(["", "", ""])
            rows.append(["NET INCOME", "", money(f.net)])
        }

        let exporter = JournalCSVExporter()
        let data = exporter.makeCSV(headers: headers, rows: rows)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileTag = plMode == .eachMonth ? "\(plYear)-by-month" : selectedPLPeriod.label.replacingOccurrences(of: " ", with: "-")
        let url = dir.appendingPathComponent("ProfitAndLoss-\(fileTag).csv")
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

    /// Period for the P&L page of the Balance Sheet PDF / print: the one selected
    /// on the Reports tab (Each Month prints that year's YTD).
    private var pdfPLPeriod: PLPeriod {
        plMode == .eachMonth ? .ytd(year: plYear) : selectedPLPeriod
    }

    private func exportBalanceSheetPDF() -> URL? {
        let bs = calculator.balanceSheetDetailed()
        let period = pdfPLPeriod
        let pl = calculator.profitAndLoss(start: period.start, end: period.end)
        let data = BKReportsPDF.renderBalanceSheet(bs: bs, pl: pl, salesRevenue: plFigures(period).income,
                                                   periodLabel: period.label)
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
        let period = pdfPLPeriod
        let pl = calculator.profitAndLoss(start: period.start, end: period.end)
        let data = BKReportsPDF.renderBalanceSheet(bs: bs, pl: pl, salesRevenue: plFigures(period).income,
                                                   periodLabel: period.label)
        dpPrint(data: data, jobName: "Balance Sheet & P&L")
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

// MARK: - Edit Entry (date + memo only)

/// Changes only an entry's date and memo — amounts and accounts are left alone,
/// so the books stay balanced. Used to move a payment to the month the money
/// actually arrived (cash-basis P&L reads the entry date).
struct BKEditEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let entry: SDJournalEntry

    @State private var date: Date = Date()
    @State private var memo: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Entry Date", selection: $date, displayedComponents: .date)
                    Text("Was \(entry.date.formatted(date: .long, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Memo") {
                    TextField("Memo", text: $memo)
                }
                Section("Lines (not changed)") {
                    ForEach(entry.sortedLines) { line in
                        HStack {
                            Text(line.memo.isEmpty ? "Line" : line.memo).font(.caption)
                            Spacer()
                            Text(line.debit > 0 ? "Dr \(line.debit.currencyString())" : "Cr \(line.credit.currencyString())")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear { date = entry.date; memo = entry.memo }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        // Keep local noon so the day doesn't shift between time zones/devices.
        let cal = Calendar.current
        let day = cal.dateComponents([.year, .month, .day], from: date)
        entry.date = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? date
        entry.memo = memo
        entry.updatedAt = Date()
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
