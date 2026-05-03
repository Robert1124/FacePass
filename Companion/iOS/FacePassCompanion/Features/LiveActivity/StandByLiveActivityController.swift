import ActivityKit
import FacePassCompanionCore
import Foundation

@MainActor
final class StandByLiveActivityController {
    func startOrUpdate(for mac: PairedMac, status: String) async throws -> String {
        guard #available(iOS 16.2, *) else {
            throw StandByLiveActivityError.unavailable
        }

        return try await startOrUpdateActivity(for: mac, status: status)
    }

    @available(iOS 16.2, *)
    private func startOrUpdateActivity(for mac: PairedMac, status: String) async throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw StandByLiveActivityError.disabled
        }

        let content = ActivityContent(
            state: StandByUnlockActivityAttributes.ContentState(
                status: status,
                lastRequestAt: Date(),
                isRequestInFlight: false
            ),
            staleDate: nil
        )

        if let activity = Activity<StandByUnlockActivityAttributes>.activities.first(
            where: { $0.attributes.macDeviceId == mac.macDeviceId }
        ) {
            await activity.update(content)
            return "StandBy card refreshed."
        }

        let attributes = StandByUnlockActivityAttributes(
            macDeviceId: mac.macDeviceId,
            macDisplayName: mac.displayName
        )
        _ = try Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )
        return "StandBy card started."
    }
}

enum StandByLiveActivityError: LocalizedError {
    case unavailable
    case disabled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Live Activities are unavailable on this iOS version."
        case .disabled:
            "Live Activities are disabled for FacePass."
        }
    }
}
