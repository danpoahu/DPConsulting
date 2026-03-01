import SwiftUI
#if !targetEnvironment(macCatalyst)
import MessageUI
#endif

// Minimal invoice model for status
struct ARInvoice: Identifiable, Hashable {
    let id: UUID
    var number: String
    var issueDate: Date
    var dueDate: Date
    var amount: Decimal

    init(id: UUID = UUID(), number: String, issueDate: Date, dueDate: Date, amount: Decimal) {
        self.id = id
        self.number = number
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.amount = amount
    }

    var isPastDue: Bool {
        var cal = Calendar.current
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let dueDay = cal.startOfDay(for: dueDate)
        return dueDay < today
    }

    var isDueToday: Bool {
        var cal = Calendar.current
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let dueDay = cal.startOfDay(for: dueDate)
        return dueDay == today
    }
}

// Lightweight client model
struct ARClient: Identifiable, Hashable {
    let id: UUID
    var name: String
    var email: String
    var lastStatementEmailedAt: Date?
    var invoices: [ARInvoice]

    init(id: UUID = UUID(), name: String, email: String, lastStatementEmailedAt: Date? = nil, invoices: [ARInvoice] = []) {
        self.id = id
        self.name = name
        self.email = email
        self.lastStatementEmailedAt = lastStatementEmailedAt
        self.invoices = invoices
    }
}

// Simple view model holding a few clients and handling the email action flag
@Observable
final class ARClientsViewModel {
    var clients: [ARClient]
    var comparisonTimeZone: TimeZone = .current

    init(clients: [ARClient] = {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        return [
            ARClient(
                name: "Acme Dental",
                email: "billing@acmedental.com",
                invoices: [
                    ARInvoice(number: "INV-1001", issueDate: now - day * 2, dueDate: now + day * 12, amount: 250.00)
                ]
            ),
            ARClient(
                name: "Bright Smiles",
                email: "office@brightsmiles.com",
                invoices: [
                    ARInvoice(number: "INV-1002", issueDate: now - day * 10, dueDate: now + day * 5, amount: 520.00)
                ]
            ),
            ARClient(
                name: "Downtown Ortho",
                email: "ap@downtownortho.com",
                invoices: [
                    ARInvoice(number: "INV-1003", issueDate: now - day * 40, dueDate: now - day * 10, amount: 780.00)
                ]
            )
        ]
    }()) {
        self.clients = clients
    }

    func emailStatement(for clientID: UUID) {
        guard let idx = clients.firstIndex(where: { $0.id == clientID }) else { return }
        // In a real app, trigger email compose here. For now, just flag the timestamp.
        clients[idx].lastStatementEmailedAt = Date()
    }

    func emailContent(for client: ARClient) -> (subject: String, body: String) {
        let invoices = client.invoices
        let currency = NumberFormatter()
        currency.numberStyle = .currency

        func formatAmount(_ amount: Decimal) -> String {
            let ns = amount as NSDecimalNumber
            return currency.string(from: ns) ?? "$\(amount)"
        }

        if invoices.isEmpty {
            return (
                subject: "Statement for \(client.name)",
                body: "Hello,\n\nPlease find your current account statement attached. There are no open invoices at this time.\n\nThank you,\nAccounts Receivable"
            )
        }

        let pastDue = invoices.filter { $0.isPastDue }
        let dueToday = invoices.filter { $0.isDueToday }
        let current = invoices.filter { !$0.isPastDue && !$0.isDueToday }

        let totalPastDue = pastDue.reduce(Decimal(0)) { $0 + $1.amount }
        let totalDueToday = dueToday.reduce(Decimal(0)) { $0 + $1.amount }
        let totalCurrent = current.reduce(Decimal(0)) { $0 + $1.amount }
        let totalAll = totalPastDue + totalDueToday + totalCurrent

        let subject = "Statement for \(client.name)"
        let intro = "Please find attached your statement and invoices with balances due. Please remit at your earliest convenience. If you have already paid, please disregard."

        var lines: [String] = []
        lines.append("Hello,\n")
        lines.append("\(intro)\n")
        lines.append("Total balance: \(formatAmount(totalAll))\n")
        if totalPastDue > 0 {
            lines.append("Past due: \(formatAmount(totalPastDue))\n")
        }
        if totalDueToday > 0 {
            lines.append("Due today: \(formatAmount(totalDueToday))\n")
        }
        if totalCurrent > 0 {
            lines.append("Current: \(formatAmount(totalCurrent))\n")
        }
        lines.append("\nInvoices:\n")
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        
        func cleanNumber(_ s: String) -> String { s.replacingOccurrences(of: ",", with: "") }

        for inv in invoices {
            let status: String
            if inv.isPastDue { status = "PAST DUE" }
            else if inv.isDueToday { status = "Due Today" }
            else { status = "Current" }
            let line = "#\(cleanNumber(inv.number)) — Issued: \(dateFormatter.string(from: inv.issueDate)), Due: \(dateFormatter.string(from: inv.dueDate)) — Amount: \(formatAmount(inv.amount)) — \(status)"
            lines.append(line)
        }
        lines.append("\nThank you,\nAccounts Receivable")

        return (subject, lines.joined(separator: "\n"))
    }
}

struct ARClientsView: View {
    @State private var viewModel = ARClientsViewModel()
    @State private var showingMailUnavailableAlert = false
    @State private var composingForClient: ARClient?
    @State private var showingMailComposer = false
    @State private var pendingMail: (subject: String, body: String, recipient: String)?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.clients) { client in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name)
                                .font(.headline)
                            Text(client.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if let sent = client.lastStatementEmailedAt {
                                Label("Emailed: \(sent.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("No statement sent yet", systemImage: "seal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            let content = viewModel.emailContent(for: client)
                            viewModel.emailStatement(for: client.id)
                            #if !targetEnvironment(macCatalyst)
                            if MFMailComposeViewController.canSendMail() {
                                pendingMail = (subject: content.subject, body: content.body, recipient: client.email)
                                showingMailComposer = true
                            } else {
                                composingForClient = client
                            }
                            #else
                            composingForClient = client
                            #endif
                        } label: {
                            Label("Email Statement", systemImage: "envelope")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("A/R Clients")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            .sheet(item: $composingForClient) { client in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Subject:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.emailContent(for: client).subject)
                            .font(.headline)
                        Text("Body:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(viewModel.emailContent(for: client).body)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Divider()
                        Text("Statement Preview")
                            .font(.headline)
                        // Header row with swapped columns
                        HStack {
                            Text("Invoice #").bold().frame(maxWidth: .infinity, alignment: .leading)
                            Text("Issue Date").bold().frame(maxWidth: .infinity, alignment: .leading)
                            Text("Due Date").bold().frame(maxWidth: .infinity, alignment: .leading)
                            Text("Balance").bold().frame(width: 100, alignment: .trailing)
                            Text("Paid").bold().frame(width: 80, alignment: .trailing)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 4)
                        ForEach(client.invoices) { inv in
                            // For demo: assume nothing paid yet
                            HStack {
                                Text("#\(inv.number.replacingOccurrences(of: ",", with: ""))").frame(maxWidth: .infinity, alignment: .leading)
                                Text(DateFormatter.localizedString(from: inv.issueDate, dateStyle: .medium, timeStyle: .none)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(DateFormatter.localizedString(from: inv.dueDate, dateStyle: .medium, timeStyle: .none)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(NumberFormatter.currencyString(from: inv.amount)).frame(width: 100, alignment: .trailing)
                                Text(NumberFormatter.currencyString(from: Decimal(0))).frame(width: 80, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Email Preview")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { composingForClient = nil } } }
                }
                .presentationSizing(.form)
            }
            #if !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showingMailComposer) {
                if let mail = pendingMail {
                    MailComposer(subject: mail.subject, recipients: [mail.recipient], body: mail.body)
                        .presentationSizing(.form)
                } else {
                    EmptyView()
                }
            }
            #endif
        }
    }
}

private extension NumberFormatter {
    static func currencyString(from decimal: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: decimal as NSDecimalNumber) ?? "$\(decimal)"
    }
}

#Preview("A/R Clients") {
    ARClientsView()
}
