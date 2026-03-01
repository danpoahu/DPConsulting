import SwiftUI
import SwiftData
import UIKit

/// Lightweight time tracker that logs time to an existing invoice line.
struct DPTimeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SDInvoice.issueDate, order: .reverse) private var allInvoices: [SDInvoice]
    @Query(sort: \SDCustomer.name) private var customers: [SDCustomer]

    // Selections
    @State private var selectedInvoice: SDInvoice? = nil
    @State private var selectedLineIndex: Int? = nil

    // Running timer
    @State private var isRunning = false
    @State private var startDate: Date? = nil
    @State private var elapsed: TimeInterval = 0

    // Totals (hours) by line index for selected invoice
    @State private var totalsByIndex: [Int: Double] = [:]

    // Errors / state
    @State private var error: String?

    // Ticker for UI updates while running
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Filter to only show invoices (not drafts)
    private var invoices: [SDInvoice] {
        allInvoices.filter { $0.status.lowercased() == "invoice" || $0.status.lowercased() == "sent" }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }

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
                            Text(timeString(elapsed))
                                .monospacedDigit()
                                .font(.title3)
                        }

                        HStack {
                            Button {
                                startTimer()
                            } label: {
                                Label("Start", systemImage: "play.fill")
                            }
                            .disabled(isRunning || selectedLineIndex == nil)

                            Button(role: .destructive) {
                                stopTimerAndSave()
                            } label: {
                                Label("Stop & Save", systemImage: "stop.fill")
                            }
                            .disabled(!isRunning)
                        }
                    }

                    if !totalsByIndex.isEmpty {
                        Section("Logged (hours)") {
                            ForEach(sortedItems.indices, id: \.self) { idx in
                                let it = sortedItems[idx]
                                let logged = totalsByIndex[idx] ?? 0
                                HStack {
                                    Text(it.itemDescription)
                                    Spacer()
                                    Text(String(format: "%.2f h", logged))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Pick an invoice to begin. Only saved invoices appear here.")
                            .foregroundStyle(.secondary)
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
            .onReceive(ticker) { _ in
                guard isRunning, let start = startDate else { return }
                elapsed = Date().timeIntervalSince(start)
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

    private func startTimer() {
        guard !isRunning, selectedInvoice != nil, selectedLineIndex != nil else { return }
        startDate = Date()
        elapsed = 0
        isRunning = true
    }

    private func stopTimerAndSave() {
        guard isRunning, let start = startDate, let inv = selectedInvoice, let idx = selectedLineIndex else { return }
        let end = Date()
        let seconds = end.timeIntervalSince(start)
        isRunning = false
        startDate = nil
        elapsed = 0

        let timeLog = SDTimeLog(lineIndex: idx, startedAt: start, stoppedAt: end, seconds: seconds)
        timeLog.invoice = inv
        modelContext.insert(timeLog)

        refreshTotals(for: inv)
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
                let line = "\(item.itemDescription) — \(String(format: "%.2f", hours)) hrs"
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
