import SwiftUI
import API2FileCore

struct AddServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [AdapterTemplate] = []
    @State private var selectedTemplate: AdapterTemplate?
    @State private var serviceID: String = ""
    @State private var apiKey: String = ""
    @State private var storageMode: ServiceStorageMode = .plainSync
    @State private var extraFieldValues: [String: String] = [:]
    @State private var isConnecting = false
    @State private var error: String?
    @State private var step: SetupStep = .selectService
    @State private var completedServiceID: String?

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
            return 360 + CGFloat((template.config.setupFields ?? []).count) * 60
        }
        return step == .enterCredentials ? 360 : 300
    }

    // MARK: - Steps

    private var selectServiceStep: some View {
        VStack(spacing: 16) {
            Text("Add Service")
                .font(.title2)
                .fontWeight(.bold)
                .testId("wizard-title")

            Text("Choose a cloud service to sync:")
                .foregroundStyle(.secondary)

            if templates.isEmpty {
                ProgressView()
                    .padding()
                    .testId("wizard-loading")
            } else {
                ForEach(templates, id: \.config.service) { template in
                    Button {
                        selectedTemplate = template
                        serviceID = template.config.service
                        storageMode = template.config.storageMode ?? .plainSync
                        extraFieldValues = [:]
                        apiKey = ""
                        completedServiceID = nil
                        error = nil
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
                    .testId("wizard-service-\(template.config.service)")
                }
            }

            Spacer()
        }
        .testId("wizard-step-select")
    }

    private var enterCredentialsStep: some View {
        VStack(spacing: 16) {
            Text("Connect \(selectedTemplate?.config.displayName ?? "")")
                .font(.title2)
                .fontWeight(.bold)
                .testId("wizard-credentials-title")

            if let template = selectedTemplate {
                Text(template.config.auth.setup?.instructions ?? "")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let urlString = template.config.auth.setup?.url, let url = URL(string: urlString) {
                    Link("Get your API key", destination: url)
                        .testId("wizard-api-key-link")
                }

                SecureField("API Key or Token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .testId("wizard-api-key-field")

                TextField("Workspace Folder", text: $serviceID)
                    .textFieldStyle(.roundedBorder)
                    .testId("wizard-service-id-field")

                Text("Creates a separate folder under the sync root. Use a unique name for a second Wix site.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Picker("Storage Mode", selection: $storageMode) {
                    Text("Plain Sync").tag(ServiceStorageMode.plainSync)
                    Text("Managed Workspace").tag(ServiceStorageMode.managedWorkspace)
                }
                .pickerStyle(.segmented)
                .testId("wizard-storage-mode")

                Text(storageMode == .managedWorkspace
                     ? "Managed services surface accepted files in the API2File workspace and route edits through validation."
                     : "Plain sync services mirror files directly into the regular sync root and watch them for edits.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // Service-specific extra fields from adapter config
                ForEach(template.config.setupFields ?? [], id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        if field.isSecure == true {
                            SecureField(field.label, text: extraFieldBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                                .testId("wizard-field-\(field.key)")
                        } else {
                            TextField(field.label, text: extraFieldBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                                .testId("wizard-field-\(field.key)")
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
                        .testId("wizard-error-message")
                }
            }

            HStack {
                Button("Back") {
                    step = .selectService
                    error = nil
                }
                .testId("wizard-back")

                Spacer()

                Button("Connect") {
                    connectService()
                }
                .disabled(!canConnect)
                .keyboardShortcut(.defaultAction)
                .testId("wizard-connect")
            }
        }
        .testId("wizard-step-credentials")
    }

    private var connectingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .testId("wizard-connecting-spinner")
            Text("Connecting to \(selectedTemplate?.config.displayName ?? "")...")
                .testId("wizard-connecting-label")
        }
        .testId("wizard-step-connecting")
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .testId("wizard-done-icon")

            Text("Connected!")
                .font(.title2)
                .fontWeight(.bold)
                .testId("wizard-done-title")

            Text(doneStepMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                dismiss()
                // Close the window if presented as NSWindow
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
            .testId("wizard-done-button")
        }
        .testId("wizard-step-done")
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
        if serviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        for field in template.config.setupFields ?? [] {
            if (extraFieldValues[field.key] ?? "").isEmpty { return false }
        }
        return true
    }

    private var doneStepMessage: String {
        let displayName = selectedTemplate?.config.displayName ?? ""
        let serviceName = completedServiceID ?? selectedTemplate?.config.service ?? ""
        switch storageMode {
        case .plainSync:
            return "\(displayName) is now syncing to ~/API2File/\(serviceName)/"
        case .managedWorkspace:
            return "\(displayName) now keeps accepted state under ~/API2File/\(serviceName)/ and surfaces editable files in ~/API2File-Workspace/\(serviceName)/"
        }
    }

    // MARK: - Actions

    private func connectService() {
        guard let template = selectedTemplate else { return }
        step = .connecting

        Task {
            do {
                let normalizedServiceID = ServiceIdentity.normalizedServiceID(from: serviceID)
                guard !normalizedServiceID.isEmpty else {
                    throw NSError(
                        domain: "API2FileApp",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Enter a valid workspace folder name."]
                    )
                }

                // Create service directory with adapter config
                let syncFolder = GlobalConfig().resolvedSyncFolder
                let serviceDir = syncFolder.appendingPathComponent(normalizedServiceID)
                let api2fileDir = serviceDir.appendingPathComponent(".api2file")
                let adapterURL = api2fileDir.appendingPathComponent("adapter.json")

                if FileManager.default.fileExists(atPath: adapterURL.path) {
                    throw NSError(
                        domain: "API2FileApp",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "A workspace folder named '\(normalizedServiceID)' already exists."]
                    )
                }

                // Save API key to Keychain
                let keychain = KeychainManager()
                let keychainKey = ServiceIdentity.keychainKey(
                    for: normalizedServiceID,
                    adapterService: template.config.service,
                    templateKeychainKey: template.config.auth.keychainKey
                )
                await keychain.save(key: keychainKey, value: apiKey)

                try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

                let configJSON = try ServiceIdentity.installedAdapterJSON(
                    template: template,
                    serviceID: normalizedServiceID,
                    extraFieldValues: extraFieldValues,
                    customizeConfig: { json in
                        json["storageMode"] = storageMode.rawValue
                    }
                )
                let configData = configJSON.data(using: .utf8)!
                try configData.write(to: adapterURL, options: .atomic)

                // Init git
                let git = GitManager(repoPath: serviceDir)
                try await git.initRepo()
                try await git.createGitignore()

                await MainActor.run {
                    completedServiceID = normalizedServiceID
                    step = .done
                    onComplete?(normalizedServiceID)
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
