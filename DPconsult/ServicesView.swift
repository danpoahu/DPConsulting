//
//  ServicesView.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/10/25.
//

import SwiftUI
import SwiftData

struct DPServicesListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SDService.name) private var services: [SDService]
    @State private var showAdd = false
    @State private var name = ""; @State private var rateText = ""; @State private var desc = ""
    @State private var editing: SDService? = nil

    var body: some View {
        NavigationStack {
            List(services) { s in
                Button { editing = s } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.name).font(.headline)
                            Spacer()
                            Text(String(format: "$%.2f/hr", s.rate)).font(.subheadline)
                        }
                        if !s.serviceDescription.isEmpty {
                            Text(s.serviceDescription).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("DP Services")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { printServiceList() } label: { Image(systemName: "printer") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } }
            }
            .alert("New Service", isPresented: $showAdd) {
                TextField("Name", text: $name)
                TextField("Rate (per hour)", text: $rateText).keyboardType(.decimalPad)
                TextField("Description (optional)", text: $desc)
                Button("Add") {
                    let service = SDService(name: name, rate: Double(rateText) ?? 0, description: desc)
                    modelContext.insert(service)
                    clear()
                }
                Button("Cancel", role: .cancel) { clear() }
            } message: { Text("Quick add") }
            .sheet(item: $editing) { svc in
                DPServiceEditor(service: svc)
                    .presentationSizing(.form)
            }
        }
    }

    private func clear() { name = ""; rateText = ""; desc = "" }

    private func printServiceList() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = margin
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold)]
            ("Service Rate Sheet" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttrs)
            y += 34
            let dateAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray]
            (DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none) as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: dateAttrs)
            y += 24

            let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
            let rateFont = UIFont.systemFont(ofSize: 12)
            let descFont = UIFont.systemFont(ofSize: 11)

            for svc in services {
                if y > page.height - 60 { ctx.beginPage(); y = margin }
                (svc.name as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: nameFont])
                let rateStr = String(format: "$%.2f/hr", svc.rate)
                (rateStr as NSString).draw(at: CGPoint(x: page.width - margin - 100, y: y), withAttributes: [.font: rateFont, .foregroundColor: UIColor.systemBlue])
                y += 18
                if !svc.serviceDescription.isEmpty {
                    (svc.serviceDescription as NSString).draw(at: CGPoint(x: margin + 12, y: y), withAttributes: [.font: descFont, .foregroundColor: UIColor.darkGray])
                    y += 15
                }
                y += 10
            }
        }
        dpPrint(data: data, jobName: "Service Rate Sheet")
    }
}

struct DPServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var service: SDService

    @State private var name: String
    @State private var rateText: String
    @State private var desc: String

    init(service: SDService) {
        self.service = service
        _name = State(initialValue: service.name)
        _rateText = State(initialValue: String(format: "%.2f", service.rate))
        _desc = State(initialValue: service.serviceDescription)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }
                Section("Rate") { TextField("Rate (per hour)", text: $rateText).keyboardType(.decimalPad) }
                Section("Description") { TextField("Description", text: $desc, axis: .vertical).lineLimit(1...3) }
            }
            .navigationTitle("Edit Service")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        service.name = name
                        service.rate = Double(rateText) ?? service.rate
                        service.serviceDescription = desc
                        dismiss()
                    }
                }
            }
        }
    }
}
