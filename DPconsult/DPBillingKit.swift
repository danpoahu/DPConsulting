//  DPBillingKit.swift
//  DPconsult
//
//  Core: Helpers, Setup view, Home menu.
//  NOTE: Models are now in SDModels.swift. Firebase has been removed.

import SwiftUI
import SwiftData
import PDFKit
import UIKit

// MARK: - Print Helper

func dpPrint(data: Data, jobName: String) {
    let controller = UIPrintInteractionController.shared
    controller.printingItem = data
    let info = UIPrintInfo(dictionary: nil)
    info.jobName = jobName
    info.outputType = .general
    controller.printInfo = info
    controller.present(animated: true)
}

func dpPrint(url: URL, jobName: String) {
    guard let data = try? Data(contentsOf: url) else { return }
    dpPrint(data: data, jobName: jobName)
}

// MARK: - Helpers

extension Binding where Value == Date? {
    func defaulted(_ def: Date) -> Binding<Date> {
        .init(get: { self.wrappedValue ?? def }, set: { self.wrappedValue = $0 })
    }
}

// Phone number formatting helper
func formatPhoneNumber(_ phone: String) -> String {
    let digits = phone.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    if digits.count == 10 {
        let area = String(digits.prefix(3))
        let middle = String(digits.dropFirst(3).prefix(3))
        let last = String(digits.suffix(4))
        return "(\(area)) \(middle)-\(last)"
    }
    if digits.count == 11 && digits.hasPrefix("1") {
        let area = String(digits.dropFirst().prefix(3))
        let middle = String(digits.dropFirst(4).prefix(3))
        let last = String(digits.suffix(4))
        return "1 (\(area)) \(middle)-\(last)"
    }
    return phone
}

// Phone input formatter (for text fields)
func formatPhoneInput(_ input: String) -> String {
    let digits = input.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    let limited = String(digits.prefix(10))
    if limited.count <= 3 {
        return limited
    } else if limited.count <= 6 {
        let area = String(limited.prefix(3))
        let middle = String(limited.dropFirst(3))
        return "(\(area)) \(middle)"
    } else {
        let area = String(limited.prefix(3))
        let middle = String(limited.dropFirst(3).prefix(3))
        let last = String(limited.dropFirst(6))
        return "(\(area)) \(middle)-\(last)"
    }
}

// Invoice number formatting helper
func formatInvoiceNumber(_ number: Int) -> String {
    return "#\(number)"
}

// MARK: - Setup

struct DPSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var address = ""
    @State private var phone = ""
    @State private var salesTaxText = ""
    @State private var invoiceFooter = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var settings: SDCompanySettings?

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false
    @State private var showRestartAlert = false

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }

                Section("Company") {
                    TextField("Company Name", text: $name)
                    TextField("Address", text: $address, axis: .vertical).lineLimit(1...3)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                }
                Section("Sales Tax") {
                    TextField("Rate (e.g. 4.5 or 0.045)", text: $salesTaxText).keyboardType(.decimalPad)
                }
                Section("Invoice Footer") {
                    TextEditor(text: $invoiceFooter).frame(minHeight: 80)
                }
                Section("iCloud Sync") {
                    Toggle("Enable iCloud Sync", isOn: Binding(
                        get: { iCloudSyncEnabled },
                        set: { newValue in
                            iCloudSyncEnabled = newValue
                            UserDefaults.standard.set(newValue, forKey: "iCloudSyncEnabled")
                            showRestartAlert = true
                        }
                    ))
                    Text("Changing sync requires restarting the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DP Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: { if isSaving { ProgressView() } else { Text("Save") } }
                    .disabled(isSaving)
                }
            }
            .onAppear { loadSettings() }
            .alert("Restart Required", isPresented: $showRestartAlert) {
                Button("OK") { }
            } message: {
                Text("Please close and reopen the app to apply the sync change.")
            }
        }
    }

    private func loadSettings() {
        let s = loadOrCreateSettings(context: modelContext)
        settings = s
        name = s.name
        address = s.address
        phone = s.phone
        salesTaxText = s.salesTax == 0 ? "" : String(format: "%.4f", s.salesTax * 100)
        invoiceFooter = s.invoiceFooter
    }

    private func save() {
        isSaving = true; defer { isSaving = false }
        let s = settings ?? loadOrCreateSettings(context: modelContext)
        let raw = salesTaxText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        let input = Double(raw) ?? 0

        s.name = name
        s.address = address
        s.phone = phone
        s.salesTax = input > 1 ? input / 100.0 : input
        s.invoiceFooter = invoiceFooter
        s.updatedAt = Date()
        settings = s
        dismiss()
    }
}

// MARK: - Home menu (tiles open views defined in other files)

struct DPBillingHomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum ActiveSheet: String, Identifiable {
        case customers, services, invoicing, reports, setup, time, bookkeeping, accountsReceivable
        var id: String { rawValue }
    }
    @State private var activeSheet: ActiveSheet? = nil
    @State private var prospectCount: Int = 0

    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image("DPLogo").resizable().scaledToFit().frame(width: 140, height: 140).padding(.top, 5)
                    Text("DP Consulting").font(.title.bold()).foregroundColor(Color("TitleColor"))

                    LazyVGrid(columns: cols, spacing: 16) {
                        customersTileWithBadge()
                        tile("Services", "wrench.adjustable.fill", .services)
                        tile("Invoicing", "doc.text", .invoicing)
                        tile("A/R", "dollarsign.circle", .accountsReceivable)
                        tile("Time", "timer", .time)
                        tile("Reports", "chart.bar.doc.horizontal", .reports)
                        tile("Bookkeeping", "banknote", .bookkeeping)
                        tile("Setup", "gearshape", .setup)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { which in
                Group {
                    switch which {
                    case .customers: DPCustomersListView()
                    case .services:  DPServicesListView()
                    case .invoicing: DPInvoicesListView()
                    case .accountsReceivable: DPARStatementView()
                    case .reports:   DPReportsView()
                    case .setup:     DPSetupView()
                    case .time:      DPTimeView()
                    case .bookkeeping: DPBookkeepingView()
                    }
                }
                #if targetEnvironment(macCatalyst)
                .presentationSizing(.page)
                #else
                .presentationSizing(.form)
                #endif
            }
            .onChange(of: activeSheet) { oldValue, newValue in
                if newValue == .customers {
                    WebProspectService.shared.clearBadge()
                }
                if oldValue == .customers, newValue == nil {
                    loadProspectCount()
                }
            }
            .onAppear {
                loadProspectCount()
            }
        }
    }

    @ViewBuilder
    private func tile(_ title: String, _ sys: String, _ sheet: ActiveSheet) -> some View {
        Button { activeSheet = sheet } label: {
            VStack(spacing: 10) {
                Image(systemName: sys).font(.system(size: 30, weight: .semibold))
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 2, y: 1)
        }
    }

    @ViewBuilder
    private func customersTileWithBadge() -> some View {
        Button { activeSheet = .customers } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.2.fill").font(.system(size: 30, weight: .semibold))
                    if prospectCount > 0 {
                        Text("\(prospectCount)")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red)
                            .clipShape(Capsule())
                            .offset(x: 12, y: -8)
                    }
                }
                Text("Customers").font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 2, y: 1)
        }
    }

    private func loadProspectCount() {
        let descriptor = FetchDescriptor<SDCustomer>(
            predicate: #Predicate { $0.webProspect == true }
        )
        prospectCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - Prospects View

struct DPProspectsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<SDCustomer> { $0.webProspect == true },
           sort: \SDCustomer.createdAt, order: .reverse)
    private var prospects: [SDCustomer]
    @State private var selectedProspect: SDCustomer? = nil

    var body: some View {
        NavigationStack {
            Group {
                if prospects.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No Web Prospects")
                            .font(.title2.bold())
                        Text("Prospects from your website will appear here")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(prospects) { prospect in
                        Button {
                            selectedProspect = prospect
                        } label: {
                            ProspectRow(prospect: prospect)
                        }
                    }
                }
            }
            .navigationTitle("Web Prospects (\(prospects.count))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $selectedProspect) { prospect in
                DPProspectDetailView(prospect: prospect)
                    .presentationSizing(.form)
            }
        }
    }
}

struct ProspectRow: View {
    let prospect: SDCustomer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(prospect.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text(prospect.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !prospect.email.isEmpty {
                Label(prospect.email, systemImage: "envelope")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if !prospect.phone.isEmpty {
                Label(formatPhoneNumber(prospect.phone), systemImage: "phone")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if !prospect.notes.isEmpty {
                Text(prospect.notes)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DPProspectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let prospect: SDCustomer

    @State private var isConverting = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(prospect.name)
                            .font(.largeTitle.bold())

                        Text("Submitted \(prospect.createdAt, style: .date) at \(prospect.createdAt, style: .time)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if !prospect.email.isEmpty || !prospect.phone.isEmpty || !prospect.address.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Contact Information")
                                .font(.headline)
                            if !prospect.email.isEmpty {
                                Label(prospect.email, systemImage: "envelope").font(.body)
                            }
                            if !prospect.phone.isEmpty {
                                Label(formatPhoneNumber(prospect.phone), systemImage: "phone").font(.body)
                            }
                            if !prospect.address.isEmpty {
                                Label(prospect.address, systemImage: "location").font(.body)
                            }
                        }
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if !prospect.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Project Details / Message")
                                .font(.headline)
                            Text(prospect.notes)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(spacing: 12) {
                        Button {
                            convertToCustomer()
                        } label: {
                            HStack {
                                if isConverting {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "person.badge.plus")
                                }
                                Text("Convert to Customer").fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isConverting)

                        Button {
                            showDeleteAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Prospect").fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.red)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.top)
                }
                .padding()
            }
            .navigationTitle("Prospect Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Delete Prospect", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    modelContext.delete(prospect)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete this prospect? This action cannot be undone.")
            }
        }
    }

    private func convertToCustomer() {
        isConverting = true
        prospect.webProspect = false
        prospect.active = true
        prospect.updatedAt = Date()
        isConverting = false
        dismiss()
    }
}
