//
//  OneTimeCleanup.swift
//  DPconsult
//
//  Data fixes that must go through SwiftData (so iCloud sync carries them) rather than
//  edits to the store file. Each runs once per device, keyed in UserDefaults.
//

import OSLog
import SwiftData
import UserNotifications

@MainActor
enum OneTimeCleanup {
    private static let log = Logger(subsystem: "com.dan.DPconsult", category: "cleanup")

    static func run(_ context: ModelContext, defaults: UserDefaults = .standard) {
        removeQuoteTestData(context, defaults: defaults)
    }

    /// 2026-10-17: the quote-generator test left two "TEST … (delete me)" customers
    /// (test@example.test), a draft quote #2077 on one of them, and Dan's own customer
    /// flagged from his test of the live page. Dan asked for the test customers gone and
    /// the badge cleared, keeping his own customer.
    private static func removeQuoteTestData(_ context: ModelContext, defaults: UserDefaults) {
        let key = "cleanup.2026-10-17.quoteTestData"
        guard !defaults.bool(forKey: key) else { return }

        let customers = (try? context.fetch(FetchDescriptor<SDCustomer>())) ?? []
        let tests = customers.filter {
            $0.email.lowercased() == "test@example.test" && $0.name.hasPrefix("TEST ") && $0.name.hasSuffix("(delete me)")
        }
        var removedInvoices = 0
        for customer in tests {
            let invoices = customer.invoices ?? []
            // Only quotes/drafts: anything that reached the books is left alone (and so is the customer).
            guard invoices.allSatisfy({ ["draft", "quote"].contains($0.status.lowercased()) && !$0.journalPosted }) else {
                log.error("Skipped \(customer.name, privacy: .public): has non-draft invoices")
                continue
            }
            for invoice in invoices {
                for item in invoice.items ?? [] { context.delete(item) }
                context.delete(invoice)
                removedInvoices += 1
            }
            context.delete(customer)
        }

        for customer in customers where customer.email.lowercased() == "dan@oahuappdesign.com" && customer.webProspect {
            customer.webProspect = false
            customer.updatedAt = Date()
        }

        do {
            try context.save()
            defaults.set(true, forKey: key)
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
            log.info("Quote test cleanup: removed \(tests.count) customers, \(removedInvoices) draft quotes")
        } catch {
            log.error("Quote test cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
