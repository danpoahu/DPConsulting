//
//  InvoiceView.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/10/25.
//

import SwiftUI
import SwiftData
import PDFKit
import UIKit
import Foundation
#if !targetEnvironment(macCatalyst)
import MessageUI
#endif

// MARK: - Invoice Item (lightweight struct for editing)

struct DPInvoiceItemDraft: Identifiable, Hashable {
    var id = UUID()
    var serviceId: String
    var description: String
    var qty: Double
    var rate: Double
    var notes: String = ""
    var amount: Double { qty * rate }
}

// Main invoice editor
struct DPInvoicingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let existing: SDInvoice?
    let preselectedCustomer: SDCustomer?

    init(existing: SDInvoice? = nil, customer: SDCustomer? = nil) {
        self.existing = existing
        self.preselectedCustomer = customer
    }

    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]
    @Query(sort: \SDService.name) private var services: [SDService]

    @State private var settings: SDCompanySettings?
    @State private var overrunMsg: String?

    @State private var selectedCustomer: SDCustomer?
    @State private var selectedService: SDService?
    @State private var hoursText = ""
    @State private var rateText = ""
    @State private var lineNotes = ""

    @State private var items: [DPInvoiceItemDraft] = []
    @State private var invoiceNotes = ""

    enum Status: String, CaseIterable, Identifiable {
        case draft = "Draft (In Progress)"
        case billable = "Billable (Ready to Send)"
        case sent = "Sent"
        case partial = "Partial Payment"
        case paid = "Paid in Full"
        var id: String { rawValue }

        var statusValue: String {
            switch self {
            case .draft: return "draft"
            case .billable: return "billable"
            case .sent: return "sent"
            case .partial: return "partial"
            case .paid: return "paid"
            }
        }

        static func from(_ string: String) -> Status {
            switch string.lowercased() {
            case "draft": return .draft
            case "billable": return .billable
            case "sent": return .sent
            case "partial": return .partial
            case "paid": return .paid
            case "quote": return .draft
            case "invoice": return .sent
            default: return .billable
            }
        }
    }
    @State private var status: Status = .draft
    @State private var amountPaid: Double = 0
    @State private var amountPaidText: String = ""

    @State private var issueDate = Date()
    @State private var dueDate: Date? = Calendar.current.date(byAdding: .day, value: 14, to: Date())

    @State private var savedInvoice: SDInvoice?
    @State private var savedNumber: Int = 0
    @State private var shareURL: URL?
    @State private var error: String?
    @State private var showShareError = false
    @State private var shareErrorMessage = ""
    @State private var isSaving = false
    @State private var didPrefill = false

    @State private var editingIndex: Int? = nil
    @State private var showLineEditor = false

    private var customerIdBinding: Binding<UUID?> {
        Binding(
            get: { self.selectedCustomer?.id },
            set: { newId in
                self.selectedCustomer = self.customers.first(where: { $0.id == newId })
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let msg = overrunMsg {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }

                customerSection
                quickLineSection

                if !items.isEmpty {
                    Section("Items") {
                        ForEach(items.indices, id: \.self) { idx in
                            let it = items[idx]
                            Button {
                                editingIndex = idx
                                showLineEditor = true
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(it.description).font(.subheadline)
                                        Spacer()
                                        Text(String(format: "%g x $%.2f = $%.2f", it.qty, it.rate, it.amount))
                                    }
                                    if !it.notes.isEmpty { Text(it.notes).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { items.remove(at: idx) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }

                Section("Invoice") {
                    Picker("Status", selection: $status) { ForEach(Status.allCases) { s in Text(s.rawValue).tag(s) } }
                    DatePicker("Issue Date", selection: $issueDate, displayedComponents: [.date])
                    if status != .draft {
                        DatePicker("Due Date", selection: $dueDate.defaulted(Date()), displayedComponents: [.date])
                    }
                    if status == .partial || status == .paid {
                        HStack {
                            Text("Amount Paid:")
                            TextField("0.00", text: $amountPaidText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: amountPaidText) { _, newValue in
                                    amountPaid = Double(newValue) ?? 0
                                }
                        }
                    }
                    TextField("Notes (shows on PDF)", text: $invoiceNotes, axis: .vertical).lineLimit(1...3)
                }

                totalsSection
            }
            .navigationTitle("DP Invoicing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }

                ToolbarItem(placement: .topBarTrailing) {
                    if savedInvoice != nil, status != .draft {
                        Button { addOverrunLinesFromTime() } label: { Image(systemName: "plus.circle") }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button { regeneratePDFOnly() } label: { Image(systemName: "doc.richtext") }
                        .disabled(selectedCustomer == nil || items.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let url = shareURL, FileManager.default.fileExists(atPath: url.path) {
                        Button {
                            presentShare(for: url)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let url = shareURL, FileManager.default.fileExists(atPath: url.path) {
                        Button { dpPrint(url: url, jobName: "Invoice") } label: {
                            Image(systemName: "printer")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAndPDF() } label: { if isSaving { ProgressView() } else { Text("Save + PDF") } }
                        .disabled(selectedCustomer == nil || items.isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showLineEditor) {
                if let idx = editingIndex {
                    DPLineItemEditor(item: $items[idx])
                        .presentationSizing(.form)
                }
            }
            .onAppear {
                settings = loadOrCreateSettings(context: modelContext)
                prefillIfNeeded()
                if existing != nil { regeneratePDFOnly() }
            }
            .alert("Share Error", isPresented: $showShareError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareErrorMessage)
            }
        }
    }

    // MARK: - Section Views

    private var customerSection: some View {
        Section("Customer") {
            Picker("Select Customer", selection: customerIdBinding) {
                Text("Choose...").tag(UUID?.none)
                ForEach(customers) { customer in
                    Text(customer.display).tag(UUID?.some(customer.id))
                }
            }
        }
    }

    private var quickLineSection: some View {
        Section("Quick Line") {
            Picker("Service", selection: Binding(
                get: { selectedService?.id },
                set: { newId in selectedService = services.first(where: { $0.id == newId }) }
            )) {
                Text("Choose...").tag(UUID?.none)
                ForEach(services) { service in
                    Text(service.name).tag(UUID?.some(service.id))
                }
            }
            TextField("Hours / Qty", text: $hoursText).keyboardType(.decimalPad)
            TextField("Rate", text: $rateText).keyboardType(.decimalPad)
            TextField("Notes (optional)", text: $lineNotes)
            Button("Add Line") {
                guard let svc = selectedService,
                      let qty = Double(hoursText),
                      let rate = Double(rateText)
                else { return }
                let item = DPInvoiceItemDraft(
                    serviceId: svc.id.uuidString,
                    description: svc.name,
                    qty: qty,
                    rate: rate,
                    notes: lineNotes
                )
                items.append(item)
                hoursText = ""
                rateText = ""
                lineNotes = ""
            }
            .disabled(selectedService == nil || hoursText.isEmpty || rateText.isEmpty)
        }
    }

    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        if existing == nil {
            // Pre-select customer for new quote/invoice
            if let c = preselectedCustomer {
                selectedCustomer = c
            }
            didPrefill = true
            return
        }
        guard let inv = existing else { return }
        status = Status.from(inv.status)
        issueDate = inv.issueDate
        dueDate = inv.dueDate
        items = inv.sortedItems.map { item in
            DPInvoiceItemDraft(
                serviceId: item.serviceId,
                description: item.itemDescription,
                qty: item.qty,
                rate: item.rate,
                notes: item.notes
            )
        }
        invoiceNotes = inv.notes
        savedInvoice = inv
        savedNumber = inv.invoiceNumber
        amountPaid = inv.amountPaid
        amountPaidText = inv.amountPaid > 0 ? String(format: "%.2f", inv.amountPaid) : ""
        if let c = inv.customer {
            selectedCustomer = c
        } else if !inv.customerId.isEmpty {
            selectedCustomer = customers.first(where: { $0.id.uuidString == inv.customerId })
        }
        didPrefill = true
    }

    private var totalsSection: some View {
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let tax = subtotal * s.salesTax
        let total = subtotal + tax
        return Section("Totals") {
            HStack { Text("Subtotal"); Spacer(); Text(String(format: "$%.2f", subtotal)) }
            HStack { Text("Tax");      Spacer(); Text(String(format: "$%.2f", tax)) }
            HStack { Text("Total");    Spacer(); Text(String(format: "$%.2f", total)).fontWeight(.semibold) }
        }
    }

    private func addOverrunLinesFromTime() {
        guard let inv = savedInvoice else { return }
        let logs = inv.timeLogs ?? []
        var secondsByIndex: [Int: Double] = [:]
        for log in logs {
            secondsByIndex[log.lineIndex, default: 0] += log.seconds
        }
        var hoursByIndex: [Int: Double] = [:]
        for (k, v) in secondsByIndex {
            hoursByIndex[k] = (v / 3600.0 * 100).rounded() / 100.0
        }

        var added = 0
        for idx in items.indices {
            let planned = items[idx].qty
            let actualH = hoursByIndex[idx] ?? 0
            let extra = actualH - planned
            if extra > 0.01 {
                let base = items[idx]
                let over = DPInvoiceItemDraft(
                    serviceId: base.serviceId,
                    description: "[Overrun] " + base.description,
                    qty: extra,
                    rate: base.rate,
                    notes: "Auto-added from time logs"
                )
                items.append(over); added += 1
            }
        }
        overrunMsg = added > 0 ? "Added \(added) overrun line(s)" : "No overruns found"
    }

    private func regeneratePDFOnly() {
        guard let customer = selectedCustomer, !items.isEmpty else { return }
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        do {
            let url = try generatePDFURL(customer: customer, settings: s, isQuote: status == .draft, numberOverride: savedNumber == 0 ? nil : savedNumber)
            if FileManager.default.fileExists(atPath: url.path) {
                self.shareURL = url
            } else {
                self.shareURL = nil
                self.error = "PDF file could not be found after rendering."
            }
        } catch let e {
            self.error = e.localizedDescription
        }
    }

    private func saveAndPDF() {
        guard let customer = selectedCustomer else { return }
        isSaving = true; error = nil; shareURL = nil

        let s = settings ?? loadOrCreateSettings(context: modelContext)
        let number: Int
        if savedNumber == 0 {
            number = nextInvoiceNumber(context: modelContext)
        } else {
            number = savedNumber
        }

        let subtotal = items.reduce(0) { $0 + $1.amount }
        let tax = subtotal * s.salesTax
        let total = subtotal + tax

        let computedDueDate: Date? = {
            switch status {
            case .draft: return nil
            case .sent: return Date()
            case .billable, .partial, .paid: return dueDate
            }
        }()

        let invoice: SDInvoice
        if let existing = savedInvoice {
            // Update existing
            existing.invoiceNumber = number
            existing.status = status.statusValue
            existing.customer = customer
            existing.customerId = customer.id.uuidString
            existing.issueDate = issueDate
            existing.dueDate = computedDueDate
            existing.notes = invoiceNotes
            existing.subtotal = subtotal
            existing.tax = tax
            existing.total = total
            existing.amountPaid = amountPaid
            existing.updatedAt = Date()

            // Replace items
            for old in (existing.items ?? []) {
                modelContext.delete(old)
            }
            for (idx, draft) in items.enumerated() {
                let item = SDInvoiceItem(
                    serviceId: draft.serviceId,
                    description: draft.description,
                    qty: draft.qty,
                    rate: draft.rate,
                    notes: draft.notes,
                    sortOrder: idx
                )
                item.invoice = existing
                modelContext.insert(item)
            }
            invoice = existing
        } else {
            // Create new
            invoice = SDInvoice(
                invoiceNumber: number,
                status: status.statusValue,
                customer: customer,
                customerId: customer.id.uuidString,
                issueDate: issueDate,
                dueDate: computedDueDate,
                notes: invoiceNotes,
                subtotal: subtotal,
                tax: tax,
                total: total,
                amountPaid: amountPaid
            )
            modelContext.insert(invoice)

            for (idx, draft) in items.enumerated() {
                let item = SDInvoiceItem(
                    serviceId: draft.serviceId,
                    description: draft.description,
                    qty: draft.qty,
                    rate: draft.rate,
                    notes: draft.notes,
                    sortOrder: idx
                )
                item.invoice = invoice
                modelContext.insert(item)
            }
        }

        savedInvoice = invoice
        savedNumber = number

        // Post A/R and Revenue when invoice is sent
        if status == .sent {
            postInvoiceJournalEntry(number: number, total: total)
        }

        do {
            let url = try generatePDFURL(customer: customer, settings: s, isQuote: status == .draft, numberOverride: number)
            if FileManager.default.fileExists(atPath: url.path) {
                self.shareURL = url
            } else {
                self.shareURL = nil
                self.error = "PDF file could not be found after rendering."
            }
        } catch let e {
            self.error = e.localizedDescription
        }

        isSaving = false
    }

    private func postInvoiceJournalEntry(number: Int, total: Double) {
        // Ensure accounts exist
        ensureDefaultAccounts(context: modelContext)

        let accountsDescriptor = FetchDescriptor<SDAccount>()
        let accounts = (try? modelContext.fetch(accountsDescriptor)) ?? []

        guard let ar = accounts.first(where: { $0.name.caseInsensitiveCompare("Accounts Receivable") == .orderedSame && $0.type == .asset }),
              let revenue = accounts.first(where: { $0.name.caseInsensitiveCompare("Sales Revenue") == .orderedSame && $0.type == .income })
        else { return }

        let entry = SDJournalEntry(date: Date(), memo: "Invoice #\(number) sent")
        modelContext.insert(entry)

        let debitLine = SDEntryLine(accountId: ar.id, debit: total, credit: 0, memo: "A/R", sortOrder: 0)
        debitLine.journalEntry = entry
        modelContext.insert(debitLine)

        let creditLine = SDEntryLine(accountId: revenue.id, debit: 0, credit: total, memo: "Revenue", sortOrder: 1)
        creditLine.journalEntry = entry
        modelContext.insert(creditLine)
    }

    @MainActor
    private func presentShare(for url: URL) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            shareErrorMessage = "PDF file is missing. Please regenerate and try again."
            showShareError = true
            return
        }

        func topController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            guard let scene = scenes.first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  var root = window.rootViewController else { return nil }
            while let presented = root.presentedViewController { root = presented }
            return root
        }

        guard let root = topController() else {
            shareErrorMessage = "Unable to find a window to present from."
            showShareError = true
            return
        }

        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        root.present(avc, animated: true)
    }

    private func generatePDFURL(customer: SDCustomer, settings: SDCompanySettings, isQuote: Bool, numberOverride: Int?) throws -> URL {
        let subtotal = items.reduce(0) { $0 + $1.amount }
        let tax = subtotal * settings.salesTax
        let total = subtotal + tax

        let data = DPInvoicePDF.render(
            isQuote: isQuote,
            number: numberOverride ?? savedNumber,
            customerName: customer.name,
            issueDate: issueDate,
            dueDate: isQuote ? nil : dueDate,
            businessName: settings.name,
            businessAddress: settings.address,
            businessPhone: settings.phone,
            customerAddress: customer.address,
            customerPhone: customer.phone,
            invoiceNotes: invoiceNotes,
            lineItems: items.map { ["description": $0.description, "qty": $0.qty, "rate": $0.rate, "amount": $0.amount, "notes": $0.notes] },
            subtotal: subtotal,
            tax: tax,
            total: total,
            footerText: settings.invoiceFooter
        )
        let fileName = (isQuote ? "Quote" : "Invoice") + "-" + String(numberOverride ?? max(savedNumber, 0)) + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }
}

// Inline line-item editor
struct DPLineItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: DPInvoiceItemDraft

    @State private var desc: String = ""
    @State private var qtyText: String = ""
    @State private var rateText: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Service / Description") { TextField("Description", text: $desc) }
                Section("Quantity & Rate") {
                    TextField("Hours / Qty", text: $qtyText).keyboardType(.decimalPad)
                    TextField("Rate", text: $rateText).keyboardType(.decimalPad)
                }
                Section("Notes (optional)") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...3) }
                Section {
                    let q = Double(qtyText) ?? 0
                    let r = Double(rateText) ?? 0
                    HStack { Text("Line Total"); Spacer(); Text(String(format: "$%.2f", q*r)).fontWeight(.semibold) }
                }
            }
            .navigationTitle("Edit Line Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        item.description = desc
                        item.qty = Double(qtyText) ?? item.qty
                        item.rate = Double(rateText) ?? item.rate
                        item.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
            .onAppear {
                desc = item.description
                qtyText = (item.qty == floor(item.qty)) ? String(Int(item.qty)) : String(item.qty)
                rateText = String(format: "%.2f", item.rate)
                notes = item.notes
            }
        }
    }
}

// Invoices list (filter + open existing)
struct DPInvoicesListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDInvoice.issueDate, order: .reverse) private var allInvoices: [SDInvoice]
    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]

    private enum Filter: String, CaseIterable, Identifiable {
        case quotes, invoices, paid
        var id: String { rawValue }
        var title: String {
            switch self { case .quotes: return "Quotes"; case .invoices: return "Open"; case .paid: return "Paid" }
        }
        var statuses: Set<String> {
            switch self {
            case .quotes: return ["quote", "draft", "billable"]
            case .invoices: return ["invoice", "sent", "partial"]
            case .paid: return ["paid"]
            }
        }
    }

    private enum EditorRoute: Identifiable {
        case new
        case edit(SDInvoice)
        var id: String { switch self { case .new: return "new"; case .edit(let inv): return "edit-\(inv.id)" } }
    }

    @State private var filter: Filter = .invoices
    @State private var editorRoute: EditorRoute?
    @State private var error: String?

    private var filteredInvoices: [SDInvoice] {
        allInvoices.filter { filter.statuses.contains($0.status.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }

                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                ForEach(filteredInvoices) { inv in
                    Button { editorRoute = .edit(inv) } label: {
                        InvoiceRow(inv: inv, customerName: nameFor(inv))
                    }
                }
            }
            .navigationTitle("DP Invoices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let data = AllInvoicesPDF.render(invoices: allInvoices, customers: customers)
                        dpPrint(data: data, jobName: "All Invoices")
                    } label: { Image(systemName: "printer") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { editorRoute = .new } label: { Image(systemName: "plus") } }
            }
            .sheet(item: $editorRoute) { route in
                Group {
                    switch route {
                        case .new: DPInvoicingView()
                        case .edit(let inv): DPInvoicingView(existing: inv)
                    }
                }
                .presentationSizing(.form)
            }
        }
    }

    private func nameFor(_ inv: SDInvoice) -> String {
        inv.customer?.name ?? customers.first(where: { $0.id.uuidString == inv.customerId })?.name ?? "Customer"
    }

    struct InvoiceRow: View {
        let inv: SDInvoice
        let customerName: String
        private let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; return d }()

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "#\(inv.invoiceNumber) - \(customerName)").font(.headline)
                    let dateStr = df.string(from: inv.issueDate)
                    Text(verbatim: inv.status.capitalized + " - " + dateStr).font(.caption).foregroundStyle(.secondary)

                    if inv.status.lowercased() == "partial" && inv.amountPaid > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "creditcard.fill").font(.caption2)
                            Text("Paid: \(inv.amountPaid.currencyString()) / Balance: \(inv.balance.currencyString())")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        .padding(.top, 2)
                    }

                    if inv.isOverdue {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                            Text("\(inv.daysOverdue) days overdue")
                                .font(.caption).foregroundStyle(.red)
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "$%.2f", inv.total)).font(.headline)
                    if inv.status.lowercased() == "partial" && inv.balance > 0 {
                        Text("Due: \(inv.balance.currencyString())")
                            .font(.caption).foregroundStyle(.orange).fontWeight(.semibold)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(cardBorderColor, lineWidth: cardBorderWidth)
            )
            .contentShape(Rectangle())
        }

        private var cardBackgroundColor: Color {
            if inv.status.lowercased() == "partial" { return Color.orange.opacity(0.1) }
            else if inv.isOverdue { return Color.red.opacity(0.08) }
            else { return Color.clear }
        }

        private var cardBorderColor: Color {
            if inv.status.lowercased() == "partial" { return Color.orange.opacity(0.5) }
            else if inv.isOverdue { return Color.red.opacity(0.3) }
            else { return Color.clear }
        }

        private var cardBorderWidth: CGFloat {
            (inv.status.lowercased() == "partial" || inv.isOverdue) ? 1.5 : 0
        }
    }
}

extension UIWindowScene {
    var keyWindow: UIWindow? { self.windows.first { $0.isKeyWindow } }
}

// MARK: - Accounts Receivable Statement View
struct DPARStatementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]
    @Query(sort: \SDInvoice.issueDate, order: .reverse)
    private var allInvoices: [SDInvoice]

    private var invoices: [SDInvoice] {
        allInvoices.filter { inv in
            let s = inv.status.lowercased()
            return s == "sent" || s == "partial" || s == "billable"
        }
    }

    @State private var settings: SDCompanySettings?
    @State private var selectedCustomer: SDCustomer?
    @State private var error: String?

    @State private var showingMailComposer = false
    @State private var emailRecipient: String = ""
    @State private var attachmentURLs: [URL] = []

    private var outstandingInvoices: [SDInvoice] {
        invoices.filter { $0.balance > 0 }
    }

    private var customerBalances: [(customer: SDCustomer, balance: Double, invoices: [SDInvoice])] {
        let grouped = Dictionary(grouping: outstandingInvoices) { inv -> UUID? in
            inv.customer?.id
        }
        return grouped.compactMap { customerId, invs in
            guard let customerId, let customer = customers.first(where: { $0.id == customerId }) else { return nil }
            let balance = invs.reduce(0) { $0 + $1.balance }
            return (customer, balance, invs.sorted { $0.issueDate < $1.issueDate })
        }.sorted { $0.balance > $1.balance }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }

                Section {
                    let totalAR = customerBalances.reduce(0) { $0 + $1.balance }
                    HStack {
                        Text("Total Accounts Receivable").font(.headline)
                        Spacer()
                        Text(totalAR.currencyString()).font(.title2.bold()).foregroundColor(.blue)
                    }
                    .padding(.vertical, 8)
                }

                if customerBalances.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundColor(.green)
                                Text("All Invoices Paid!").font(.title2.bold())
                                Text("No outstanding balances").foregroundColor(.secondary)
                            }
                            .padding(.vertical, 40)
                            Spacer()
                        }
                    }
                } else {
                    ForEach(customerBalances, id: \.customer.id) { item in
                        Section {
                            Button {
                                selectedCustomer = item.customer
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(item.customer.name).font(.headline)
                                        Spacer()
                                        Text(item.balance.currencyString())
                                            .font(.title3.bold())
                                            .foregroundColor(item.invoices.contains { $0.isOverdue } ? .red : .primary)
                                    }

                                    ForEach(item.invoices) { invoice in
                                        NavigationLink(destination: DPInvoicingView(existing: invoice)) {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Invoice #\(invoice.invoiceNumber)").font(.subheadline)
                                                    Text(invoice.issueDate, style: .date).font(.caption).foregroundColor(.secondary)
                                                    if invoice.isOverdue {
                                                        Text("\(invoice.daysOverdue) days overdue").font(.caption).foregroundColor(.red)
                                                    }
                                                }
                                                Spacer()
                                                VStack(alignment: .trailing, spacing: 2) {
                                                    Text("Balance: \(invoice.balance.currencyString())").font(.subheadline.bold())
                                                    if invoice.amountPaid > 0 {
                                                        Text("Paid: \(invoice.amountPaid.currencyString())").font(.caption).foregroundColor(.green)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }

                                    HStack(spacing: 12) {
                                        Button {
                                            emailStatement(for: item.customer, invoices: item.invoices)
                                        } label: {
                                            Label("Email Statement", systemImage: "envelope").font(.caption)
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            exportStatement(for: item.customer, invoices: item.invoices)
                                        } label: {
                                            Label("Export PDF", systemImage: "square.and.arrow.up").font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 4)

                                    Text("Tip: The sender account is chosen by Mail. To send from ohauappdesign@icloud.com, set it as your default in Mail or change it in the composer.")
                                        .font(.caption2).foregroundColor(.secondary).padding(.top, 2)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Accounts Receivable")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { printStatement() } label: { Image(systemName: "printer") }
                }
            }
            .onAppear {
                settings = loadOrCreateSettings(context: modelContext)
            }
            #if !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showingMailComposer) {
                if !attachmentURLs.isEmpty {
                    MailComposerView(
                        recipients: [emailRecipient],
                        subject: "DP Consult Statement and Invoices Attached",
                        body: generateEmailBody(),
                        attachments: attachmentURLs,
                        bcc: ["dan@oahuappdesign.com"]
                    )
                    .presentationSizing(.form)
                }
            }
            #endif
        }
    }

    private func emailStatement(for customer: SDCustomer, invoices: [SDInvoice]) {
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        guard let statementURL = generateStatementPDF(for: customer, invoices: invoices, settings: s) else {
            error = "Failed to generate statement PDF"
            return
        }

        var urls = [statementURL]
        for invoice in invoices {
            if let pdfURL = try? generateInvoicePDF(invoice: invoice, customer: customer, settings: s) {
                urls.append(pdfURL)
            }
        }

        self.selectedCustomer = customer
        #if !targetEnvironment(macCatalyst)
        if MFMailComposeViewController.canSendMail() {
            emailRecipient = customer.email.isEmpty ? "" : customer.email
            attachmentURLs = urls
            showingMailComposer = true
        } else {
            presentShareSheet(for: statementURL)
        }
        #else
        presentShareSheet(for: statementURL)
        #endif
    }

    private func printStatement() {
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        for customer in customers {
            let custInvoices = invoices.filter {
                $0.customer?.id == customer.id &&
                ["invoice", "sent", "partial"].contains($0.status.lowercased())
            }
            if !custInvoices.isEmpty,
               let url = generateStatementPDF(for: customer, invoices: custInvoices, settings: s) {
                dpPrint(url: url, jobName: "A/R Statement - \(customer.name)")
                break
            }
        }
    }

    private func exportStatement(for customer: SDCustomer, invoices: [SDInvoice]) {
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        guard let url = generateStatementPDF(for: customer, invoices: invoices, settings: s) else {
            error = "Failed to generate statement PDF"
            return
        }
        presentShareSheet(for: url)
    }

    @MainActor
    private func presentShareSheet(for url: URL) {
        func topController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            guard let scene = scenes.first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  var root = window.rootViewController else { return nil }
            while let presented = root.presentedViewController { root = presented }
            return root
        }
        guard let root = topController() else {
            error = "Unable to find a window to present from."
            return
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activityVC, animated: true)
    }

    private func generateStatementPDF(for customer: SDCustomer, invoices: [SDInvoice], settings: SDCompanySettings) -> URL? {
        let data = ARStatementPDF.render(
            customer: customer,
            invoices: invoices,
            settings: settings
        )
        let fileName = "AR_Statement_\(customer.name.replacingOccurrences(of: " ", with: "_"))_\(Date().ISO8601Format()).pdf"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func generateInvoicePDF(invoice: SDInvoice, customer: SDCustomer, settings: SDCompanySettings) throws -> URL {
        let invoiceItems = invoice.sortedItems
        let data = DPInvoicePDF.render(
            isQuote: false,
            number: invoice.invoiceNumber,
            customerName: customer.name,
            issueDate: invoice.issueDate,
            dueDate: invoice.dueDate,
            businessName: settings.name,
            businessAddress: settings.address,
            businessPhone: settings.phone,
            customerAddress: customer.address,
            customerPhone: customer.phone,
            invoiceNotes: invoice.notes,
            lineItems: invoiceItems.map { ["description": $0.itemDescription, "qty": $0.qty, "rate": $0.rate, "amount": $0.amount, "notes": $0.notes] },
            subtotal: invoice.subtotal,
            tax: invoice.tax,
            total: invoice.total,
            footerText: settings.invoiceFooter
        )
        let fileName = "Invoice_\(invoice.invoiceNumber)_\(customer.name.replacingOccurrences(of: " ", with: "_")).pdf"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }

    private func generateEmailBody() -> String {
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        let name = selectedCustomer?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let greeting = name.isEmpty ? "Hello," : "Hello \(name),"

        return """
        \(greeting)

        Please find attached your statement and invoices with balances due. Please remit at your earliest convenience. If you have already paid, please disregard.

        Thank you for your continued support. We appreciate your valued business.

        Dan
        \(s.name)
        """
    }
}

// MARK: - AR Statement PDF Generator

enum ARStatementPDF {
    private static func formatPhoneNumber(_ phone: String) -> String {
        let digits = phone.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        if digits.count == 10 {
            let area = String(digits.prefix(3))
            let middle = String(digits.dropFirst(3).prefix(3))
            let last = String(digits.suffix(4))
            return "(\(area)) \(middle)-\(last)"
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            let area = String(digits.dropFirst().prefix(3))
            let middle = String(digits.dropFirst(4).prefix(3))
            let last = String(digits.suffix(4))
            return "1 (\(area)) \(middle)-\(last)"
        }
        return phone
    }

    static func render(customer: SDCustomer, invoices: [SDInvoice], settings: SDCompanySettings) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36

        let h1 = UIFont.systemFont(ofSize: 28, weight: .bold)
        let h2 = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 12)
        let small = UIFont.systemFont(ofSize: 10)

        let brandBlue = UIColor.systemBlue
        let brandOrange = UIColor.systemOrange
        let stripe = UIColor(white: 0.965, alpha: 1)
        let hairline = UIColor.black.withAlphaComponent(0.18).cgColor
        let accent = UIColor.tintColor

        let colW: CGFloat = 240
        let leftX = margin
        let rightX = page.width - margin - colW

        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        func drawMultiline(_ text: String, at: CGPoint, width: CGFloat, font: UIFont, lineSpacing: CGFloat = 1.35, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing; para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(x: at.x, y: at.y, width: width, height: size.height), withAttributes: attrs)
            return ceil(size.height)
        }

        func drawLogo(named: String, at: CGPoint, maxWidth: CGFloat) -> CGFloat {
            guard let img = UIImage(named: named) else { return 0 }
            let scale = min(1, maxWidth / img.size.width)
            let w = img.size.width * scale; let h = img.size.height * scale
            img.draw(in: CGRect(x: at.x, y: at.y, width: w, height: h))
            return h
        }

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        let totalDueOverall: Double = invoices.reduce(0) { $0 + $1.balance }

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let g = UIGraphicsGetCurrentContext()!
            var y = margin

            let logoH = drawLogo(named: "DPLogo", at: CGPoint(x: leftX, y: y), maxWidth: 140)
            y += logoH
            let bizTopY = y + (logoH > 0 ? 6 : 0)

            var bizLines: [String] = []
            let bizName = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bizName.isEmpty { bizLines.append(bizName) }
            if !settings.address.isEmpty {
                let addr = settings.address.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                bizLines.append(addr)
            }
            if !settings.phone.isEmpty { bizLines.append(formatPhoneNumber(settings.phone)) }

            y = bizTopY
            y += drawMultiline(bizLines.joined(separator: "\n"), at: CGPoint(x: leftX, y: y), width: colW, font: body, lineSpacing: 2)
            let bizBottomY = y

            let titleTop = margin
            let titleH = draw("STATEMENT", at: CGPoint(x: rightX, y: titleTop), font: h1, color: brandBlue)
            g.setFillColor(brandOrange.cgColor)
            g.fill(CGRect(x: rightX, y: titleTop + titleH + 6, width: 96, height: 3))

            var ry = titleTop + titleH + 26
            let df = DateFormatter(); df.dateStyle = .medium
            let labelToValueX: CGFloat = 110
            let minRowH: CGFloat = 26
            let dateLabelH = draw("Date:", at: CGPoint(x: rightX, y: ry), font: h2)
            _ = draw(df.string(from: Date()), at: CGPoint(x: rightX + labelToValueX, y: ry), font: body)
            ry += max(minRowH, dateLabelH) + 6
            let balLabelH = draw("Balance Due:", at: CGPoint(x: rightX, y: ry), font: h2, color: accent)
            _ = draw(money(totalDueOverall), at: CGPoint(x: rightX + labelToValueX, y: ry), font: h2, color: accent)
            ry += max(minRowH, balLabelH) + 10

            let billY = ry
            _ = draw("Bill To", at: CGPoint(x: rightX, y: billY), font: h2)
            var by = billY + 18

            var custLines: [String] = []
            if !customer.name.isEmpty { custLines.append(customer.name) }
            if !customer.address.isEmpty { custLines.append(customer.address) }
            if !customer.phone.isEmpty { custLines.append("Phone: \(formatPhoneNumber(customer.phone))") }

            by += drawMultiline(custLines.joined(separator: "\n"), at: CGPoint(x: rightX, y: by), width: colW, font: body, lineSpacing: 2)

            let tableTop = max(by, bizBottomY) + 12
            g.setStrokeColor(hairline); g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: tableTop))
            g.addLine(to: CGPoint(x: page.width - margin, y: tableTop))
            g.strokePath()

            var ty = tableTop + 4
            let headerH: CGFloat = 28
            g.setFillColor(brandBlue.cgColor)
            g.fill(CGRect(x: margin, y: ty, width: page.width - margin*2, height: headerH))

            let invoiceX = margin + 10
            let dateX = margin + 100
            let dueX = margin + 200
            let paidX = margin + 420
            let balanceX = page.width - margin - 70 - 54

            _ = draw("Invoice #", at: CGPoint(x: invoiceX, y: ty + 7), font: h2, color: .white)
            _ = draw("Date", at: CGPoint(x: dateX, y: ty + 7), font: h2, color: .white)
            _ = draw("Due Date", at: CGPoint(x: dueX, y: ty + 7), font: h2, color: .white)
            _ = draw("Balance", at: CGPoint(x: paidX, y: ty + 7), font: h2, width: 100, align: .right, color: .white)
            _ = draw("Paid", at: CGPoint(x: balanceX - 90, y: ty + 7), font: h2, width: 90, align: .right, color: .white)
            ty += headerH + 6

            let df2 = DateFormatter(); df2.dateStyle = .short
            var row = 0

            for invoice in invoices {
                let rowH: CGFloat = 24
                if row % 2 == 1 {
                    g.setFillColor(stripe.cgColor)
                    g.fill(CGRect(x: margin, y: ty - 1, width: page.width - 2*margin, height: rowH + 2))
                }
                let textColor: UIColor = invoice.isOverdue ? .systemRed : .black
                _ = draw("#\(invoice.invoiceNumber)", at: CGPoint(x: invoiceX, y: ty), font: body, color: textColor)
                _ = draw(df2.string(from: invoice.issueDate), at: CGPoint(x: dateX, y: ty), font: body, color: textColor)
                if let due = invoice.dueDate {
                    _ = draw(df2.string(from: due), at: CGPoint(x: dueX, y: ty), font: body, color: textColor)
                }
                _ = draw(money(invoice.balance), at: CGPoint(x: paidX, y: ty), font: body, width: 100, align: .right, color: textColor)
                _ = draw(money(invoice.amountPaid), at: CGPoint(x: balanceX - 90, y: ty), font: body, width: 90, align: .right, color: textColor)
                ty += rowH; row += 1
            }

            let footerTop = page.height - margin - 34
            g.setStrokeColor(hairline); g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: footerTop))
            g.addLine(to: CGPoint(x: page.width - margin, y: footerTop))
            g.strokePath()

            let footerText = "Please remit payment to the address above. Thank you for your business!"
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: small, .paragraphStyle: para, .foregroundColor: UIColor.darkGray]
            (footerText as NSString).draw(in: CGRect(x: margin, y: footerTop + 6, width: page.width - margin*2, height: 28), withAttributes: attrs)
        }
    }
}

// MARK: - Mail Composer (UIKit wrapper)

#if !targetEnvironment(macCatalyst)
struct MailComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachments: [URL]
    let bcc: [String]

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(recipients)
        vc.setBccRecipients(bcc)
        vc.setPreferredSendingEmailAddress("dan@oahuappdesign.com")
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        for url in attachments {
            if let data = try? Data(contentsOf: url) {
                vc.addAttachmentData(data, mimeType: "application/pdf", fileName: url.lastPathComponent)
            }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}
#endif
