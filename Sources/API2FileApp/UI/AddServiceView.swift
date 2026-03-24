import SwiftUI
import API2FileCore

struct AddServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [AdapterTemplate] = []
    @State private var selectedTemplate: AdapterTemplate?
    @State private var apiKey: String = ""
    @State private var extraFieldValues: [String: String] = [:]
    @State private var isConnecting = false
    @State private var error: String?
    @State private var step: SetupStep = .selectService

    var onComplete: ((String?) -> Void)?

    init(onComplete: ((String?) -> Void)? = nil) {
        self.onComplete = onComplete
    }

    enum SetupStep {
        case selectService
        case enterCredentials
        case connecting
        case done
    }

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .selectService:
                selectServiceStep
            case .enterCredentials:
                enterCredentialsStep
            case .connecting:
                connectingStep
            case .done:
                doneStep
            }
        }
        .frame(width: 400, height: dynamicHeight)
        .padding()
        .task {
            templates = (try? await AdapterStore.shared.loadAll()) ?? []
        }
    }

    private var dynamicHeight: CGFloat {
        if step == .enterCredentials, let template = selectedTemplate, !(template.config.setupFields ?? []).isEmpty {
            return 300 + CGFloat((template.config.setupFields ?? []).count) * 60
        }
        return 300
    }

    // MARK: - Steps

    private var selectServiceStep: some View {
        VStack(spacing: 16) {
            Text("Add Service")
                .font(.title2)
                .fontWeight(.bold)

            Text("Choose a cloud service to sync:")
                .foregroundStyle(.secondary)

            if templates.isEmpty {
                ProgressView()
                    .padding()
            } else {
                ForEach(templates, id: \.config.service) { template in
                    Button {
                        selectedTemplate = template
                        extraFieldValues = [:]
                        step = .enterCredentials
                    } label: {
                        HStack {
                            Image(systemName: template.config.icon ?? "cloud")
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(template.config.displayName)
                                    .fontWeight(.medium)
                                Text(template.config.wizardDescription ?? template.config.resources.map(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
    }

    private var enterCredentialsStep: some View {
        VStack(spacing: 16) {
            Text("Connect \(selectedTemplate?.config.displayName ?? "")")
                .font(.title2)
                .fontWeight(.bold)

            if let template = selectedTemplate {
                Text(template.config.auth.setup?.instructions ?? "")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let urlString = template.config.auth.setup?.url, let url = URL(string: urlString) {
                    Link("Get your API key", destination: url)
                }

                SecureField("API Key or Token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                // Service-specific extra fields from adapter config
                ForEach(template.config.setupFields ?? [], id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        if field.isSecure == true {
                            SecureField(field.label, text: extraFieldBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(field.label, text: extraFieldBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                        }
                        if let help = field.helpText {
                            Text(help)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Button("Back") {
                    step = .selectService
                    error = nil
                }

                Spacer()

                Button("Connect") {
                    connectService()
                }
                .disabled(!canConnect)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connectingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(selectedTemplate?.config.displayName ?? "")...")
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Connected!")
                .font(.title2)
                .fontWeight(.bold)

            Text("\(selectedTemplate?.config.displayName ?? "") is now syncing to ~/API2File/\(selectedTemplate?.config.service ?? "")/")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                dismiss()
                // Close the window if presented as NSWindow
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func extraFieldBinding(for key: String) -> Binding<String> {
        Binding(
            get: { extraFieldValues[key] ?? "" },
            set: { extraFieldValues[key] = $0 }
        )
    }

    private var canConnect: Bool {
        guard let template = selectedTemplate else { return false }
        if apiKey.isEmpty { return false }
        for field in template.config.setupFields ?? [] {
            if (extraFieldValues[field.key] ?? "").isEmpty { return false }
        }
        return true
    }

    // MARK: - Actions

    private func connectService() {
        guard let template = selectedTemplate else { return }
        step = .connecting

        Task {
            do {
                // Save API key to Keychain
                let keychain = KeychainManager()
                await keychain.save(key: template.config.auth.keychainKey, value: apiKey)

                // Create service directory with adapter config
                let syncFolder = GlobalConfig().resolvedSyncFolder
                let serviceDir = syncFolder.appendingPathComponent(template.config.service)
                let api2fileDir = serviceDir.appendingPathComponent(".api2file")

                try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

                // Apply extra field substitutions to the adapter config
                var configJSON = template.rawJSON
                for field in template.config.setupFields ?? [] {
                    if let value = extraFieldValues[field.key] {
                        configJSON = configJSON.replacingOccurrences(of: field.templateKey, with: value)
                    }
                }

                let configData = configJSON.data(using: .utf8)!
                try configData.write(to: api2fileDir.appendingPathComponent("adapter.json"), options: .atomic)

                // Init git
                let git = GitManager(repoPath: serviceDir)
                try await git.initRepo()
                try await git.createGitignore()

                let completedServiceId = template.config.service

                await MainActor.run {
                    step = .done
                    onComplete?(completedServiceId)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    step = .enterCredentials
                }
            }
        }
    }
}

// MARK: - Extra Field Definition (kept for compatibility)

struct ExtraField: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let helpText: String?
}
