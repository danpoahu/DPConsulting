//
//  BillingSummaryInbox.swift
//  DPconsult
//
//  Monthly work summaries that Claude writes to the Reports folder
//  (`<Client>-<Month>-<Year>-billing-summary.html`). The Mac app notices new ones,
//  badges Invoicing, and opens the Import Summary sheet already loaded, so Dan no
//  longer picks the file by hand. The folder only exists on the Mac; elsewhere the
//  inbox is simply empty.
//

import Foundation
import OSLog

enum BillingSummaryInbox {
    static let folder = URL(fileURLWithPath: "/Volumes/Xcode_Projects/Reports", isDirectory: true)
    static let suffix = "-billing-summary.html"

    /// File names already imported or dismissed. A per-Mac convenience, not business data,
    /// so it lives in UserDefaults rather than SwiftData/CloudKit.
    private static let seenKey = "billingSummaryInbox.seen"
    private static let log = Logger(subsystem: "com.dan.DPconsult", category: "billingInbox")

    /// New summaries, oldest first. The first time this runs, everything already in the
    /// folder counts as handled, so only summaries written from then on badge.
    static func pending(in folder: URL = folder, defaults: UserDefaults = .standard,
                        fileManager: FileManager = .default) -> [URL] {
        let files = summaries(in: folder, fileManager: fileManager)
        guard let seen = defaults.stringArray(forKey: seenKey) else {
            defaults.set(files.map(\.lastPathComponent), forKey: seenKey)
            log.info("Inbox baseline: \(files.count) existing summaries marked handled")
            return []
        }
        let seenSet = Set(seen)
        return files.filter { !seenSet.contains($0.lastPathComponent) }
    }

    static func markHandled(_ url: URL, defaults: UserDefaults = .standard) {
        var seen = defaults.stringArray(forKey: seenKey) ?? []
        guard !seen.contains(url.lastPathComponent) else { return }
        seen.append(url.lastPathComponent)
        defaults.set(seen, forKey: seenKey)
    }

    /// "LDAH-October-2026-billing-summary.html" → "LDAH October 2026"
    static func displayName(_ url: URL) -> String {
        String(url.lastPathComponent.dropLast(suffix.count)).replacingOccurrences(of: "-", with: " ")
    }

    private static func summaries(in folder: URL, fileManager: FileManager) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
