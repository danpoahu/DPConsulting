//
//  iCloudSyncPromptView.swift
//  DPconsult
//
//  First-launch prompt to enable iCloud sync.
//

import SwiftUI

struct iCloudSyncPromptView: View {
    let onEnable: () -> Void
    let onSkip: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "icloud")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Sync with iCloud?")
                    .font(.title.bold())

                Text("Enable iCloud sync to keep your data backed up and available across your devices.\n\nYour data will always be stored locally on this device either way.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: onEnable) {
                        Text("Enable iCloud Sync")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button("Not Now", action: onSkip)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
            .padding(32)
        }
        .interactiveDismissDisabled()
    }
}
