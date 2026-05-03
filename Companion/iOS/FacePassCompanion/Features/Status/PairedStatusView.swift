import FacePassCompanionCore
import SwiftUI

struct PairedStatusView: View {
    @ObservedObject var model: FacePassCompanionModel
    @State private var isRequestingUnlock = false
    @State private var isUpdatingActivity = false
    @State private var isShowingForgetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let pairedMac = model.pairedMac {
                    pairedMacSection(pairedMac)
                    unlockSection
                    standbyAccessSection
                    pairingSection
                } else {
                    Section {
                        VStack(spacing: 10) {
                            Label("No Mac Paired", systemImage: "desktopcomputer")
                                .font(.headline)
                            Text("Pair a Mac to request lock-screen unlock from this iPhone.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .navigationTitle("FacePass")
            .confirmationDialog(
                "Forget this Mac?",
                isPresented: $isShowingForgetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Forget Mac", role: .destructive) {
                    model.forgetPairedMac()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can pair this Mac again later from the Mac app.")
            }
        }
    }

    private func pairedMacSection(_ mac: PairedMac) -> some View {
        Section {
            LabeledContent("Name", value: mac.displayName)
            LabeledContent("Device ID", value: mac.macDeviceId)
            LabeledContent("Fingerprint", value: mac.publicKeyFingerprint)
            LabeledContent("Last Seen", value: formattedLastSeen(mac.lastSeenAt))
        } header: {
            Text("Paired Mac")
        }
    }

    private var unlockSection: some View {
        Section {
            Button {
                Task {
                    await requestUnlock()
                }
            } label: {
                Label("Unlock Mac", systemImage: "lock.open")
            }
            .disabled(isRequestingUnlock)

            LabeledContent("Last Result", value: model.lastUnlockStatus)
        } footer: {
            Text("The request is signed by this iPhone and sent locally to the paired Mac. The Mac password is never sent to or shown on this iPhone.")
        }
    }

    private var standbyAccessSection: some View {
        Section {
            Button {
                Task {
                    await startOrRefreshLiveActivity()
                }
            } label: {
                Label("Start or Refresh Live Activity", systemImage: "rectangle.on.rectangle")
            }
            .disabled(isUpdatingActivity)

            LabeledContent("Live Activity Status", value: model.lastLiveActivityStatus)

            VStack(alignment: .leading, spacing: 6) {
                Label("StandBy Widget", systemImage: "square.grid.2x2")
                    .font(.headline)

                Text("Add FacePass Unlock from the iOS widget gallery or StandBy customization. Its Unlock Mac button uses the same signed local request; iOS usually runs it without opening FacePass, but system behavior can vary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("StandBy Access")
        } footer: {
            Text("Live Activity and widget requests both require iPhone device approval and never send the Mac password to this iPhone.")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                model.isPairingPresented = true
            } label: {
                Label("Pair Another Mac", systemImage: "qrcode.viewfinder")
            }

            Button(role: .destructive) {
                isShowingForgetConfirmation = true
            } label: {
                Label("Forget Mac", systemImage: "trash")
            }
        }
    }

    private func requestUnlock() async {
        guard !isRequestingUnlock else {
            return
        }

        isRequestingUnlock = true
        defer { isRequestingUnlock = false }
        await model.requestUnlock()
    }

    private func startOrRefreshLiveActivity() async {
        guard !isUpdatingActivity else {
            return
        }

        isUpdatingActivity = true
        defer { isUpdatingActivity = false }
        await model.startOrRefreshLiveActivity()
    }

    private func formattedLastSeen(_ date: Date?) -> String {
        guard let date else {
            return "Not seen since pairing"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
