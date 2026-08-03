import SwiftUI
import SwiftData
import UIKit

// MARK: - Persistent Timer Manager
// Lives as a singleton so the timer keeps running even when the view is dismissed.

@MainActor
final class DPTimerManager: ObservableObject {
    static let shared = DPTimerManager()

    @Published var isRunning = false
    @Published var startDate: Date? = nil
    @Published var invoiceId: UUID? = nil      // PersistentIdentifier won't work, store UUID
    @Published var lineIndex: Int? = nil
    @Published var invoiceLabel: String = ""    // for display when reopening

    private init() {}

    var elapsed: TimeInterval {
        guard isRunning, let start = startDate else { return 0 }
        return max(0, Date().timeIntervalSince(start))
    }

    func start(invoiceId: UUID, lineIndex: Int, label: String) {
        self.invoiceId = invoiceId
        self.lineIndex = lineIndex
        self.invoiceLabel = label
        self.startDate = Date()
        self.isRunning = true
    }

    func stop() -> (start: Date, seconds: Double, lineIndex: Int)? {
        guard isRunning, let start = startDate, let idx = lineIndex else { return nil }
        let end = Date()
        let seconds = end.timeIntervalSince(start)
        isRunning = false
        startDate = nil
        return (start, seconds, idx)
    }

    func reset() {
        isRunning = false
        startDate = nil
        invoiceId = nil
        lineIndex = nil
        invoiceLabel = ""
    }
}

// MARK: - Time View

/// Lightweight time tracker that logs time to an existing invoice line.
struct DPTimeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var timer = DPTimerManager.shared

    @Query(sort: \SDInvoice.issueDate, order: .reverse) private var allInvoices: [SDInvoice]
    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]

    // Selections
    @State private var selectedInvoice: SDInvoice? = nil
    @State private var selectedLineIndex: Int? = nil

    // Totals (hours) by line index for selected invoice
    @State private var totalsByIndex: [Int: Double] = [:]

    // Line item editor
    @State private var editingDraft: DPInvoiceItemDraft? = nil
    @State private var editingItemIndex: Int? = nil
    @State private var showLineEditor = false

    // Errors / state
    @State private var error: String?

    // Filter to only show invoices (not drafts)
    private var invoices: [SDInvoice] {
        allInvoices.filter { $0.status.lowercased() == "billable" }
    }

    // Step size for +/– buttons (in hours)
    private let stepSize: Double = 0.25

    var body: some View {
        NavigationStack {
            // TimelineView ticks every second — works through background/sleep
            TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                Form {
                    if let error { Text(error).foregroundStyle(.red) }

                    // Show banner if timer is running from a previous session
                    if timer.isRunning, selectedInvoice == nil || selectedInvoice?.id != timer.invoiceId {
                        Section {
                            HStack {
                                Image(systemName: "timer")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Timer running").font(.subheadline).fontWeight(.semibold)
                                    Text(timer.invoiceLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let _ = timeline.date
                                Text(timeString(timer.elapsed))
                                    .monospacedDigit()
                                    .font(.title3)
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    Section("Invoice") {
                        Picker("Select invoice", selection: $selectedInvoice) {
                            Text("Choose...").tag(SDInvoice?.none)
                            ForEach(invoices) { inv in
                                Text("#\(padded(inv.invoiceNumber)) - \(nameFor(inv))")
                                    .tag(SDInvoice?.some(inv))
                            }
                        }
                        .onChange(of: selectedInvoice) { _, inv in
                            selectedLineIndex = nil
                            refreshTotals(for: inv)
                        }
                    }

                    if let inv = selectedInvoice {
                        let sortedItems = inv.sortedItems
                        Section("Line Item") {
                            if sortedItems.isEmpty {
                                Text("This invoice has no line items yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Select line", selection: $selectedLineIndex) {
                                    Text("Choose...").tag(Int?.none)
                                    ForEach(sortedItems.indices, id: \.self) { idx in
                                        let it = sortedItems[idx]
                                        let logged = totalsByIndex[idx] ?? 0
                                        HStack {
                                            Text(it.itemDescription)
                                            Spacer()
                                            Text(String(format: "%g h", logged))
                                        }
                                        .tag(Int?.some(idx))
                                    }
                                }
                            }
                        }

                        Section("Timer") {
                            HStack {
                                Label("Elapsed", systemImage: "timer")
                                Spacer()
                                let _ = timeline.date
                                Text(timeString(timer.isRunning && timer.invoiceId == inv.id ? timer.elapsed : 0))
                                    .monospacedDigit()
                                    .font(.title3)
                                    .foregroundStyle(timer.isRunning && timer.invoiceId == inv.id ? .green : .primary)
                            }

                            HStack {
                                Button {
                                    startTimer(inv: inv)
                                } label: {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .disabled(timer.isRunning || selectedLineIndex == nil)

                                Button(role: .destructive) {
                                    stopTimerAndSave(inv: inv)
                                } label: {
                                    Label("Stop & Save", systemImage: "stop.fill")
                                }
                                .disabled(!timer.isRunning || timer.invoiceId != inv.id)
                            }
                        }

                        // Logged hours with +/- adjustment and tap-to-edit
                        Section {
                            ForEach(sortedItems.indices, id: \.self) { idx in
                                let it = sortedItems[idx]
                                let logged = totalsByIndex[idx] ?? 0
                                HStack(spacing: 8) {
                                    // Tap description to open line item editor
                                    Button {
                                        editingItemIndex = idx
                                        editingDraft = DPInvoiceItemDraft(
                                            serviceId: it.serviceId,
                                            description: it.itemDescription,
                                            qty: it.qty,
                                            rate: it.rate,
                                            notes: it.notes
                                        )
                                        showLineEditor = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "pencil.circle")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                            Text(it.itemDescription)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    // Tight – hours + group
                                    HStack(spacing: 6) {
                                        Button {
                                            adjustTime(for: inv, lineIndex: idx, delta: -stepSize)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.body)
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(logged < stepSize)

                                        Text(formatHoursMinutes(logged))
                                            .monospacedDigit()
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .frame(minWidth: 62)

                                        Button {
                                            adjustTime(for: inv, lineIndex: idx, delta: stepSize)
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.body)
                                                .foregroundStyle(.green)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        } header: {
                            Text("Logged Hours")
                        } footer: {
                            Text("Tap a line to edit details. Use + / – for 15 min adjustments.")
                        }
                    } else {
                        Section {
                            Text("Pick an invoice to begin. Only saved invoices appear here.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("DP Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { printTimeLog() } label: { Image(systemName: "printer") }
                }
            }
            .onAppear {
                restoreSelectionIfTimerRunning()
            }
            .sheet(isPresented: $showLineEditor) {
                if let draft = editingDraft {
                    DPTimeLineItemEditor(draft: draft) { saved in
                        // Write changes back to the SDInvoiceItem
                        guard let inv = selectedInvoice, let idx = editingItemIndex else { return }
                        let sortedItems = inv.sortedItems
                        guard idx < sortedItems.count else { return }
                        let item = sortedItems[idx]
                        item.itemDescription = saved.description
                        item.qty = saved.qty
                        item.rate = saved.rate
                        item.notes = saved.notes
                        refreshTotals(for: inv)
                    }
                    .presentationDetents([.medium])
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshTotals(for invoice: SDInvoice?) {
        guard let invoice else { totalsByIndex = [:]; return }
        let logs = invoice.timeLogs ?? []
        var secondsByIndex: [Int: Double] = [:]
        for log in logs {
            secondsByIndex[log.lineIndex, default: 0] += log.seconds
        }
        var hours: [Int: Double] = [:]
        for (k, v) in secondsByIndex {
            let h = v / 3600.0
            hours[k] = (h * 100).rounded() / 100.0
        }
        totalsByIndex = hours
    }

    private func startTimer(inv: SDInvoice) {
        guard !timer.isRunning, let idx = selectedLineIndex else { return }
        let label = "#\(padded(inv.invoiceNumber)) - \(nameFor(inv))"
        timer.start(invoiceId: inv.id, lineIndex: idx, label: label)
    }

    private func stopTimerAndSave(inv: SDInvoice) {
        guard let result = timer.stop() else { return }

        let timeLog = SDTimeLog(lineIndex: result.lineIndex, startedAt: result.start, stoppedAt: Date(), seconds: result.seconds)
        timeLog.invoice = inv
        modelContext.insert(timeLog)

        refreshTotals(for: inv)

        // Update the invoice line item qty to match total logged hours
        let sortedItems = inv.sortedItems
        if result.lineIndex < sortedItems.count {
            sortedItems[result.lineIndex].qty = totalsByIndex[result.lineIndex] ?? sortedItems[result.lineIndex].qty
        }
    }

    private func adjustTime(for inv: SDInvoice, lineIndex idx: Int, delta: Double) {
        let deltaSeconds = delta * 3600.0
        let now = Date()
        let adjustLog = SDTimeLog(lineIndex: idx, startedAt: now, stoppedAt: now, seconds: deltaSeconds)
        adjustLog.invoice = inv
        modelContext.insert(adjustLog)

        // Update the invoice line item qty
        let sortedItems = inv.sortedItems
        refreshTotals(for: inv)
        if idx < sortedItems.count {
            sortedItems[idx].qty = max(0, totalsByIndex[idx] ?? 0)
        }
    }

    /// If the timer is running when we reopen, auto-select the right invoice.
    private func restoreSelectionIfTimerRunning() {
        guard timer.isRunning, let timerInvId = timer.invoiceId else { return }
        if let inv = invoices.first(where: { $0.id == timerInvId }) {
            selectedInvoice = inv
            selectedLineIndex = timer.lineIndex
            refreshTotals(for: inv)
        }
    }

    // MARK: - Helpers

    private func nameFor(_ inv: SDInvoice) -> String {
        inv.customer?.name ?? "Customer"
    }

    private func padded(_ n: Int) -> String {
        let s = String(n)
        let zeros = max(0, 7 - s.count)
        return String(repeating: "0", count: zeros) + s
    }

    private func formatHoursMinutes(_ hours: Double) -> String {
        let totalMinutes = Int(round(hours * 60))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private func printTimeLog() {
        guard let inv = selectedInvoice else { return }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = margin
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold)]
            ("Time Log" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttrs)
            y += 28
            let subAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.darkGray]
            ("Invoice #\(padded(inv.invoiceNumber)) — \(nameFor(inv))" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: subAttrs)
            y += 20
            let dateAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray]
            (DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none) as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: dateAttrs)
            y += 28

            let headFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let bodyFont = UIFont.systemFont(ofSize: 11)

            for (idx, item) in inv.sortedItems.enumerated() {
                if y > page.height - 60 { ctx.beginPage(); y = margin }
                let hours = totalsByIndex[idx] ?? 0
                let line = "\(item.itemDescription) — \(formatHoursMinutes(hours))"
                (line as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: headFont])
                y += 18

                let logs = (inv.timeLogs ?? []).filter { $0.lineIndex == idx }.sorted { $0.startedAt < $1.startedAt }
                for log in logs {
                    let start = DateFormatter.localizedString(from: log.startedAt, dateStyle: .short, timeStyle: .short)
                    let dur = String(format: "%.2f hrs", log.seconds / 3600.0)
                    let entry = "  \(start)  —  \(dur)"
                    (entry as NSString).draw(at: CGPoint(x: margin + 12, y: y), withAttributes: [.font: bodyFont, .foregroundColor: UIColor.darkGray])
                    y += 15
                }
                y += 8
            }
        }
        dpPrint(data: data, jobName: "Time Log")
    }
}

// MARK: - Line Item Editor (launched from DP Time)

/// Reusable editor that works with a draft copy and calls back on save.
struct DPTimeLineItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    let draft: DPInvoiceItemDraft
    let onSave: (DPInvoiceItemDraft) -> Void

    @State private var desc: String = ""
    @State private var qtyText: String = ""
    @State private var rateText: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Service / Description") {
                    TextField("Description", text: $desc)
                }
                Section("Quantity & Rate") {
                    TextField("Hours / Qty", text: $qtyText)
                        .keyboardType(.decimalPad)
                    TextField("Rate", text: $rateText)
                        .keyboardType(.decimalPad)
                }
                Section("Notes (optional)") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    let q = Double(qtyText) ?? 0
                    let r = Double(rateText) ?? 0
                    HStack {
                        Text("Line Total")
                        Spacer()
                        Text(String(format: "$%.2f", q * r))
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("Edit Line Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.description = desc
                        saved.qty = Double(qtyText) ?? draft.qty
                        saved.rate = Double(rateText) ?? draft.rate
                        saved.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(saved)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                desc = draft.description
                qtyText = (draft.qty == floor(draft.qty)) ? String(Int(draft.qty)) : String(format: "%.2f", draft.qty)
                rateText = String(format: "%.2f", draft.rate)
                notes = draft.notes
            }
        }
    }
}
