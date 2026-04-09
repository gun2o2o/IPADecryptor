import SwiftUI

struct AppListItemView: View {
    let app: InstalledApp
    let onDecrypt: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "app.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(app.bundleId).font(.caption2).foregroundStyle(.tertiary)
                    Text("v\(app.version)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Decrypt", action: onDecrypt)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
