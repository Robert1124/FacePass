import FacePassCore
import SwiftUI

struct PermissionStatusRow: View {
    let status: PermissionStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status.isGranted ? .green : .orange)
                .frame(width: 18)

            Text(status.title)

            Spacer()

            Text(status.statusText)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
