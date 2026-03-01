//
//  WebProspectService.swift
//  DPconsult
//
//  CloudKit public database service for web contact form submissions.
//

import CloudKit
import SwiftData
import UserNotifications

@MainActor
final class WebProspectService: ObservableObject {
    static let shared = WebProspectService()

    private let container = CKContainer(identifier: "iCloud.com.dan.DPconsult")
    private var publicDB: CKDatabase { container.publicCloudDatabase }

    private let recordType = "WebProspect"
    private let subscriptionID = "web-prospect-new"

    // MARK: - Fetch unprocessed prospects

    func fetchNewProspects() async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "processed == %d", 0)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "submittedAt", ascending: false)]

        let (results, _) = try await publicDB.records(matching: query,
                                                       desiredKeys: nil,
                                                       resultsLimit: 100)
        return results.compactMap { try? $0.1.get() }
    }

    // MARK: - Import into SwiftData

    func importProspects(into context: ModelContext) async -> Int {
        guard let records = try? await fetchNewProspects(), !records.isEmpty else { return 0 }
        var importedCount = 0

        for record in records {
            let name  = record["name"]  as? String ?? ""
            let email = record["email"] as? String ?? ""

            // Deduplicate: skip if SDCustomer with same name+email already exists
            let descriptor = FetchDescriptor<SDCustomer>(
                predicate: #Predicate { $0.name == name && $0.email == email }
            )
            let existing = (try? context.fetchCount(descriptor)) ?? 0
            if existing > 0 {
                try? await markProcessed(record)
                continue
            }

            let phone    = record["phone"]    as? String ?? ""
            let business = record["business"] as? String ?? ""
            let message  = record["message"]  as? String ?? ""
            let submitted = record["submittedAt"] as? Date ?? Date()

            let notes = business.isEmpty
                ? message
                : "Business: \(business)\n\(message)"

            let customer = SDCustomer(
                name: name,
                phone: phone,
                email: email,
                notes: notes,
                active: true,
                webProspect: true
            )
            customer.createdAt = submitted
            context.insert(customer)
            importedCount += 1

            try? await markProcessed(record)
        }

        if importedCount > 0 {
            try? context.save()
        }
        return importedCount
    }

    // MARK: - Mark record as processed

    private func markProcessed(_ record: CKRecord) async throws {
        record["processed"] = 1 as CKRecordValue
        _ = try await publicDB.save(record)
    }

    // MARK: - Push notification subscription

    func registerSubscription() async {
        let predicate = NSPredicate(format: "processed == %d", 0)
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )

        let info = CKSubscription.NotificationInfo()
        info.title = "New Web Prospect"
        info.alertBody = "Someone submitted the contact form!"
        info.shouldBadge = true
        info.soundName = "default"
        subscription.notificationInfo = info

        do {
            _ = try await publicDB.save(subscription)
            print("[WebProspect] Subscription registered")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            print("[WebProspect] Subscription already exists, OK")
        } catch {
            print("[WebProspect] Subscription error: \(error)")
        }
    }

    // MARK: - Badge management

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}
