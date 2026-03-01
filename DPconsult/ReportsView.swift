//
//  ReportsView.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/10/25.
//

import SwiftUI
import SwiftData
import UIKit

struct DPReportsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum Report: String, CaseIterable, Identifiable {
        case sales = "Sales Summary"
        case aging = "Aging (Unpaid)"
        case customer = "Customer Balances"
        case services = "Service Breakdown"
        var id: String { rawValue }
    }

    // Filters
    enum RangePreset: String, CaseIterable, Identifiable {
        case last12 = "Last 12 Months"
        case ytd = "Year to Date"
        case all = "All Time"
        var id: String { rawValue }
    }

    @State private var selectedReport: Report = .sales
    @State private var preset: RangePreset = .last12
    @State private var startDate: Date = Calendar.current.date(byAdding: .month, value: -11, to: firstOfMonth(Date()))!
    @State private var endDate: Date = Date()

    // Data — live from SwiftData
    @Query(sort: \SDInvoice.issueDate, order: .reverse) private var invoices: [SDInvoice]
    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]
    @Query(sort: \SDService.name) private var services: [SDService]
    @Query(sort: \SDJournalEntry.date, order: .reverse) private var journalEntries: [SDJournalEntry]

    // PDF Export
    @State private var shareURL: URL?
    @State private var showShareError = false
    @State private var shareErrorMessage = ""

    @State private var shareItemURL: URL? = nil
    @State private var showingShareSheet = false

    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }

                Section("Report") {
                    Picker("Type", selection: $selectedReport) {
                        ForEach(Report.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Range") {
                    Picker("Preset", selection: $preset) {
                        ForEach(RangePreset.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .onChange(of: preset) { _, newValue in
                        switch newValue {
                        case .last12:
                            startDate = Calendar.current.date(byAdding: .month, value: -11, to: DPReportsView.firstOfMonth(Date()))!
                            endDate = Date()
                        case .ytd:
                            let now = Date()
                            startDate = DPReportsView.firstOfYear(now)
                            endDate = now
                        case .all:
                            startDate = Date(timeIntervalSince1970: 0)
                            endDate = Date()
                        }
                    }

                    DatePicker("Start", selection: $startDate, displayedComponents: [.date])
                    DatePicker("End", selection: $endDate, displayedComponents: [.date])
                }

                Section {
                    switch selectedReport {
                    case .sales:
                        SalesSummaryView(invoices: filteredInvoices(statuses: ["draft", "billable", "invoice", "sent", "partial", "paid"], windowed: preset != .all))
                    case .aging:
                        AgingView(invoices: filteredInvoices(statuses: ["invoice", "sent", "partial"], windowed: false), customers: customers)
                    case .customer:
                        CustomerBalancesView(invoices: filteredInvoices(statuses: ["invoice", "sent", "partial"], windowed: false), customers: customers)
                    case .services:
                        ServiceBreakdownView(invoices: filteredInvoices(statuses: ["draft", "billable", "invoice", "sent", "partial", "paid"], windowed: preset != .all))
                    }
                }
            }
            .navigationTitle("DP Reports")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let data = DPReportPDF.render(reportData: getReportData())
                        dpPrint(data: data, jobName: "Report")
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportToPDF()
                    } label: {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportAllInvoicesCSV()
                    } label: {
                        Label("Share Invoices CSV", systemImage: "doc.text")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportAllInvoiceDetailsCSV()
                    } label: {
                        Label("Share Invoice Details CSV", systemImage: "doc.plaintext")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportAllInvoicesPDF()
                    } label: {
                        Label("Share All Invoices PDF", systemImage: "list.bullet.rectangle.portrait")
                    }
                }
            }
            .alert("Share Error", isPresented: $showShareError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareErrorMessage)
            }
            .sheet(isPresented: $showingShareSheet, onDismiss: { shareItemURL = nil }) {
                if let url = shareItemURL {
                    DPShareSheetView(activityItems: [url]) { _ in
                        showingShareSheet = false
                        shareItemURL = nil
                    }
                    .presentationSizing(.form)
                } else {
                    Color.clear.onAppear {
                        showingShareSheet = false
                        shareErrorMessage = "No file to share. Please export again."
                        showShareError = true
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func filteredInvoices(statuses: [String], windowed: Bool) -> [SDInvoice] {
        let base = invoices.filter { statuses.contains($0.status.lowercased()) }
        guard windowed else { return base }
        return base.filter { inv in
            let date = inv.issueDate
            return date >= startDate && date <= endDate
        }
    }

    // MARK: - PDF Export

    private func exportToPDF() {
        error = nil
        let reportData = getReportData()
        do {
            let url = try generateReportPDF(reportData: reportData)
            if FileManager.default.fileExists(atPath: url.path) {
                self.shareItemURL = url
                self.showingShareSheet = true
            } else {
                self.shareErrorMessage = "PDF file could not be found after rendering."
                self.showShareError = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func getReportData() -> ReportData {
        let filtered = filteredInvoices(statuses: getStatusesForCurrentReport(), windowed: getWindowedForCurrentReport())

        return ReportData(
            reportType: selectedReport,
            invoices: filtered,
            customers: customers,
            services: services,
            startDate: startDate,
            endDate: endDate,
            preset: preset,
            bsBalances: nil,
            plSummary: nil
        )
    }

    private func getStatusesForCurrentReport() -> [String] {
        switch selectedReport {
        case .sales:
            return ["draft", "billable", "invoice", "sent", "partial", "paid"]
        case .services:
            return ["draft", "billable", "invoice", "sent", "partial", "paid"]
        case .aging, .customer:
            return ["invoice", "sent", "partial"]
        }
    }

    private func getWindowedForCurrentReport() -> Bool {
        switch selectedReport {
        case .sales, .services:
            return preset != .all
        case .aging, .customer:
            return false
        }
    }

    private func generateReportPDF(reportData: ReportData) throws -> URL {
        let data = DPReportPDF.render(reportData: reportData)
        let fileName = "\(reportData.reportType.rawValue.replacingOccurrences(of: " ", with: "_"))-\(formatDateForFilename(Date())).pdf"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }

    private func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor
    private func presentShare(for url: URL) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            shareErrorMessage = "PDF file is missing. Please regenerate and try again."
            showShareError = true
            return
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                shareErrorMessage = "PDF is empty. Please regenerate."
                showShareError = true
                return
            }
        } catch {
            shareErrorMessage = "Unable to read PDF file attributes."
            showShareError = true
            return
        }
        self.shareItemURL = url
        self.showingShareSheet = true
    }

    // MARK: - Invoices CSV (All, grouped by status)
    private func exportAllInvoicesCSV() {
        do {
            // Build a quick lookup of payments from bookkeeping entries
            var paymentsByInvoice: [Int: Double] = [:]
            for entry in journalEntries {
                let pattern = "#(\\d+)"
                if let re = try? NSRegularExpression(pattern: pattern, options: []) {
                    let memo = entry.memo
                    let nsMemo = memo as NSString
                    let matches = re.matches(in: memo, options: [], range: NSRange(location: 0, length: nsMemo.length))
                    for m in matches {
                        if m.numberOfRanges > 1 {
                            let numStr = nsMemo.substring(with: m.range(at: 1))
                            if let num = Int(numStr) {
                                let lines = entry.sortedLines
                                let totalDeb = lines.reduce(0) { $0 + $1.debit }
                                let totalCred = lines.reduce(0) { $0 + $1.credit }
                                let amt = max(totalDeb, totalCred)
                                paymentsByInvoice[num] = max(paymentsByInvoice[num] ?? 0, amt)
                            }
                        }
                    }
                }
            }

            // Group invoices by status (case-insensitive)
            let grouped = Dictionary(grouping: invoices) { $0.status.lowercased() }
            let order = ["draft", "billable", "invoice", "sent", "partial", "paid"]
            let orderedKeys = grouped.keys.sorted { (a, b) in
                let ia = order.firstIndex(of: a) ?? Int.max
                let ib = order.firstIndex(of: b) ?? Int.max
                return ia == ib ? a < b : ia < ib
            }

            // Build CSV rows
            var rows: [[String]] = []
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            func nameFor(_ inv: SDInvoice) -> String { inv.customer?.name ?? "Customer" }

            for key in orderedKeys {
                let displayStatus = key.capitalized
                // Group header row
                rows.append(["STATUS: \(displayStatus)", "", "", "", "", "", "", ""])
                // Data rows for this status
                for inv in (grouped[key] ?? []).sorted(by: { $0.issueDate < $1.issueDate }) {
                    let num = "#\(inv.invoiceNumber)"
                    let customer = nameFor(inv)
                    let issue = df.string(from: inv.issueDate)
                    let due = inv.dueDate.map { df.string(from: $0) } ?? ""

                    let items = inv.sortedItems
                    let itemsSum = items.reduce(0) { $0 + $1.amount }
                    let baseTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
                    let paidRaw = inv.amountPaid
                    let correctedBalance = max(0, baseTotal - paidRaw)
                    let total = String(format: "%.2f", baseTotal)
                    let paid = String(format: "%.2f", paidRaw)
                    let balance = String(format: "%.2f", correctedBalance)

                    rows.append([num, displayStatus, customer, issue, due, total, paid, balance])
                }
                // Blank spacer row between groups
                rows.append(["", "", "", "", "", "", "", ""])
            }

            // Headers
            let headers = ["Invoice #", "Status", "Customer", "Issue Date", "Due Date", "Total", "Paid", "Balance"]
            let exporter = JournalCSVExporter()
            let data = exporter.makeCSV(headers: headers, rows: rows)

            // Write to Documents and present share sheet
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = dir.appendingPathComponent("AllInvoices.csv")
            try data.write(to: url, options: .atomic)
            presentShare(for: url)
        } catch {
            self.error = "Failed to export Invoices CSV: \(error.localizedDescription)"
        }
    }

    private func extractInvoiceNumber(from memo: String) -> Int? {
        let pattern = "#(\\d+)"
        if let re = try? NSRegularExpression(pattern: pattern, options: []),
           let m = re.firstMatch(in: memo, options: [], range: NSRange(location: 0, length: (memo as NSString).length)) {
            let ns = memo as NSString
            let numStr = ns.substring(with: m.range(at: 1))
            return Int(numStr)
        }
        return nil
    }

    // MARK: - All Invoice Details CSV (invoices, line items, and payment info if available)
    private func exportAllInvoiceDetailsCSV() {
        do {
            // Build a quick lookup of payments from bookkeeping entries
            var paymentsMap: [Int: (date: Date, memo: String, amount: Double)] = [:]
            for entry in journalEntries {
                if let num = extractInvoiceNumber(from: entry.memo) {
                    let lines = entry.sortedLines
                    let totalDeb = lines.reduce(0) { $0 + $1.debit }
                    let totalCred = lines.reduce(0) { $0 + $1.credit }
                    let amt = max(totalDeb, totalCred)
                    paymentsMap[num] = (entry.date, entry.memo, amt)
                }
            }

            // Prepare CSV headers and rows
            let headers = [
                "RowType","Invoice #","Status","Customer","Issue Date","Due Date","Subtotal","Tax","Total","Amount Paid","Balance","Invoice Notes",
                "Line Description","Line Qty","Line Rate","Line Amount","Line Notes",
                "Payment Date","Payment Memo","Payment Amount"
            ]
            var rows: [[String]] = []
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            func nameFor(_ inv: SDInvoice) -> String { inv.customer?.name ?? "Customer" }

            for inv in invoices.sorted(by: { $0.issueDate < $1.issueDate }) {
                let numStr = "#\(inv.invoiceNumber)"
                let customer = nameFor(inv)
                let issue = df.string(from: inv.issueDate)
                let due = inv.dueDate.map { df.string(from: $0) } ?? ""
                let subtotal = String(format: "%.2f", inv.subtotal)
                let tax = String(format: "%.2f", inv.tax)
                let total = String(format: "%.2f", inv.total)
                let paid = String(format: "%.2f", inv.amountPaid)
                let balance = String(format: "%.2f", inv.balance)
                let notes = inv.notes

                var payDate = ""; var payMemo = ""; var payAmt = ""
                if let p = paymentsMap[inv.invoiceNumber] {
                    payDate = df.string(from: p.date)
                    payMemo = p.memo
                    payAmt = String(format: "%.2f", inv.amountPaid)
                }

                // Invoice header row
                rows.append([
                    "INVOICE", numStr, inv.status.capitalized, customer, issue, due, subtotal, tax, total, paid, balance, notes,
                    "", "", "", "", "", payDate, payMemo, payAmt
                ])

                // Line item rows
                for item in inv.sortedItems {
                    let qtyStr = item.qty == floor(item.qty) ? String(Int(item.qty)) : String(format: "%.2f", item.qty)
                    let rateStr = String(format: "%.2f", item.rate)
                    let amtStr = String(format: "%.2f", item.amount)
                    let cleanNotes = item.notes.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                    rows.append([
                        "LINE", numStr, inv.status.capitalized, customer, issue, due, "", "", "", "", "", "",
                        item.itemDescription, qtyStr, rateStr, amtStr, cleanNotes, "", "", ""
                    ])
                }
                // Spacer row after each invoice block for readability
                rows.append([String](repeating: "", count: headers.count))
            }

            // Export using existing CSV exporter
            let exporter = JournalCSVExporter()
            let data = exporter.makeCSV(headers: headers, rows: rows)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = dir.appendingPathComponent("AllInvoiceDetails.csv")
            try data.write(to: url, options: .atomic)
            presentShare(for: url)
        } catch {
            self.error = "Failed to export All Invoice Details CSV: \(error.localizedDescription)"
        }
    }

    // MARK: - All Invoices PDF
    private func exportAllInvoicesPDF() {
        do {
            let data = AllInvoicesPDF.render(invoices: invoices, customers: customers)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = dir.appendingPathComponent("AllInvoices.pdf")
            try data.write(to: url, options: .atomic)
            presentShare(for: url)
        } catch {
            self.error = "Failed to export All Invoices PDF: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    static func firstOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    static func firstOfYear(_ date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year], from: date)
        comps.month = 1; comps.day = 1
        return cal.date(from: comps) ?? date
    }
}

// MARK: - Sales Summary

private struct SalesSummaryView: View {
    let invoices: [SDInvoice]
    private let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "yyyy-MM"
        return d
    }()

    var body: some View {
        if invoices.isEmpty {
            Text("No invoices in range.").foregroundStyle(.secondary)
        } else {
            let monthly = groupByMonth(invoices)
            let total = monthly.values.reduce(0, +)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Total").bold(); Spacer(); Text(money(total)).bold() }
                Divider()
                ForEach(monthly.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k)
                        Spacer()
                        Text(money(monthly[k] ?? 0))
                    }
                }
            }
        }
    }

    private func groupByMonth(_ invs: [SDInvoice]) -> [String: Double] {
        var out: [String: Double] = [:]
        for inv in invs {
            let d = inv.issueDate
            let key = df.string(from: d)
            let items = inv.sortedItems
            let itemsSum = items.reduce(0) { $0 + $1.amount }
            let correctedTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
            out[key, default: 0] += correctedTotal
        }
        return out
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }
}
// MARK: - Aging (Unpaid)

private struct AgingView: View {
    let invoices: [SDInvoice]   // unpaid only
    let customers: [SDCustomer]

    var body: some View {
        if invoices.isEmpty {
            Text("No unpaid invoices.").foregroundStyle(.secondary)
        } else {
            let buckets = bucketize(invoices)
            VStack(alignment: .leading, spacing: 10) {
                row("0–30", buckets.zeroTo30.total)
                row("31–60", buckets._31To60.total)
                row("61–90", buckets._61To90.total)
                row("90+", buckets._90Plus.total)
                Divider().padding(.vertical, 6)

                // Optional details
                if !buckets._90Plus.items.isEmpty {
                    Text("90+ Days").font(.headline)
                    ForEach(buckets._90Plus.items, id: \.id) { inv in
                        NavigationLink(destination: DPInvoicingView(existing: inv)) {
                            HStack {
                                Text("#\(inv.invoiceNumber) - \(inv.customer?.name ?? "Customer")")
                                Spacer()
                                Text(money(inv.balance))
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ amt: Double) -> some View {
        HStack { Text(title); Spacer(); Text(money(amt)).fontWeight(.semibold) }
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    private typealias Bucket = (items: [SDInvoice], total: Double)

    private func bucketize(_ invs: [SDInvoice]) -> (zeroTo30: Bucket, _31To60: Bucket, _61To90: Bucket, _90Plus: Bucket) {
        var b0: [SDInvoice] = []; var b1: [SDInvoice] = []; var b2: [SDInvoice] = []; var b3: [SDInvoice] = []
        let now = Calendar.current.startOfDay(for: Date())
        for inv in invs {
            let basisDate = inv.dueDate ?? inv.issueDate
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: basisDate), to: now).day ?? 0
            let ageDays = max(0, days)
            switch ageDays {
            case 0...30: b0.append(inv)
            case 31...60: b1.append(inv)
            case 61...90: b2.append(inv)
            default: b3.append(inv)
            }
        }
        return (
            (b0, b0.reduce(0) { $0 + $1.balance }),
            (b1, b1.reduce(0) { $0 + $1.balance }),
            (b2, b2.reduce(0) { $0 + $1.balance }),
            (b3, b3.reduce(0) { $0 + $1.balance })
        )
    }
}

// MARK: - Customer Balances (Unpaid)

private struct CustomerBalancesView: View {
    let invoices: [SDInvoice]  // unpaid only
    let customers: [SDCustomer]

    var body: some View {
        if invoices.isEmpty {
            Text("No unpaid invoices.").foregroundStyle(.secondary)
        } else {
            let totals = byCustomer(invoices)
            let overall = totals.values.reduce(0, +)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Total Outstanding").bold(); Spacer(); Text(money(overall)).bold() }
                Divider()
                ForEach(totals.keys.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(money(totals[name] ?? 0))
                    }
                }
            }
        }
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    private func byCustomer(_ invs: [SDInvoice]) -> [String: Double] {
        var out: [String: Double] = [:]
        for inv in invs {
            let name = inv.customer?.name ?? "Customer"
            out[name, default: 0] += inv.balance
        }
        return out
    }
}

// MARK: - Service Breakdown

private struct ServiceBreakdownView: View {
    let invoices: [SDInvoice] // invoice + paid

    var body: some View {
        if invoices.isEmpty {
            Text("No invoices in range.").foregroundStyle(.secondary)
        } else {
            let map = byService(invoices)
            let sorted = map.keys.sorted { (map[$0] ?? 0) > (map[$1] ?? 0) }
            let overall = map.values.reduce(0, +)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Total").bold(); Spacer(); Text(money(overall)).bold() }
                Divider()
                ForEach(sorted, id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(money(map[key] ?? 0))
                    }
                }
            }
        }
    }

    private func byService(_ invs: [SDInvoice]) -> [String: Double] {
        var out: [String: Double] = [:]
        for inv in invs {
            for it in inv.sortedItems {
                out[it.itemDescription, default: 0] += it.qty * it.rate
            }
        }
        return out
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }
}

// Convenience
private func firstOfMonth(_ date: Date) -> Date {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month], from: date)
    return cal.date(from: comps) ?? date
}

// MARK: - Report Data Structure

struct ReportData {
    let reportType: DPReportsView.Report
    let invoices: [SDInvoice]
    let customers: [SDCustomer]
    let services: [SDService]
    let startDate: Date
    let endDate: Date
    let preset: DPReportsView.RangePreset

    let bsBalances: (assets: [(SDAccount, Double)], liabilities: [(SDAccount, Double)], equity: [(SDAccount, Double)])?
    let plSummary: (income: [(SDAccount, Double)], expenses: [(SDAccount, Double)], net: Double)?
}

// MARK: - Report PDF Generator

enum DPReportPDF {
    static func render(reportData: ReportData) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
        let margin: CGFloat = 36

        // Theme (matching invoice style)
        let brandBlue = UIColor.systemBlue
        let brandOrange = UIColor.systemOrange
        let hairline = UIColor.black.withAlphaComponent(0.18).cgColor

        // Fonts
        let h1 = UIFont.systemFont(ofSize: 24, weight: .bold)
        let body = UIFont.systemFont(ofSize: 12)
        let small = UIFont.systemFont(ofSize: 10)

        @discardableResult
        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let g = UIGraphicsGetCurrentContext()!
            var y = margin

            // Header
            let titleH = draw(reportData.reportType.rawValue, at: CGPoint(x: margin, y: y), font: h1, color: brandBlue)

            // Add orange accent bar
            g.setFillColor(brandOrange.cgColor)
            g.fill(CGRect(x: margin, y: y + titleH + 4, width: 120, height: 3))

            y += titleH + 20

            // Date range info
            let df = DateFormatter()
            df.dateStyle = .medium
            let rangeText = "Period: \(df.string(from: reportData.startDate)) - \(df.string(from: reportData.endDate))"
            let generatedText = "Generated: \(df.string(from: Date()))"

            y += draw(rangeText, at: CGPoint(x: margin, y: y), font: body)
            y += draw(generatedText, at: CGPoint(x: margin, y: y), font: small, color: .gray)
            y += 20

            // Divider
            g.setStrokeColor(hairline)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: y))
            g.addLine(to: CGPoint(x: page.width - margin, y: y))
            g.strokePath()
            y += 10

            // Report content based on type
            switch reportData.reportType {
            case .sales:
                y = drawSalesReport(reportData: reportData, startY: y, page: page, margin: margin, g: g)
            case .aging:
                y = drawAgingReport(reportData: reportData, startY: y, page: page, margin: margin, g: g)
            case .customer:
                y = drawCustomerReport(reportData: reportData, startY: y, page: page, margin: margin, g: g)
            case .services:
                y = drawServicesReport(reportData: reportData, startY: y, page: page, margin: margin, g: g)
            }

            // Footer
            let footerY = page.height - margin - 20
            g.setStrokeColor(hairline)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: footerY))
            g.addLine(to: CGPoint(x: page.width - margin, y: footerY))
            g.strokePath()

            let footerText = "DP Consulting Report"
            _ = draw(footerText, at: CGPoint(x: margin, y: footerY + 6), font: small, width: page.width - 2*margin, align: .center, color: .gray)
        }
    }

    private static func drawSalesReport(reportData: ReportData, startY: CGFloat, page: CGRect, margin: CGFloat, g: CGContext) -> CGFloat {
        var y = startY
        let body = UIFont.systemFont(ofSize: 12)
        let h2 = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let stripe = UIColor(white: 0.965, alpha: 1)

        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        // Group by month
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        var monthly: [String: Double] = [:]

        for inv in reportData.invoices {
            let d = inv.issueDate
            let key = df.string(from: d)
            let items = inv.sortedItems
            let itemsSum = items.reduce(0) { $0 + $1.amount }
            let correctedTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
            monthly[key, default: 0] += correctedTotal
        }

        if monthly.isEmpty {
            y += draw("No sales data for this period.", at: CGPoint(x: margin, y: y), font: body)
            return y
        }

        let total = monthly.values.reduce(0, +)

        // Header
        y += draw("Sales Summary", at: CGPoint(x: margin, y: y), font: h2)
        y += 10

        // Table header
        let headerH: CGFloat = 20
        g.setFillColor(UIColor.systemBlue.cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: headerH))

        let monthX = margin + 10
        let amountX = page.width - margin - 100

        _ = draw("Month", at: CGPoint(x: monthX, y: y + 4), font: body, color: .white)
        _ = draw("Amount", at: CGPoint(x: amountX, y: y), font: body, width: 90, align: .right, color: .white)
        y += headerH + 2

        // Rows
        let sortedKeys = monthly.keys.sorted()
        for (index, key) in sortedKeys.enumerated() {
            let rowH: CGFloat = 18

            // Stripe
            if index % 2 == 1 {
                g.setFillColor(stripe.cgColor)
                g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: rowH))
            }

            // Format month nicely
            let displayMonth = DateFormatter.monthYear.string(from: DateFormatter.yearMonth.date(from: key) ?? Date())

            y += draw(displayMonth, at: CGPoint(x: monthX, y: y + 2), font: body)
            _ = draw(money(monthly[key] ?? 0), at: CGPoint(x: amountX, y: y - 12), font: body, width: 90, align: .right)
            y += rowH - 12
        }

        // Total
        y += 10
        g.setFillColor(UIColor.systemOrange.withAlphaComponent(0.1).cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: 20))

        y += draw("Total", at: CGPoint(x: monthX, y: y + 4), font: h2)
        _ = draw(money(total), at: CGPoint(x: amountX, y: y), font: h2, width: 90, align: .right)
        y += 20

        return y
    }

    private static func drawAgingReport(reportData: ReportData, startY: CGFloat, page: CGRect, margin: CGFloat, g: CGContext) -> CGFloat {
        var y = startY
        let body = UIFont.systemFont(ofSize: 12)

        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        // Bucketize invoices
        typealias Bucket = (items: [SDInvoice], total: Double)
        var b0: [SDInvoice] = [], b1: [SDInvoice] = [], b2: [SDInvoice] = [], b3: [SDInvoice] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for inv in reportData.invoices {
            let basis = inv.dueDate ?? inv.issueDate
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: basis), to: today).day ?? 0
            let ageDays = max(0, days)
            switch ageDays {
            case 0...30: b0.append(inv)
            case 31...60: b1.append(inv)
            case 61...90: b2.append(inv)
            default: b3.append(inv)
            }
        }
        let buckets: [String: Bucket] = [
            "0-30 Days": (b0, b0.reduce(0) { $0 + $1.balance }),
            "31-60 Days": (b1, b1.reduce(0) { $0 + $1.balance }),
            "61-90 Days": (b2, b2.reduce(0) { $0 + $1.balance }),
            "90+ Days": (b3, b3.reduce(0) { $0 + $1.balance })
        ]

        if reportData.invoices.isEmpty {
            y += draw("No unpaid invoices.", at: CGPoint(x: margin, y: y), font: body)
            return y
        }

        // Header
        y += draw("Aging Report (Unpaid Invoices)", at: CGPoint(x: margin, y: y), font: UIFont.systemFont(ofSize: 16, weight: .semibold))
        y += 10

        // Summary table
        let headerH: CGFloat = 20
        g.setFillColor(UIColor.systemBlue.cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: headerH))

        let periodX = margin + 10
        let amountX = page.width - margin - 100

        _ = draw("Period", at: CGPoint(x: periodX, y: y + 4), font: body, color: .white)
        _ = draw("Amount", at: CGPoint(x: amountX, y: y), font: body, width: 90, align: .right, color: .white)
        y += headerH + 2

        let periods = ["0-30 Days", "31-60 Days", "61-90 Days", "90+ Days"]
        for (index, period) in periods.enumerated() {
            let rowH: CGFloat = 18

            if index % 2 == 1 {
                g.setFillColor(UIColor(white: 0.965, alpha: 1).cgColor)
                g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: rowH))
            }

            let bucket = buckets[period] ?? ([], 0)
            y += draw(period, at: CGPoint(x: periodX, y: y + 2), font: body)
            _ = draw(money(bucket.total), at: CGPoint(x: amountX, y: y - 12), font: body, width: 90, align: .right)
            y += rowH - 12
        }

        // Total
        let total = buckets.values.map { $0.total }.reduce(0, +)
        y += 10
        g.setFillColor(UIColor.systemOrange.withAlphaComponent(0.1).cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: 20))

        y += draw("Total Outstanding", at: CGPoint(x: periodX, y: y + 4), font: UIFont.systemFont(ofSize: 16, weight: .semibold))
        _ = draw(money(total), at: CGPoint(x: amountX, y: y), font: UIFont.systemFont(ofSize: 16, weight: .semibold), width: 90, align: .right)
        y += 30

        // Detailed 90+ days section
        if !b3.isEmpty {
            y += draw("90+ Days Detail", at: CGPoint(x: margin, y: y), font: UIFont.systemFont(ofSize: 16, weight: .semibold))
            y += 10

            for inv in b3 {
                let customerName = inv.customer?.name ?? "Customer"
                let line = "#\(inv.invoiceNumber) - \(customerName)"
                y += draw(line, at: CGPoint(x: margin + 10, y: y), font: body)
                _ = draw(money(inv.balance), at: CGPoint(x: amountX, y: y - 12), font: body, width: 90, align: .right)
            }
        }

        return y
    }

    private static func drawCustomerReport(reportData: ReportData, startY: CGFloat, page: CGRect, margin: CGFloat, g: CGContext) -> CGFloat {
        var y = startY
        let body = UIFont.systemFont(ofSize: 12)
        let h2 = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let stripe = UIColor(white: 0.965, alpha: 1)

        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        // Group by customer
        var customerTotals: [String: Double] = [:]
        for inv in reportData.invoices {
            let name = inv.customer?.name ?? "Customer"
            customerTotals[name, default: 0] += inv.balance
        }

        if customerTotals.isEmpty {
            y += draw("No unpaid invoices.", at: CGPoint(x: margin, y: y), font: body)
            return y
        }

        let total = customerTotals.values.reduce(0, +)

        // Header
        y += draw("Customer Balances (Unpaid)", at: CGPoint(x: margin, y: y), font: h2)
        y += 10

        // Table header
        let headerH: CGFloat = 20
        g.setFillColor(UIColor.systemBlue.cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: headerH))

        let customerX = margin + 10
        let amountX = page.width - margin - 100

        _ = draw("Customer", at: CGPoint(x: customerX, y: y + 4), font: body, color: .white)
        _ = draw("Outstanding", at: CGPoint(x: amountX, y: y), font: body, width: 90, align: .right, color: .white)
        y += headerH + 2

        // Sort by amount descending
        let sorted = customerTotals.keys.sorted { (customerTotals[$0] ?? 0) > (customerTotals[$1] ?? 0) }

        for (index, customerName) in sorted.enumerated() {
            let rowH: CGFloat = 18

            if index % 2 == 1 {
                g.setFillColor(stripe.cgColor)
                g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: rowH))
            }

            let amount = customerTotals[customerName] ?? 0

            y += draw(customerName, at: CGPoint(x: customerX, y: y + 2), font: body)
            _ = draw(money(amount), at: CGPoint(x: amountX, y: y - 12), font: body, width: 90, align: .right)
            y += rowH - 12
        }

        // Total
        y += 10
        g.setFillColor(UIColor.systemOrange.withAlphaComponent(0.1).cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: 20))

        y += draw("Total Outstanding", at: CGPoint(x: customerX, y: y + 4), font: h2)
        _ = draw(money(total), at: CGPoint(x: amountX, y: y), font: h2, width: 90, align: .right)
        y += 20

        return y
    }

    private static func drawServicesReport(reportData: ReportData, startY: CGFloat, page: CGRect, margin: CGFloat, g: CGContext) -> CGFloat {
        var y = startY
        let body = UIFont.systemFont(ofSize: 12)
        let h2 = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let stripe = UIColor(white: 0.965, alpha: 1)

        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        // Group by service
        var serviceTotals: [String: Double] = [:]
        for inv in reportData.invoices {
            for item in inv.sortedItems {
                serviceTotals[item.itemDescription, default: 0] += item.qty * item.rate
            }
        }

        if serviceTotals.isEmpty {
            y += draw("No service data for this period.", at: CGPoint(x: margin, y: y), font: body)
            return y
        }

        let total = serviceTotals.values.reduce(0, +)

        // Header
        y += draw("Service Breakdown", at: CGPoint(x: margin, y: y), font: h2)
        y += 10

        // Table header
        let headerH: CGFloat = 20
        g.setFillColor(UIColor.systemBlue.cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: headerH))

        let serviceX = margin + 10
        let amountX = page.width - margin - 100

        _ = draw("Service", at: CGPoint(x: serviceX, y: y + 4), font: body, color: .white)
        _ = draw("Revenue", at: CGPoint(x: amountX, y: y), font: body, width: 90, align: .right, color: .white)
        y += headerH + 2

        // Sort by amount descending
        let sorted = serviceTotals.keys.sorted { (serviceTotals[$0] ?? 0) > (serviceTotals[$1] ?? 0) }

        for (index, service) in sorted.enumerated() {
            let rowH: CGFloat = 18

            if index % 2 == 1 {
                g.setFillColor(stripe.cgColor)
                g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: rowH))
            }

            let amount = serviceTotals[service] ?? 0

            y += draw(service, at: CGPoint(x: serviceX, y: y + 2), font: body)
            _ = draw(money(amount), at: CGPoint(x: amountX, y: y - 12), font: body, width: 90, align: .right)
            y += rowH - 12
        }

        // Total
        y += 10
        g.setFillColor(UIColor.systemOrange.withAlphaComponent(0.1).cgColor)
        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: 20))

        y += draw("Total Revenue", at: CGPoint(x: serviceX, y: y + 4), font: h2)
        _ = draw(money(total), at: CGPoint(x: amountX, y: y), font: h2, width: 90, align: .right)
        y += 20

        return y
    }
}

// Date formatter extensions for cleaner formatting
private extension DateFormatter {
    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    static let yearMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

// MARK: - SharePresenter and ControllerResolver

private final class SharePresenter: ObservableObject {
    @Published var isPresenting = false
    weak var controller: UIViewController?
    func attach(_ controller: UIViewController) { self.controller = controller }
    @MainActor
    func present(url: URL) {
        guard !isPresenting else { return }
        guard let controller else { return }
        isPresenting = true
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = controller.view
            pop.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        DispatchQueue.main.async {
            controller.present(avc, animated: true)
        }
        avc.completionWithItemsHandler = { [weak self] _, _, _, _ in
            Task { @MainActor in self?.isPresenting = false }
        }
    }
}
private struct ControllerResolver: UIViewControllerRepresentable {
    let onResolve: (UIViewController) -> Void
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async { onResolve(vc) }
        vc.view.isHidden = true
        vc.view.isUserInteractionEnabled = false
        return vc
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

// DPShareSheetView is defined in ActivityView.swift
