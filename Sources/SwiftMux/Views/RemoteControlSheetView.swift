import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct RemoteControlSheetView: View {
    @ObservedObject var serverManager: RemoteServerManager

    @AppStorage("swiftmux.remote.bind-mode")
    private var bindModeRaw = RemoteServerBindMode.local.rawValue
    @AppStorage("swiftmux.remote.port")
    private var port = 8421
    @AppStorage("swiftmux.remote.require-token")
    private var requireToken = false
    @AppStorage("swiftmux.remote.token")
    private var token = ""

    @Environment(\.dismiss) private var dismiss

    private var bindMode: RemoteServerBindMode {
        get {
            RemoteServerBindMode(rawValue: bindModeRaw) ?? .local
        }
        nonmutating set {
            bindModeRaw = newValue.rawValue
            if newValue == .network {
                requireToken = true
                if token.isEmpty {
                    token = RemoteServerManager.generateToken()
                }
            }
        }
    }

    private var bindModeBinding: Binding<RemoteServerBindMode> {
        Binding(
            get: { bindMode },
            set: { bindMode = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text("Remote Control")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                RemoteServerStatusPill(state: serverManager.state)

                Spacer(minLength: 20)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("Bind", selection: bindModeBinding) {
                    ForEach(RemoteServerBindMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(serverManager.isActive)

                HStack(spacing: 12) {
                    Text("Port")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(AppTheme.mutedText)
                        .frame(width: 86, alignment: .leading)

                    TextField("8421", value: $port, formatter: NumberFormatter.remoteServerPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 86)
                        .disabled(serverManager.isActive)

                    Stepper("", value: $port, in: 1...65535)
                        .labelsHidden()
                        .disabled(serverManager.isActive)
                }

                Toggle("Require bearer token", isOn: $requireToken)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .disabled(serverManager.isActive)
                    .onChange(of: requireToken) { _, enabled in
                        if enabled, token.isEmpty {
                            token = RemoteServerManager.generateToken()
                        }
                    }

                if requireToken {
                    HStack(spacing: 10) {
                        Text("Token")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(AppTheme.mutedText)
                            .frame(width: 86, alignment: .leading)

                        TextField("Token", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .disabled(serverManager.isActive)

                        Button {
                            token = RemoteServerManager.generateToken()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Regenerate token")
                        .disabled(serverManager.isActive)

                        Button {
                            copy(token)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy token")
                    }
                }
            }
            .padding(14)
            .background(AppTheme.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if serverManager.isActive {
                HStack(alignment: .top, spacing: 14) {
                    if canScanFromPhone {
                        RemoteControlQRCodeView(urlString: serverManager.remoteURLString)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        RemoteControlInfoRow(label: canScanFromPhone ? "PHONE" : "LOCAL", value: serverManager.remoteURLString)
                        if !serverManager.launchCommand.isEmpty {
                            RemoteControlInfoRow(label: "Launch", value: serverManager.launchCommand)
                        }
                        if let processID = serverManager.processID {
                            RemoteControlInfoRow(label: "PID", value: String(processID))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(AppTheme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if case .failed(let message) = serverManager.state {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.red.opacity(0.9))
                        .textSelection(.enabled)

                    Button("Dismiss") {
                        serverManager.clearFailure()
                    }
                    .controlSize(.small)
                }
            }

            if !serverManager.logText.isEmpty {
                DisclosureGroup("Server Log") {
                    ScrollView {
                        Text(serverManager.logText)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: 150)
                    .background(AppTheme.windowBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack(spacing: 10) {
                if serverManager.isActive {
                    Button {
                        openBrowser()
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .disabled(!serverManager.isRunning)

                    Button {
                        copy(serverManager.remoteURLString)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .disabled(!serverManager.isRunning)

                    Spacer()

                    Button(role: .destructive) {
                        serverManager.stop()
                    } label: {
                        Label("Stop Server", systemImage: "stop.circle")
                    }
                    .tint(.red)
                } else {
                    Spacer()

                    Button {
                        startServer()
                    } label: {
                        Label("Start Server", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStartDisabled)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(AppTheme.panelBackground)
        .onAppear {
            if token.isEmpty {
                token = RemoteServerManager.generateToken()
            }
        }
    }

    private var isStartDisabled: Bool {
        port < 1 || port > 65535 || (requireToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canScanFromPhone: Bool {
        serverManager.host == RemoteServerBindMode.network.host
    }

    private func startServer() {
        let activeToken = requireToken ? token : nil
        serverManager.start(
            bindMode: bindMode,
            port: port,
            token: activeToken
        )
    }

    private func openBrowser() {
        guard let url = serverManager.browserURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct RemoteServerStatusPill: View {
    let state: RemoteServerManager.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(AppTheme.elevatedBackground)
        .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .stopped:
            return AppTheme.idleAccent
        case .starting:
            return AppTheme.waitingAccent
        case .running:
            return AppTheme.activeAccent
        case .failed:
            return .red
        }
    }
}

private struct RemoteControlInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.mutedText)
                .frame(width: 64, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct RemoteControlQRCodeView: View {
    let urlString: String

    var body: some View {
        Group {
            if let image = QRCodeRenderer.image(for: urlString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundColor(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 132, height: 132)
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private enum QRCodeRenderer {
    private static let context = CIContext()

    static func image(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: 132, height: 132))
    }
}

private extension NumberFormatter {
    static let remoteServerPort: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }()
}
