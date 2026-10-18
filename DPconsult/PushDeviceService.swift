//
//  PushDeviceService.swift
//  DPconsult
//
//  Tells the website's Cloudflare worker (dp-cloudkit-proxy) where to send "New Quote
//  Request" and "New Web Prospect" alerts: each iPhone/iPad saves its APNs token as a
//  public-database `PushDevice` record. Only apps entitled to this container can write
//  there, so nobody else can sign up for Dan's alerts. The Mac posts its own alerts
//  (DPconsultApp.importWebLeads), so it doesn't register.
//

import CloudKit
import OSLog
import UIKit

@MainActor
enum PushDeviceService {
    private static let log = Logger(subsystem: "com.dan.DPconsult", category: "push")

    static func register(token: Data) {
        #if !targetEnvironment(macCatalyst)
        let hex = token.map { String(format: "%02x", $0) }.joined()
        // Debug device builds are signed for the APNs sandbox; anything else is production.
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif

        let record = CKRecord(recordType: "PushDevice",
                              recordID: CKRecord.ID(recordName: "push-" + String(hex.prefix(40))))
        record["token"] = hex as CKRecordValue
        record["environment"] = environment as CKRecordValue
        record["deviceName"] = UIDevice.current.name as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .allKeys // same device re-registering overwrites its own record
        op.modifyRecordsResultBlock = { result in
            if case .failure(let error) = result {
                log.error("Push device save failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Push device registered (\(environment, privacy: .public))")
            }
        }
        CKContainer(identifier: "iCloud.com.dan.DPconsult").publicCloudDatabase.add(op)
        #endif
    }
}
