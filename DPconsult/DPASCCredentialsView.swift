#if false
import SwiftUI

struct DPASCCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var pemText = ""
    @State private var status = ""
    @State private var isTesting = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("App Store Connect")) {
                    TextField("Issuer ID", text: $issuerId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Key ID", text: $keyId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Private Key (.p8 as PEM)")) {
                    TextEditor(text: $pemText)
                        .frame(minHeight: 150)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("You can paste the entire PEM block including BEGIN/END lines.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Actions") {
                    Button("Save") {
                        saveCredentials()
                    }
                    .disabled(isTesting)
                    
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || issuerId.isEmpty || keyId.isEmpty || pemText.isEmpty)
                    
                    Button("Delete") {
                        deleteCredentials()
                    }
                    .foregroundColor(.red)
                    .disabled(isTesting)
                }
                
                if !status.isEmpty {
                    Section {
                        Text(status)
                            .foregroundColor(status.contains("error") || status.contains("Error") ? .red : .green)
                    }
                }
            }
            .navigationTitle("ASC Credentials")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadCredentials()
            }
        }
    }
    
    private func saveCredentials() {
        status = ""
        guard !issuerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "All fields are required."
            return
        }
        
        do {
            let creds = DPASCCredentials(issuerId: issuerId, keyId: keyId, privateKeyPEM: pemText)
            try DPASCCredentialsManager.shared.save(creds)
            status = "Credentials saved successfully."
        } catch {
            status = "Error saving credentials: \(error.localizedDescription)"
        }
    }
    
    private func testConnection() {
        status = ""
        isTesting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try DPASCCredentialsManager.shared.generateJWT()
                DispatchQueue.main.async {
                    status = "Test successful: JWT generated."
                    isTesting = false
                }
            } catch {
                DispatchQueue.main.async {
                    status = "Test failed: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
    
    private func deleteCredentials() {
        status = ""
        do {
            try DPASCCredentialsManager.shared.delete()
            issuerId = ""
            keyId = ""
            pemText = ""
            status = "Credentials deleted."
        } catch {
            status = "Error deleting credentials: \(error.localizedDescription)"
        }
    }
    
    private func loadCredentials() {
        if let creds = DPASCCredentialsManager.shared.load() {
            issuerId = creds.issuerId
            keyId = creds.keyId
            pemText = creds.privateKeyPEM
        }
    }
}

struct DPASCCredentialsView_Previews: PreviewProvider {
    static var previews: some View {
        DPASCCredentialsView()
    }
}
#endif
