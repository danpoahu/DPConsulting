//
//  CustomerView.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/10/25.
//

import SwiftUI
import SwiftData

struct DPCustomersListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDCustomer.name) private var allCustomers: [SDCustomer]
    @State private var showAdd = false
    @State private var showArchived = false
    @State private var name = ""; @State private var email = ""; @State private var phone = ""; @State private var addr = ""; @State private var notes = ""
    @State private var editing: SDCustomer? = nil
    @State private var quotingCustomer: SDCustomer? = nil

    private var filteredCustomers: [SDCustomer] {
        allCustomers
            .filter { customer in
                if showArchived {
                    return !customer.active
                } else {
                    return customer.active
                }
            }
            .sorted { customer1, customer2 in
                customer1.createdAt > customer2.createdAt
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("Filter", selection: $showArchived) {
                        Text("Active").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                List(filteredCustomers, id: \.id) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        // Top row: name + badges — tap to edit
                        Button { editing = c } label: {
                            HStack {
                                Text(c.name).font(.headline)
                                Spacer()
                                if c.webProspect {
                                    Text("PROSPECT")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.orange)
                                        .clipShape(Capsule())
                                }
                                if !c.active {
                                    Text("ARCHIVED")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.gray)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        if !c.address.isEmpty { Text(c.address).font(.caption).foregroundStyle(.secondary) }

                        // Clickable phone
                        if !c.phone.isEmpty {
                            Button {
                                let digits = c.phone.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
                                if let url = URL(string: "tel:\(digits)") {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label(formatPhoneNumber(c.phone), systemImage: "phone.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }

                        // Clickable email
                        if !c.email.isEmpty {
                            Button {
                                if let url = URL(string: "mailto:\(c.email)") {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label(c.email, systemImage: "envelope.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }

                        // Bottom row: date + Quote button
                        HStack {
                            Text("Added \(c.createdAt, style: .date)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button { quotingCustomer = c } label: {
                                Label("Quote", systemImage: "doc.text.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.orange)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(showArchived ? "Archived Customers" : "DP Customers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { printCustomerList() } label: { Image(systemName: "printer") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Customer", isPresented: $showAdd) {
                TextField("Name", text: $name)
                TextField("Email", text: $email).keyboardType(.emailAddress)
                TextField("Phone", text: $phone).keyboardType(.phonePad)
                TextField("Address", text: $addr)
                Button("Add") {
                    let customer = SDCustomer(name: name, address: addr, phone: phone, email: email, notes: notes)
                    modelContext.insert(customer)
                    clear()
                }
                Button("Cancel", role: .cancel) { clear() }
            } message: { Text("Quick add") }
            .sheet(item: $editing) { c in
                DPCustomerEditor(customer: c)
                    .presentationSizing(.form)
            }
            .sheet(item: $quotingCustomer) { c in
                NavigationStack {
                    DPInvoicingView(customer: c)
                }
                .presentationSizing(.form)
            }
        }
    }

    private func clear() { name = ""; email = ""; phone = ""; addr = ""; notes = "" }

    private func printCustomerList() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = margin
            let title = showArchived ? "Archived Customers" : "Customer Directory"
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold)]
            (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttrs)
            y += 34
            let dateAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray]
            (DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none) as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: dateAttrs)
            y += 24

            let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
            let detailFont = UIFont.systemFont(ofSize: 11)
            let detailColor = UIColor.darkGray

            for customer in filteredCustomers {
                if y > page.height - 60 { ctx.beginPage(); y = margin }
                (customer.name as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: nameFont])
                y += 18
                if !customer.email.isEmpty {
                    (customer.email as NSString).draw(at: CGPoint(x: margin + 12, y: y), withAttributes: [.font: detailFont, .foregroundColor: detailColor])
                    y += 15
                }
                if !customer.phone.isEmpty {
                    (customer.phone as NSString).draw(at: CGPoint(x: margin + 12, y: y), withAttributes: [.font: detailFont, .foregroundColor: detailColor])
                    y += 15
                }
                if !customer.address.isEmpty {
                    (customer.address as NSString).draw(at: CGPoint(x: margin + 12, y: y), withAttributes: [.font: detailFont, .foregroundColor: detailColor])
                    y += 15
                }
                y += 8
            }
        }
        dpPrint(data: data, jobName: "Customer Directory")
    }
}

struct DPCustomerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var customer: SDCustomer

    @State private var name: String
    @State private var email: String
    @State private var phone: String
    @State private var address: String
    @State private var notes: String
    @State private var active: Bool
    @State private var webProspect: Bool

    init(customer: SDCustomer) {
        self.customer = customer
        _name = State(initialValue: customer.name)
        _email = State(initialValue: customer.email)
        _phone = State(initialValue: customer.phone)
        _address = State(initialValue: customer.address)
        _notes = State(initialValue: customer.notes)
        _active = State(initialValue: customer.active)
        _webProspect = State(initialValue: customer.webProspect)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Contact") {
                    TextField("Email", text: $email).keyboardType(.emailAddress)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                }
                Section("Address") {
                    TextField("Address", text: $address, axis: .vertical).lineLimit(1...3)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
                Section("Status") {
                    Toggle("Active Customer", isOn: $active)
                    Toggle("Web Prospect", isOn: $webProspect)
                }
            }
            .navigationTitle("Edit Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        customer.name = name
                        customer.email = email
                        customer.phone = phone
                        customer.address = address
                        customer.notes = notes
                        customer.active = active
                        customer.webProspect = webProspect
                        customer.updatedAt = Date()
                        dismiss()
                    }
                }
            }
        }
    }
}
