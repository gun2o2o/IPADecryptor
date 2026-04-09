import SwiftUI

struct DecryptionRowView: View {
    let job: DecryptionJob
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay { Image(systemName: "app.fill").foregroundStyle(.secondary) }
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.app.name).font(.body).lineLimit(1)

                switch job.state {
                case .active(let phase):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Image(systemName: phase.icon).foregroundStyle(.purple)
                        Text(phase.label).foregroundStyle(.secondary)
                    }.font(.caption)

                case .failed(let error):
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)

                case .completed:
                    Label("Decrypted", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)

                case .idle:
                    Text("Waiting...").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !job.state.isActive {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
