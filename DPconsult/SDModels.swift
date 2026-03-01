//
//  SDModels.swift
//  DPconsult
//
//  SwiftData models replacing Firebase/Firestore data layer.
//

import SwiftData
import Foundation

// MARK: - Customer

@Model
final class SDCustomer {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var phone: String = ""
    var email: String = ""
    var notes: String = ""
    var active: Bool = true
    var webProspect: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \SDInvoice.customer)
    var invoices: [SDInvoice]? = []

    var display: String { name }

    init(name: String, address: String = "", phone: String = "",
         email: String = "", notes: String = "", active: Bool = true,
         webProspect: Bool = false) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.phone = phone
        self.email = email
        self.notes = notes
        self.active = active
        self.webProspect = webProspect
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Service

@Model
final class SDService {
    var id: UUID = UUID()
    var name: String = ""
    var rate: Double = 0
    var serviceDescription: String = ""
    var createdAt: Date = Date()

    init(name: String, rate: Double, description: String = "") {
        self.id = UUID()
        self.name = name
        self.rate = rate
        self.serviceDescription = description
        self.createdAt = Date()
    }
}

// MARK: - Invoice

@Model
final class SDInvoice {
    var id: UUID = UUID()
    var invoiceNumber: Int = 0
    var status: String = "draft"
    var customer: SDCustomer?
    var issueDate: Date = Date()
    var dueDate: Date?
    var notes: String = ""
    var subtotal: Double = 0
    var tax: Double = 0
    var total: Double = 0
    var amountPaid: Double = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Store customerId as string for cross-reference when customer relationship isn't set
    var customerId: String = ""

    @Relationship(deleteRule: .cascade)
    var items: [SDInvoiceItem]? = []

    @Relationship(deleteRule: .cascade)
    var timeLogs: [SDTimeLog]? = []

    var balance: Double { total - amountPaid }

    var isOverdue: Bool {
        guard let dueDate, balance > 0 else { return false }
        return Calendar.current.startOfDay(for: dueDate) < Calendar.current.startOfDay(for: Date())
    }

    var daysOverdue: Int {
        guard let dueDate, isOverdue else { return 0 }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: dueDate), to: cal.startOfDay(for: Date())).day ?? 0
    }

    var sortedItems: [SDInvoiceItem] {
        (items ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    init(invoiceNumber: Int, status: String = "draft", customer: SDCustomer? = nil,
         customerId: String = "", issueDate: Date = Date(), dueDate: Date? = nil,
         notes: String = "", subtotal: Double = 0, tax: Double = 0,
         total: Double = 0, amountPaid: Double = 0) {
        self.id = UUID()
        self.invoiceNumber = invoiceNumber
        self.status = status
        self.customer = customer
        self.customerId = customerId
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.notes = notes
        self.subtotal = subtotal
        self.tax = tax
        self.total = total
        self.amountPaid = amountPaid
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Invoice Item

@Model
final class SDInvoiceItem {
    var id: UUID = UUID()
    var serviceId: String = ""
    var itemDescription: String = ""
    var qty: Double = 0
    var rate: Double = 0
    var notes: String = ""
    var sortOrder: Int = 0

    var invoice: SDInvoice?

    var amount: Double { qty * rate }

    init(serviceId: String = "", description: String = "", qty: Double = 0,
         rate: Double = 0, notes: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.serviceId = serviceId
        self.itemDescription = description
        self.qty = qty
        self.rate = rate
        self.notes = notes
        self.sortOrder = sortOrder
    }
}

// MARK: - Time Log

@Model
final class SDTimeLog {
    var id: UUID = UUID()
    var lineIndex: Int = 0
    var startedAt: Date = Date()
    var stoppedAt: Date = Date()
    var seconds: Double = 0
    var createdAt: Date = Date()

    var invoice: SDInvoice?

    init(lineIndex: Int, startedAt: Date, stoppedAt: Date, seconds: Double) {
        self.id = UUID()
        self.lineIndex = lineIndex
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.seconds = seconds
        self.createdAt = Date()
    }
}

// MARK: - Company Settings

@Model
final class SDCompanySettings {
    var id: UUID = UUID()
    var name: String = "Your Company"
    var address: String = ""
    var phone: String = ""
    var salesTax: Double = 0
    var invoiceFooter: String = ""
    var updatedAt: Date = Date()

    init(name: String = "Your Company", address: String = "", phone: String = "",
         salesTax: Double = 0, invoiceFooter: String = "") {
        self.id = UUID()
        self.name = name
        self.address = address
        self.phone = phone
        self.salesTax = salesTax
        self.invoiceFooter = invoiceFooter
        self.updatedAt = Date()
    }
}

// MARK: - Bookkeeping Account

@Model
final class SDAccount {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = "asset"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var type: BKAccountType {
        get { BKAccountType(rawValue: typeRaw) ?? .asset }
        set { typeRaw = newValue.rawValue }
    }

    init(name: String, type: BKAccountType) {
        self.id = UUID()
        self.name = name
        self.typeRaw = type.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Journal Entry

@Model
final class SDJournalEntry {
    var id: UUID = UUID()
    var date: Date = Date()
    var memo: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade)
    var lines: [SDEntryLine]? = []

    var sortedLines: [SDEntryLine] {
        (lines ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var isBalanced: Bool {
        let ls = lines ?? []
        let sumDebits = ls.reduce(0) { $0 + $1.debit }
        let sumCredits = ls.reduce(0) { $0 + $1.credit }
        return abs(sumDebits - sumCredits) < 0.0001
    }

    init(date: Date = Date(), memo: String = "") {
        self.id = UUID()
        self.date = date
        self.memo = memo
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Entry Line

@Model
final class SDEntryLine {
    var id: UUID = UUID()
    var accountId: UUID = UUID()
    var debit: Double = 0
    var credit: Double = 0
    var memo: String = ""
    var sortOrder: Int = 0

    var journalEntry: SDJournalEntry?

    init(accountId: UUID, debit: Double = 0, credit: Double = 0,
         memo: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.accountId = accountId
        self.debit = debit
        self.credit = credit
        self.memo = memo
        self.sortOrder = sortOrder
    }
}

// MARK: - Counter

@Model
final class SDCounter {
    var id: UUID = UUID()
    var name: String = ""
    var current: Int = 0

    init(name: String, current: Int = 0) {
        self.id = UUID()
        self.name = name
        self.current = current
    }
}

// MARK: - Helper: Next Invoice Number

func nextInvoiceNumber(context: ModelContext) -> Int {
    let descriptor = FetchDescriptor<SDCounter>(
        predicate: #Predicate { $0.name == "invoice" }
    )
    let counters = (try? context.fetch(descriptor)) ?? []

    if let counter = counters.first {
        counter.current += 1
        return counter.current
    } else {
        let counter = SDCounter(name: "invoice", current: 1)
        context.insert(counter)
        return 1
    }
}

// MARK: - Helper: Load or Create Settings

func loadOrCreateSettings(context: ModelContext) -> SDCompanySettings {
    let descriptor = FetchDescriptor<SDCompanySettings>()
    let all = (try? context.fetch(descriptor)) ?? []
    if let existing = all.first {
        return existing
    }
    let settings = SDCompanySettings()
    context.insert(settings)
    return settings
}

// MARK: - Helper: Ensure Default Accounts

func ensureDefaultAccounts(context: ModelContext) {
    let descriptor = FetchDescriptor<SDAccount>()
    let accounts = (try? context.fetch(descriptor)) ?? []

    if !accounts.contains(where: { $0.name.caseInsensitiveCompare("Cash") == .orderedSame && $0.type == .asset }) {
        context.insert(SDAccount(name: "Cash", type: .asset))
    }
    if !accounts.contains(where: { $0.name.caseInsensitiveCompare("Sales Revenue") == .orderedSame && $0.type == .income }) {
        context.insert(SDAccount(name: "Sales Revenue", type: .income))
    }
    if !accounts.contains(where: { $0.name.caseInsensitiveCompare("Accounts Receivable") == .orderedSame && $0.type == .asset }) {
        context.insert(SDAccount(name: "Accounts Receivable", type: .asset))
    }
}
