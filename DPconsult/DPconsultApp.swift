//
//  DPconsultApp.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/7/25.
//

import SwiftUI
import SwiftData
import OSLog
#if targetEnvironment(macCatalyst)
import UIKit
#endif

@main
struct DPconsultApp: App {
    static let log = Logger(subsystem: "com.dan.DPconsult", category: "lifecycle")

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasShownSyncPrompt") private var hasShownSyncPrompt: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSyncPrompt = false
    @State private var showRestartAlert = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDCustomer.self, SDService.self, SDInvoice.self,
            SDInvoiceItem.self, SDTimeLog.self, SDCompanySettings.self,
            SDAccount.self, SDJournalEntry.self, SDEntryLine.self,
            SDCounter.self
        ])

        // Default iCloud sync ON. `bool(forKey:)` returns false for an unset key, so a
        // fresh install previously synced nothing until the toggle was found manually —
        // and the setting is per-device, so every device had to be switched on separately.
        if UserDefaults.standard.object(forKey: "iCloudSyncEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")
        }
        let iCloudEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        // The app is unsandboxed, so SwiftData's default store path resolves to the shared
        // ~/Library/Application Support/default.store, which another unsandboxed app also
        // claims. Sharing that file leaves foreign CloudKit mirroring metadata in the store
        // and prevents this app's sync from engaging. Own the path explicitly.
        let storeURL: URL = {
            let dir = URL.applicationSupportDirectory.appending(path: "DPconsult", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appending(path: "DPconsult.store")
        }()

        let primary = ModelConfiguration(schema: schema,
                                         url: storeURL,
                                         cloudKitDatabase: iCloudEnabled ? .automatic : .none)

        do {
            let c = try ModelContainer(for: schema, configurations: [primary])
            DPconsultApp.log.info("ModelContainer init OK (iCloud=\(iCloudEnabled, privacy: .public))")
            return c
        } catch {
            // CloudKit-mode init occasionally fails on Mac Catalyst (entitlement/cache/account state).
            // Fall back to local-only so the app still launches and the user can see their data.
            DPconsultApp.log.error("ModelContainer init failed (iCloud=\(iCloudEnabled, privacy: .public)): \(String(describing: error), privacy: .public)")
            if iCloudEnabled {
                let fallback = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
                do {
                    let c = try ModelContainer(for: schema, configurations: [fallback])
                    DPconsultApp.log.error("ModelContainer fell back to local-only after CloudKit init failure")
                    // Make the fallback visible in the UI. Previously this was logged
                    // only, so the app looked normal while saving nothing to iCloud.
                    SyncMonitor.shared.reportLocalOnlyFallback()
                    return c
                } catch {
                    fatalError("Could not create ModelContainer (fallback also failed): \(error)")
                }
            }
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            DPBillingHomeView()
                .onAppear {
                    #if targetEnvironment(macCatalyst)
                    configureMacWindow()
                    #endif
                    if !hasShownSyncPrompt {
                        showSyncPrompt = true
                    }
                    Task {
                        OneTimeCleanup.run(sharedModelContainer.mainContext)
                        await WebProspectService.shared.registerSubscription()
                        await importWebLeads()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .newWebProspectReceived)) { _ in
                    Task { await importWebLeads(manual: true) } // Refresh button or push
                }
                .sheet(isPresented: $showSyncPrompt) {
                    iCloudSyncPromptView(
                        onEnable: {
                            UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")
                            hasShownSyncPrompt = true
                            showSyncPrompt = false
                            showRestartAlert = true
                        },
                        onSkip: {
                            hasShownSyncPrompt = true
                            showSyncPrompt = false
                        }
                    )
                    .presentationSizing(.form)
                }
                .alert("Restart Required", isPresented: $showRestartAlert) {
                    Button("OK") { }
                } message: {
                    Text("Please close and reopen the app to activate iCloud sync.")
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(from: oldPhase, to: newPhase)
                }
                // Apple won't create new CloudKit subscriptions in Production (known server
                // issue, forums thread 826814, May 2026), so web leads can't rely on push.
                // While the app is open it checks every 10 minutes instead.
                .onReceive(Timer.publish(every: 600, on: .main, in: .common).autoconnect()) { _ in
                    Task { await importWebLeads() }
                }
        }
        .modelContainer(sharedModelContainer)
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 800, height: 900)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func configureMacWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                windowScene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 500)
                windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1400, height: 2000)
                let screen = windowScene.screen.bounds
                let width: CGFloat = 800
                let height: CGFloat = min(screen.height - 100, 1000)
                let x = (screen.width - width) / 2
                let frame = CGRect(x: x, y: 50, width: width, height: height)
                windowScene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.Mac(systemFrame: frame)
                )
            }
        }
    }
    #endif

    private func handleScenePhaseChange(from old: ScenePhase, to new: ScenePhase) {
        DPconsultApp.log.info("scenePhase: \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)")
        guard new == .active, old != .active else { return }
        // Mac Catalyst can leave SwiftData/CloudKit views stale when the window
        // returns from background. Saving the main context (no-op if no changes)
        // and counting records here both nudges sync and surfaces empty-state
        // events in the log for future debugging.
        let ctx = sharedModelContainer.mainContext
        do {
            try ctx.save()
        } catch {
            DPconsultApp.log.error("scenePhase save() failed: \(String(describing: error), privacy: .public)")
        }
        let customers = (try? ctx.fetchCount(FetchDescriptor<SDCustomer>())) ?? -1
        let invoices = (try? ctx.fetchCount(FetchDescriptor<SDInvoice>())) ?? -1
        DPconsultApp.log.info("on .active: customers=\(customers) invoices=\(invoices)")
        Task { await importWebLeads() }
    }

    /// Contact-form prospects and quote requests from oahuappdesign.com. Anything new
    /// gets a Mac notification and refreshes the home-screen badges.
    @MainActor private static var importingWebLeads = false

    @MainActor
    private func importWebLeads(manual: Bool = false) async {
        // Automatic checks run on the Mac only. If the iPhone and iPad polled too, two
        // devices could import the same request before either marks it processed, and
        // iCloud would sync both copies. They get the result through sync instead.
        #if !targetEnvironment(macCatalyst)
        guard manual else { return }
        #endif
        // The timer, the push handler and scene activation can overlap; two runs at
        // once would both import the same request before either saves.
        guard !Self.importingWebLeads else { return }
        Self.importingWebLeads = true
        defer { Self.importingWebLeads = false }
        let ctx = ModelContext(sharedModelContainer)
        let prospects = await WebProspectService.shared.importProspects(into: ctx)
        let quotes = await QuoteRequestService.shared.importRequests(into: ctx)
        guard prospects + quotes > 0 else { return }
        DPconsultApp.log.info("Imported web leads: prospects=\(prospects) quotes=\(quotes)")
        let waiting = (try? ctx.fetchCount(FetchDescriptor<SDCustomer>(predicate: #Predicate { $0.webProspect }))) ?? 0
        WebLeadNotifier.post(prospects: prospects, quotes: quotes, badge: waiting)
        NotificationCenter.default.post(name: .webLeadsImported, object: nil)
    }

}
