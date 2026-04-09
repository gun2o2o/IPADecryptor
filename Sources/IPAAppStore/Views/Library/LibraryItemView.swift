import SwiftUI

struct LibraryItemView: View {
    let job: DecryptionJob
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .overlay { Image(systemName: "app.fill").foregroundStyle(.secondary) }
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.app.name)
                    .font(.body).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 10) {
                    Text(job.app.bundleId)
                    Text("v\(job.app.version)")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button(action: onReveal) {
                    Label("Show", systemImage: "folder")
                }.buttonStyle(.bordered).controlSize(.small)

                Button(action: onRemove) {
                    Image(systemName: "trash")
                }.buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}
