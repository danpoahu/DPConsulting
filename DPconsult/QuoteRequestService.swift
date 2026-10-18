//
//  QuoteRequestService.swift
//  DPconsult
//
//  Quote requests from oahuappdesign.com/quote/. The Cloudflare worker (dp-cloudkit-proxy)
//  saves each one as a public-database `QuoteRequest` and a cron run has Claude draft the
//  proposal into `draftText`. Here each request becomes a customer flagged as a web
//  prospect, with the proposal at the top of its notes, where Dan edits it.
//

import CloudKit
import OSLog
import SwiftData
import UserNotifications

@MainActor
final class QuoteRequestService {
    static let shared = QuoteRequestService()

    static let subscriptionID = "quote-request-ready"

    private let container = CKContainer(identifier: "iCloud.com.dan.DPconsult")
    private var publicDB: CKDatabase { container.publicCloudDatabase }
    private let recordType = "QuoteRequest"
    private let log = Logger(subsystem: "com.dan.DPconsult", category: "quoteRequests")

    /// A request still waiting on its draft is imported anyway after this long,
    /// with the client's raw answers, so nothing sits invisible.
    private let draftGracePeriod: TimeInterval = 30 * 60

    // MARK: - Import

    func importRequests(into context: ModelContext) async -> Int {
        let records: [CKRecord]
        do {
            records = try await fetchUnprocessed()
        } catch {
            log.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        guard !records.isEmpty else { return 0 }

        var customers = (try? context.fetch(FetchDescriptor<SDCustomer>())) ?? []
        var imported = 0

        for record in records {
            let ref = Self.ref(for: record)
            // Already imported (e.g. the processed flag failed to save last time).
            if customers.contains(where: { $0.notes.contains(ref) }) {
                await markProcessed(record)
                continue
            }

            let status = record["draftStatus"] as? String ?? "pending"
            let submitted = record["submittedAt"] as? Date ?? Date()
            if status == "pending", Date().timeIntervalSince(submitted) < draftGracePeriod {
                continue // Claude hasn't drafted it yet; the next run will.
            }

            let name = (record["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let email = (record["email"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let block = Self.notesBlock(for: record, ref: ref, submitted: submitted)

            if let customer = customers.first(where: { !email.isEmpty && $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                customer.notes = customer.notes.isEmpty ? block : block + "\n\n" + Self.divider + "\n\n" + customer.notes
                customer.webProspect = true
                customer.active = true
                customer.updatedAt = Date()
            } else {
                let customer = SDCustomer(
                    name: name.isEmpty ? email : name,
                    phone: record["phone"] as? String ?? "",
                    email: email,
                    notes: block,
                    active: true,
                    webProspect: true
                )
                customer.createdAt = submitted
                context.insert(customer)
                customers.append(customer) // a second request from the same email in this batch joins it
            }
            imported += 1
            await markProcessed(record)
        }

        if imported > 0 {
            do { try context.save() } catch { log.error("Save failed: \(error.localizedDescription, privacy: .public)") }
            log.info("Imported \(imported) quote request(s)")
        }
        return imported
    }

    private func fetchUnprocessed() async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(format: "processed == %d", 0))
        query.sortDescriptors = [NSSortDescriptor(key: "submittedAt", ascending: true)]
        let (results, _) = try await publicDB.records(matching: query, desiredKeys: nil, resultsLimit: 50)
        return results.compactMap { try? $0.1.get() }
    }

    private func markProcessed(_ record: CKRecord) async {
        record["processed"] = 1 as CKRecordValue
        do { _ = try await publicDB.save(record) } catch {
            log.error("Mark processed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Push notification when a draft is ready
    // Not called: Production refuses new subscriptions (Apple server issue, May 2026).
    // The app polls instead (DPconsultApp.importWebLeads). Kept for when Apple fixes it.

    func registerSubscription() async {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(format: "processed == %d AND draftStatus == %@", 0, "ready"),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.title = "New Quote Request"
        info.alertBody = "A proposal draft is ready to review in Customers."
        info.shouldBadge = true
        info.soundName = "default"
        subscription.notificationInfo = info

        do {
            _ = try await publicDB.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already registered.
        } catch {
            log.error("Subscription error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notes text

    static let header = "WEB QUOTE REQUEST"
    static let divider = "————————————————"

    static func ref(for record: CKRecord) -> String {
        "ref " + String(record.recordID.recordName.prefix(8))
    }

    static func notesBlock(for record: CKRecord, ref: String, submitted: Date) -> String {
        let date = submitted.formatted(date: .abbreviated, time: .shortened)
        let title = "\(header) · \(date) · \(ref)"
        if let draft = record["draftText"] as? String, !draft.isEmpty, record["draftStatus"] as? String == "ready" {
            return title + "\n" + draft
        }
        // No draft (Claude failed or is late): keep the client's answers so nothing is lost.
        let error = record["draftError"] as? String ?? ""
        var lines = [title, "No proposal draft yet\(error.isEmpty ? "" : " (\(error.prefix(120)))"). The client's answers:"]
        if let json = record["answersJSON"] as? String,
           let data = json.data(using: .utf8),
           let answers = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            lines += answers.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { "• \($0.key): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Local notification

/// Posts the "new web lead" alert from the app itself, since CloudKit push isn't available.
enum WebLeadNotifier {
    static func post(prospects: Int, quotes: Int, badge: Int) {
        let content = UNMutableNotificationContent()
        if quotes > 0 {
            content.title = quotes == 1 ? "New Quote Request" : "\(quotes) New Quote Requests"
            content.body = "A proposal draft is ready to review in Customers."
        } else {
            content.title = prospects == 1 ? "New Web Prospect" : "\(prospects) New Web Prospects"
            content.body = "Someone submitted the contact form."
        }
        content.sound = .default
        content.badge = NSNumber(value: badge)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Quote seeding from the notes

/// Reads the newest quote-request block in a customer's notes, so the Quote button can
/// start a quote from the proposal. It reads the notes as Dan left them: edit an hour
/// figure in the notes and the quote follows.
struct QuoteDraftSeed: Equatable {
    var title: String
    var items: [Line]
    var addsGET: Bool

    struct Line: Equatable {
        var description: String
        var hours: Double
        var rate: Double
    }

    static let getRate = 0.04712

    static func parse(_ notes: String) -> QuoteDraftSeed? {
        guard let start = notes.range(of: QuoteRequestService.header) else { return nil }
        var block = String(notes[start.lowerBound...])
        if let end = block.range(of: QuoteRequestService.divider) { block = String(block[..<end.lowerBound]) }
        let lines = block.components(separatedBy: .newlines)

        let title = lines.dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? "Proposal"

        var rate = 55.0
        if let m = block.firstMatch(of: #/at \$(\d+(?:\.\d+)?)/h/#), let r = Double(m.1) { rate = r }

        var items: [Line] = []
        var inScope = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SCOPE AND ESTIMATE") { inScope = true; continue }
            guard inScope else { continue }
            if line.isEmpty || line.hasPrefix("Subtotal") {
                if let m = line.firstMatch(of: #/contingency for unknowns: (\d+(?:\.\d+)?) h/#),
                   let h = Double(m.1), h > 0 {
                    items.append(Line(description: "Contingency for unknowns", hours: h, rate: rate))
                }
                if line.hasPrefix("Subtotal") || !items.isEmpty { break }
                continue
            }
            if let m = line.firstMatch(of: #/^•\s*(.+):\s*(\d+(?:\.\d+)?)\s*h\b/#), let h = Double(m.2) {
                items.append(Line(description: String(m.1), hours: h, rate: rate))
            }
        }
        guard !items.isEmpty else { return nil }
        return QuoteDraftSeed(title: title, items: items, addsGET: block.contains("Hawaii GET"))
    }

    /// Line items for `DPInvoicingView`: hours × rate, plus a GET line when the proposal adds GET
    /// (the app's own Sales Tax setting is 0, so GET travels as a line to match the proposal).
    var invoiceItems: [DPInvoiceItemDraft] {
        var drafts = items.map {
            DPInvoiceItemDraft(serviceId: "", description: $0.description, qty: $0.hours, rate: $0.rate)
        }
        if addsGET {
            let subtotal = drafts.reduce(0) { $0 + $1.amount }
            let get = (subtotal * Self.getRate * 100).rounded() / 100
            drafts.append(DPInvoiceItemDraft(serviceId: "", description: "Hawaii GET 4.712%", qty: 1, rate: get))
        }
        return drafts
    }
}
