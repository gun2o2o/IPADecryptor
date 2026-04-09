import SwiftUI

struct DecryptionListView: View {
    @ObservedObject var vm: MainViewModel

    private var activeJobs: [DecryptionJob] {
        vm.jobs.filter { job in
            if job.state.isActive { return true }
            if case .failed = job.state { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Decrypting").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            Divider()

            if activeJobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "lock.open.rotation")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No active jobs")
                        .font(.headline).foregroundStyle(.secondary)
                    Text("Go to Apps tab and tap Decrypt")
                        .font(.subheadline).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(activeJobs) { job in
                        DecryptionRowView(job: job) {
                            vm.removeJob(id: job.id)
                        }
                    }
                }.listStyle(.inset)
            }
        }
    }
}
