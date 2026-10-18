//
//  LeadActivityService.swift
//  DPconsult
//
//  Lets the website worker start the "new web lead" Live Activity (Lock Screen,
//  Dynamic Island, Apple Watch Smart Stack). iOS hands out a push-to-start token; it
//  goes into the same public `PushDevice` record type as the alert token, with a
//  "lastart-" record name so the worker sends it a Live Activity push instead of an alert.
//  Opening DPconsult clears the cards: by then Dan has seen the lead.
//

import CloudKit
import OSLog
import UIKit
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor
enum LeadActivityService {
    private static let log = Logger(subsystem: "com.dan.DPconsult", category: "liveActivity")
    private static var observing = false

    static func start() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard !observing else { return }
        observing = true
        Task {
            for await token in Activity<LeadActivityAttributes>.pushToStartTokenUpdates {
                save(token: token)
            }
        }
        #endif
    }

    /// Ends any lead cards on screen. Called when the app becomes active.
    static func endAll() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        Task {
            for activity in Activity<LeadActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    private static func save(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        // One record per device: a new token from the same device replaces the old one.
        let device = UIDevice.current.identifierForVendor?.uuidString ?? String(hex.prefix(32))
        let record = CKRecord(recordType: "PushDevice", recordID: CKRecord.ID(recordName: "lastart-" + device))
        record["token"] = hex as CKRecordValue
        record["environment"] = environment as CKRecordValue
        record["deviceName"] = (UIDevice.current.name + " (Live Activity)") as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.modifyRecordsResultBlock = { result in
            if case .failure(let error) = result {
                log.error("Live Activity token save failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Live Activity push-to-start token registered")
            }
        }
        CKContainer(identifier: "iCloud.com.dan.DPconsult").publicCloudDatabase.add(op)
    }
}
