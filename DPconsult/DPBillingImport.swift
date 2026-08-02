//
//  DPBillingImport.swift
//  DPconsult
//
//  Reads a monthly work-summary HTML file and produces pre-filled invoice line
//  items — one per week, with that week's deliverables attached as client-facing
//  notes, plus a Professional Discount line computed from a target total.
//
//  Nothing here writes to SwiftData. The drafts are handed to DPInvoicingView,
//  which stays the only thing that saves.
//
//  Spec: docs/superpowers/specs/2026-08-02-billing-summary-import-design.md
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

private let importLog = Logger(subsystem: "com.dan.DPconsult", category: "billingImport")

// MARK: - Parsed model

struct BillingWeek: Identifiable, Hashable {
    var id = UUID()
    var label: String = ""
    var focus: String = ""
    var commits: Int = 0
    var hours: Double = 0
    var month: Int = 0
    var startDay: Int = 0
    var endDay: Int = 0
    var notes: String = ""
}

struct BillingDeliverable: Hashable {
    var month: Int
    var startDay: Int
    var endDay: Int
    var text: String
}

struct BillingSummary {
    var title: String
    var weeks: [BillingWeek]
    var statedTotalHours: Double?
    var deliverables: [BillingDeliverable]
    var invoiceBlurb: String?
}

struct BillingTotals {
    var grossHours: Double
    var grossAmount: Double
    /// Positive magnitude of the discount; zero when no discount line is wanted.
    var discount: Double
    var total: Double
}

enum BillingSummaryParseError: Error, Equatable, LocalizedError {
    case unreadableFile
    case noTable
    case noRows

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "That file could not be read as text."
        case .noTable:
            return "Couldn't find an \u{201C}Hours by week\u{201D} table in that file."
        case .noRows:
            return "Found the \u{201C}Hours by week\u{201D} table, but no week rows in it."
        }
    }
}

// MARK: - HTML text helpers

/// Small, dependency-free HTML scraping helpers. Deliberately not a general HTML
/// parser — it handles the shape of the generated work-summary files and nothing more.
enum BillingHTML {

    /// Every `<tag …>inner</tag>` pair at any depth, in document order.
    static func slices(of tag: String, in html: some StringProtocol) -> [(attrs: String, inner: String)] {
        let source = String(html)
        var result: [(attrs: String, inner: String)] = []
        var cursor = source.startIndex
        let open = "<\(tag)"
        let close = "</\(tag)>"

        while cursor < source.endIndex,
              let openRange = source.range(of: open, options: .caseInsensitive,
                                           range: cursor..<source.endIndex) {
            // The character after the tag name must not be alphanumeric, or "<t"
            // would match "<table" when looking for "<td".
            if openRange.upperBound < source.endIndex,
               let next = source[openRange.upperBound...].first,
               next.isLetter || next.isNumber {
                cursor = openRange.upperBound
                continue
            }
            guard let gt = source.range(of: ">", options: [],
                                        range: openRange.upperBound..<source.endIndex) else { break }
            guard let closeRange = source.range(of: close, options: .caseInsensitive,
                                                range: gt.upperBound..<source.endIndex) else { break }
            result.append((attrs: String(source[openRange.upperBound..<gt.lowerBound]),
                           inner: String(source[gt.upperBound..<closeRange.lowerBound])))
            cursor = closeRange.upperBound
        }
        return result
    }

    /// Content of the first `<table>` following the given heading text.
    static func tableFollowing(heading: String, in html: String) -> String? {
        guard let head = html.range(of: heading, options: .caseInsensitive) else { return nil }
        let rest = String(html[head.upperBound...])
        guard let tableStart = rest.range(of: "<table", options: .caseInsensitive),
              let gt = rest.range(of: ">", options: [], range: tableStart.upperBound..<rest.endIndex),
              let tableEnd = rest.range(of: "</table>", options: .caseInsensitive,
                                        range: gt.upperBound..<rest.endIndex)
        else { return nil }
        return String(rest[gt.upperBound..<tableEnd.lowerBound])
    }

    static func stripTags(_ s: some StringProtocol) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" {
                inTag = true
                out.append(" ")          // keep adjacent-tag text from fusing
            } else if ch == ">" {
                inTag = false
            } else if !inTag {
                out.append(ch)
            }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var out = decodeNumericEntities(s)
        // &amp; must be last so "&amp;lt;" doesn't become "<".
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&ndash;", "\u{2013}"), ("&mdash;", "\u{2014}"),
            ("&middot;", "\u{00B7}"), ("&rarr;", "\u{2192}"), ("&amp;", "&")
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        var i = s.startIndex

        while i < s.endIndex {
            let hash = s.index(after: i)
            guard s[i] == "&",
                  hash < s.endIndex, s[hash] == "#",
                  let bodyStart = s.index(i, offsetBy: 2, limitedBy: s.endIndex),
                  bodyStart < s.endIndex
            else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }

            // A numeric entity is short; don't scan the rest of the document for ";".
            let scanEnd = s.index(bodyStart, offsetBy: 10, limitedBy: s.endIndex) ?? s.endIndex
            guard let semi = s[bodyStart..<scanEnd].firstIndex(of: ";") else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }

            let body = String(s[bodyStart..<semi])
            let value: UInt32? = (body.first == "x" || body.first == "X")
                ? UInt32(body.dropFirst(), radix: 16)
                : UInt32(body, radix: 10)

            if let value, let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Closing an inline tag inserts a separator space, which leaves "<b>Foo</b>, bar"
    /// reading as "Foo , bar". Pull punctuation back onto the preceding word.
    static func tightenPunctuation(_ s: String) -> String {
        var out = s
        for mark in [",", ";", ":", "!", "?", ")", "%"] {
            out = out.replacingOccurrences(of: " \(mark)", with: mark)
        }
        // Sentence-ending periods only — " .xlsx" and " .com" keep their space.
        out = out.replacingOccurrences(of: " \\.(?=\\s|$)", with: ".",
                                       options: .regularExpression)
        return out.replacingOccurrences(of: "( ", with: "(")
    }

    /// Strip tags, decode entities, collapse runs of whitespace, tidy punctuation, trim.
    static func clean(_ s: some StringProtocol) -> String {
        tightenPunctuation(collapseWhitespace(decodeEntities(stripTags(s))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every run of digits, in order. "7-25 → 7-27" → [7, 25, 7, 27]
    static func integers(in s: some StringProtocol) -> [Int] {
        var result: [Int] = []
        var current = ""
        for ch in s {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if let v = Int(current) { result.append(v) }
                current = ""
            }
        }
        if !current.isEmpty, let v = Int(current) { result.append(v) }
        return result
    }

    /// First contiguous run of digits and dots. "90.0 h" → 90.0
    static func number(in s: some StringProtocol) -> Double? {
        var current = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else if !current.isEmpty {
                break
            }
        }
        return Double(current)
    }

    private static let monthPrefixes = ["jan", "feb", "mar", "apr", "may", "jun",
                                        "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Month number from a leading month name. "Jul 1 – 5" → 7. Unknown → 0.
    static func monthNumber(inLabel label: some StringProtocol) -> Int {
        let letters = label.lowercased().prefix { $0.isLetter }
        guard letters.count >= 3 else { return 0 }
        let key = String(letters.prefix(3))
        guard let index = monthPrefixes.firstIndex(of: key) else { return 0 }
        return index + 1
    }
}

// MARK: - Parser

enum BillingSummaryParser {

    static func parse(_ html: String) throws(BillingSummaryParseError) -> BillingSummary {
        let title = BillingHTML.slices(of: "h1", in: html).first
            .map { BillingHTML.clean($0.inner) } ?? ""

        let (weeksParsed, statedTotal) = try parseWeeks(html)
        var weeks = weeksParsed

        let deliverables = parseDeliverables(html)
        attachNotes(to: &weeks, from: deliverables)

        return BillingSummary(title: title,
                              weeks: weeks,
                              statedTotalHours: statedTotal,
                              deliverables: deliverables,
                              invoiceBlurb: parseInvoiceBlurb(html))
    }

    // MARK: Hours by week (required)

    static func parseWeeks(_ html: String) throws(BillingSummaryParseError) -> ([BillingWeek], Double?) {
        guard let table = BillingHTML.tableFollowing(heading: "Hours by week", in: html) else {
            throw BillingSummaryParseError.noTable
        }

        var weeks: [BillingWeek] = []
        var statedTotal: Double?

        for row in BillingHTML.slices(of: "tr", in: table) {
            if row.inner.range(of: "<th", options: .caseInsensitive) != nil { continue }

            let cells = BillingHTML.slices(of: "td", in: row.inner).map { BillingHTML.clean($0.inner) }
            guard cells.count >= 4 else { continue }

            // The summary's total row carries class="tot".
            if row.attrs.range(of: "tot", options: .caseInsensitive) != nil {
                statedTotal = BillingHTML.number(in: cells[3])
                continue
            }

            let label = cells[0]
            let days = BillingHTML.integers(in: label)
            let startDay = days.first ?? 0

            weeks.append(BillingWeek(label: label,
                                     focus: cells[1],
                                     commits: Int(BillingHTML.number(in: cells[2]) ?? 0),
                                     hours: BillingHTML.number(in: cells[3]) ?? 0,
                                     month: BillingHTML.monthNumber(inLabel: label),
                                     startDay: startDay,
                                     endDay: days.count > 1 ? days[1] : startDay))
        }

        guard !weeks.isEmpty else { throw BillingSummaryParseError.noRows }
        return (weeks, statedTotal)
    }

    // MARK: Major deliverables (optional)

    static func parseDeliverables(_ html: String) -> [BillingDeliverable] {
        guard let table = BillingHTML.tableFollowing(heading: "Major deliverables", in: html) else {
            return []
        }

        var result: [BillingDeliverable] = []
        for row in BillingHTML.slices(of: "tr", in: table) {
            if row.inner.range(of: "<th", options: .caseInsensitive) != nil { continue }

            let cells = BillingHTML.slices(of: "td", in: row.inner)
            guard cells.count >= 2 else { continue }

            // Date forms seen in real files: "7-24", "7-25 → 7-27", "~6-25"
            let dateText = BillingHTML.clean(cells[0].inner).replacingOccurrences(of: "~", with: "")
            let parts = BillingHTML.integers(in: dateText)

            let month: Int, startDay: Int, endDay: Int
            if parts.count >= 4 {
                month = parts[0]
                startDay = parts[1]
                // A range crossing months is clamped rather than dropped.
                endDay = parts[2] == parts[0] ? parts[3] : 31
            } else if parts.count >= 2 {
                month = parts[0]
                startDay = parts[1]
                endDay = parts[1]
            } else {
                continue
            }

            let text = BillingHTML.clean(cells[1].inner)
            guard !text.isEmpty else { continue }

            result.append(BillingDeliverable(month: month, startDay: startDay,
                                             endDay: endDay, text: text))
        }
        return result
    }

    /// A deliverable spanning a week boundary lands in both weeks. Intentional —
    /// the client is reading what a week's hours went to, not a partition.
    static func attachNotes(to weeks: inout [BillingWeek], from deliverables: [BillingDeliverable]) {
        for index in weeks.indices {
            let week = weeks[index]
            let overlapping = deliverables.filter {
                $0.month == week.month
                    && $0.startDay <= week.endDay
                    && $0.endDay >= week.startDay
            }
            weeks[index].notes = overlapping.map(\.text).joined(separator: " \u{00B7} ")
        }
    }

    // MARK: For the invoice (optional)

    static func parseInvoiceBlurb(_ html: String) -> String? {
        guard let table = BillingHTML.tableFollowing(heading: "For the invoice", in: html),
              let firstCell = BillingHTML.slices(of: "td", in: table).first
        else { return nil }

        // The <br> separates the bold title from the grey detail line; keep them apart.
        var inner = firstCell.inner
        for tag in ["<br>", "<br/>", "<br />"] {
            inner = inner.replacingOccurrences(of: tag, with: " \u{2014} ", options: .caseInsensitive)
        }

        let text = BillingHTML.clean(inner)
        return text.isEmpty ? nil : text
    }

    // MARK: Totals

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    static func totals(weeks: [BillingWeek], rate: Double, target: Double?) -> BillingTotals {
        let grossHours = round2(weeks.reduce(0) { $0 + $1.hours })
        let grossAmount = round2(grossHours * rate)

        guard let target, target > 0, target < grossAmount - 0.005 else {
            return BillingTotals(grossHours: grossHours, grossAmount: grossAmount,
                                 discount: 0, total: grossAmount)
        }
        return BillingTotals(grossHours: grossHours, grossAmount: grossAmount,
                             discount: round2(grossAmount - target), total: round2(target))
    }
}

// MARK: - Customer matching

/// Free functions over plain strings so they stay testable without a SwiftData container.
enum BillingCustomerMatch {

    /// First letter of each word of 3+ letters.
    /// "Leadership in Disabilities & Achievement of Hawai'i" → "LDAH"
    static func acronym(for name: String) -> String {
        name.split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 3 }
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }

    static func matches(customerName: String, haystack: String) -> Bool {
        let name = customerName.lowercased()
        let hay = haystack.lowercased()
        guard !name.isEmpty, !hay.isEmpty else { return false }

        if hay.contains(name) { return true }

        // Any distinctive word of the customer's name appearing verbatim.
        for word in name.split(whereSeparator: { !$0.isLetter }) where word.count >= 4 {
            if hay.contains(word) { return true }
        }

        // Acronym as a standalone token: "LDAH" in "LDAH-July-2026-…"
        let initials = acronym(for: customerName).lowercased()
        guard initials.count >= 2 else { return false }
        let tokens = hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains { $0 == initials }
    }

    /// First name satisfying either rule, in the order given.
    static func best(in names: [String], haystack: String) -> String? {
        names.first { matches(customerName: $0, haystack: haystack) }
    }
}

// MARK: - Seed handed to the invoice editor

struct DPImportSeed: Identifiable {
    let id = UUID()
    let customer: SDCustomer
    let items: [DPInvoiceItemDraft]
    let notes: String
}

// MARK: - Import sheet

struct DPBillingImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]

    let onCreate: (DPImportSeed) -> Void

    @State private var showFileImporter = false
    @State private var fileName: String = ""
    @State private var summaryTitle: String = ""
    @State private var statedTotalHours: Double?
    @State private var weeks: [BillingWeek] = []
    @State private var invoiceNotes: String = ""
    @State private var selectedCustomer: SDCustomer?
    @State private var rateText: String = "50.00"
    @State private var targetText: String = ""
    @State private var errorMessage: String?

    private var rate: Double { Double(rateText) ?? 0 }
    private var target: Double? { targetText.isEmpty ? nil : Double(targetText) }
    private var totals: BillingTotals {
        BillingSummaryParser.totals(weeks: weeks, rate: rate, target: target)
    }

    private var targetExceedsGross: Bool {
        guard let target else { return false }
        return target < 0 || target > totals.grossAmount + 0.005
    }

    private var createDisabled: Bool {
        selectedCustomer == nil || weeks.isEmpty || rate <= 0 || targetExceedsGross
    }

    private var hoursMismatch: (parsed: Double, stated: Double)? {
        guard let stated = statedTotalHours else { return nil }
        let parsed = totals.grossHours
        return abs(parsed - stated) > 0.005 ? (parsed, stated) : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                if !weeks.isEmpty {
                    customerSection
                    weeksSection
                    notesSection
                    totalsSection
                }
            }
            .navigationTitle("Import Summary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(createDisabled)
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.html],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { load(url) }
                case .failure(let failure):
                    errorMessage = failure.localizedDescription
                }
            }
            .alert("Import Problem",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Sections

    private var fileSection: some View {
        Section("Summary file") {
            Button {
                showFileImporter = true
            } label: {
                Label(fileName.isEmpty ? "Choose Summary File\u{2026}" : "Choose a Different File\u{2026}",
                      systemImage: "doc.text.magnifyingglass")
            }
            if !fileName.isEmpty {
                LabeledContent("File", value: fileName)
            }
            if !summaryTitle.isEmpty {
                LabeledContent("Title", value: summaryTitle)
            }
        }
    }

    private var customerSection: some View {
        Section("Customer") {
            Picker("Bill to", selection: $selectedCustomer) {
                Text("Choose\u{2026}").tag(SDCustomer?.none)
                ForEach(customers) { customer in
                    Text(customer.name).tag(SDCustomer?.some(customer))
                }
            }
            HStack {
                Text("Rate")
                Spacer()
                TextField("50.00", text: $rateText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                #if !targetEnvironment(macCatalyst)
                    .keyboardType(.decimalPad)
                #endif
                Text("/ h").foregroundStyle(.secondary)
            }
        }
    }

    private var weeksSection: some View {
        Section {
            ForEach($weeks) { $week in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Week", text: $week.label)
                        .font(.headline)
                    TextField("Focus", text: $week.focus, axis: .vertical)
                        .lineLimit(1...3)
                    HStack {
                        Text("Hours").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", value: $week.hours, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        #if !targetEnvironment(macCatalyst)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notes shown to the client")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Detail for this week", text: $week.notes, axis: .vertical)
                            .lineLimit(2...10)
                            .font(.callout)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { weeks.remove(atOffsets: $0) }

            Button {
                weeks.append(BillingWeek())
            } label: {
                Label("Add row", systemImage: "plus.circle")
            }
        } header: {
            Text("Weeks")
        } footer: {
            if let mismatch = hoursMismatch {
                Text("These rows total \(mismatch.parsed, format: .number) h, but the summary states \(mismatch.stated, format: .number) h.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var notesSection: some View {
        Section("Invoice notes") {
            TextField("Shown in the Notes block on the invoice",
                      text: $invoiceNotes, axis: .vertical)
                .lineLimit(2...8)
        }
    }

    private var totalsSection: some View {
        Section("Totals") {
            LabeledContent("Gross hours", value: totals.grossHours, format: .number)
            LabeledContent("Gross amount", value: totals.grossAmount, format: .currency(code: "USD"))
            HStack {
                Text("Bill this amount")
                Spacer()
                TextField("full amount", text: $targetText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                #if !targetEnvironment(macCatalyst)
                    .keyboardType(.decimalPad)
                #endif
            }
            if targetExceedsGross {
                Text("Enter an amount between 0 and the gross.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if totals.discount > 0 {
                LabeledContent("Professional Discount",
                               value: -totals.discount, format: .currency(code: "USD"))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Invoice total", value: totals.total, format: .currency(code: "USD"))
                .fontWeight(.semibold)
        }
    }

    // MARK: Load

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let html: String
        do {
            html = try String(contentsOf: url, encoding: .utf8)
        } catch {
            importLog.error("Could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = BillingSummaryParseError.unreadableFile.errorDescription
            return
        }

        do {
            apply(try BillingSummaryParser.parse(html), fileName: url.lastPathComponent)
        } catch {
            importLog.error("Parse failed for \(url.lastPathComponent, privacy: .public)")
            errorMessage = error.errorDescription
        }
    }

    private func apply(_ summary: BillingSummary, fileName: String) {
        self.fileName = fileName
        summaryTitle = summary.title
        statedTotalHours = summary.statedTotalHours
        weeks = summary.weeks
        invoiceNotes = summary.invoiceBlurb ?? summary.title

        if selectedCustomer == nil {
            let haystack = "\(summary.title) \(fileName)"
            if let name = BillingCustomerMatch.best(in: customers.map(\.name), haystack: haystack) {
                selectedCustomer = customers.first { $0.name == name }
            }
        }
    }

    // MARK: Create

    private func create() {
        guard let customer = selectedCustomer else { return }

        var items: [DPInvoiceItemDraft] = weeks.map { week in
            let description = week.focus.isEmpty ? week.label : "\(week.label): \(week.focus)"
            return DPInvoiceItemDraft(serviceId: "",
                                      description: description,
                                      qty: week.hours,
                                      rate: rate,
                                      notes: week.notes)
        }

        let computed = totals
        if computed.discount > 0 {
            items.append(DPInvoiceItemDraft(serviceId: "",
                                            description: "Professional Discount",
                                            qty: 1,
                                            rate: -computed.discount,
                                            notes: ""))
        }

        onCreate(DPImportSeed(customer: customer, items: items, notes: invoiceNotes))
        dismiss()
    }
}
