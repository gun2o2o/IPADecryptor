import SwiftUI

struct LibraryView: View {
    @ObservedObject var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Text("\(vm.libraryItems.count) apps")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            Divider()

            if vm.libraryItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Library is Empty")
                        .font(.headline).foregroundStyle(.secondary)
                    Text("Decrypted IPA files will appear here")
                        .font(.subheadline).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.libraryItems) { job in
                        LibraryItemView(job: job) {
                            if case .completed(let path) = job.state {
                                vm.revealInFinder(path: path)
                            }
                        } onRemove: {
                            vm.removeJob(id: job.id)
                        }
                    }
                }.listStyle(.inset)
            }
        }
    }
}
