import SwiftUI

struct SettingsView: View {
    @AppStorage("sshHost") private var sshHost = "127.0.0.1"
    @AppStorage("sshPort") private var sshPort = "2222"
    @AppStorage("sshPassword") private var sshPassword = "alpine"
    @AppStorage("vphoneVersion") private var vphoneVersion = "stable"

    var body: some View {
        Form {
            Section("vphone-cli Version") {
                Picker("Version", selection: $vphoneVersion) {
                    Text("Stable (a7dd34f + iOS 26.1) — Recommended").tag("stable")
                    Text("Latest (GitHub main — may need firmware update)").tag("latest")
                }
                .pickerStyle(.radioGroup)
                Text("Stable is tested and verified. Latest may require different firmware.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("VM SSH Connection") {
                HStack {
                    TextField("Host", text: $sshHost).frame(width: 160)
                    Text(":").foregroundStyle(.secondary)
                    TextField("Port", text: $sshPort).frame(width: 60)
                }
                SecureField("Password", text: $sshPassword)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
    }
}
