//
//  SyncMonitor.swift
//  DPconsult
//
//  Surfaces CloudKit sync failures that were previously invisible.
//
//  Background: SwiftData mirrors to CloudKit through NSPersistentCloudKitContainer.
//  CloudKit modify operations are atomic per record zone, so a single rejected field
//  fails the entire batch and *nothing* uploads. Before this monitor existed, that
//  failure was reported only to the unified log, so the app looked completely healthy
//  while silently uploading nothing for weeks.
//

import Foundation
import CoreData
import OSLog
import Combine

@MainActor
final class SyncMonitor: ObservableObject {

    static let shared = SyncMonitor()

    private static let log = Logger(subsystem: "com.dan.DPconsult", category: "sync")

    /// Human-readable description of the most recent CloudKit failure, or nil when healthy.
    @Published private(set) var lastError: String?

    /// True when the app could not start CloudKit mirroring and silently opened a
    /// local-only store instead. Data written in this state never leaves the device.
    @Published private(set) var isLocalOnlyFallback = false

    /// When the last successful export (upload) completed.
    @Published private(set) var lastSuccessfulExport: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEvent(_:)),
            name: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil
        )
    }

    /// Called from the app's container setup when CloudKit init fails and the app
    /// falls back to a local-only store.
    nonisolated func reportLocalOnlyFallback() {
        Task { @MainActor in
            self.isLocalOnlyFallback = true
            Self.log.fault("Running local-only: CloudKit mirroring is NOT active.")
        }
    }

    @objc private nonisolated func handleEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }

        // Only finished events carry a result.
        guard event.endDate != nil else { return }

        let kind: String
        switch event.type {
        case .setup:  kind = "setup"
        case .import: kind = "import"
        case .export: kind = "export"
        @unknown default: kind = "unknown"
        }

        let error = event.error
        let succeeded = event.succeeded

        Task { @MainActor in
            if let error {
                let message = Self.describe(kind: kind, error: error)
                self.lastError = message
                Self.log.fault("\(message, privacy: .public)")
            } else if succeeded {
                if kind == "export" { self.lastSuccessfulExport = Date() }
                self.lastError = nil
                Self.log.debug("CloudKit \(kind, privacy: .public) succeeded.")
            }
        }
    }

    /// Turns a raw CKError into something that names the actual cause.
    private static func describe(kind: String, error: Error) -> String {
        let ns = error as NSError
        var detail = ns.localizedDescription

        // Core Data wraps the real CloudKit failure in the partial-errors dictionary.
        if let partial = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail = partial.localizedDescription
        }
        if detail.localizedCaseInsensitiveContains("production schema") {
            detail += " — a field in the app's model is missing from the Production CloudKit schema. Deploy the schema in the CloudKit Console; until then nothing will upload."
        }
        return "iCloud \(kind) failed: \(detail)"
    }
}
