import SwiftUI
import API2FileCore

struct AddServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedService: BundledService?
    @State private var apiKey: String = ""
    @State private var isConnecting = false
    @State private var error: String?
    @State private var step: SetupStep = .selectService

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
        .frame(width: 400, height: 300)
        .padding()
    }

    // MARK: - Steps

    private var selectServiceStep: some View {
        VStack(spacing: 16) {
            Text("Add Service")
                .font(.title2)
                .fontWeight(.bold)

            Text("Choose a cloud service to sync:")
                .foregroundStyle(.secondary)

            ForEach(BundledService.allCases, id: \.self) { service in
                Button {
                    selectedService = service
                    step = .enterCredentials
                } label: {
                    HStack {
                        Image(systemName: service.icon)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(service.displayName)
                                .fontWeight(.medium)
                            Text(service.description)
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

            Spacer()
        }
    }

    private var enterCredentialsStep: some View {
        VStack(spacing: 16) {
            Text("Connect \(selectedService?.displayName ?? "")")
                .font(.title2)
                .fontWeight(.bold)

            if let service = selectedService {
                Text(service.setupInstructions)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let url = service.setupURL {
                    Link("Get your API key", destination: url)
                }

                SecureField("API Key or Token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

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
                .disabled(apiKey.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connectingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(selectedService?.displayName ?? "")...")
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

            Text("\(selectedService?.displayName ?? "") is now syncing to ~/API2File/\(selectedService?.serviceId ?? "")/")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func connectService() {
        guard let service = selectedService else { return }
        step = .connecting

        Task {
            do {
                // Save API key to Keychain
                let keychain = KeychainManager()
                await keychain.save(key: service.keychainKey, value: apiKey)

                // Create service directory with adapter config
                let syncFolder = GlobalConfig().resolvedSyncFolder
                let serviceDir = syncFolder.appendingPathComponent(service.serviceId)
                let api2fileDir = serviceDir.appendingPathComponent(".api2file")

                try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

                // Copy bundled adapter config
                let configData = service.adapterConfigJSON.data(using: .utf8)!
                try configData.write(to: api2fileDir.appendingPathComponent("adapter.json"), options: .atomic)

                // Init git
                let git = GitManager(repoPath: serviceDir)
                try await git.initRepo()
                try await git.createGitignore()

                await MainActor.run {
                    step = .done
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

// MARK: - Bundled Services

enum BundledService: String, CaseIterable {
    case demo
    case monday
    case wix
    case netlify

    var displayName: String {
        switch self {
        case .demo: return "Demo Tasks API"
        case .monday: return "Monday.com"
        case .wix: return "Wix"
        case .netlify: return "Netlify"
        }
    }

    var serviceId: String { rawValue }

    var icon: String {
        switch self {
        case .demo: return "laptopcomputer"
        case .monday: return "calendar.badge.checkmark"
        case .wix: return "globe"
        case .netlify: return "network"
        }
    }

    var description: String {
        switch self {
        case .demo: return "Local demo server — no account needed"
        case .monday: return "Boards and items as CSV files"
        case .wix: return "Products, pages, orders"
        case .netlify: return "Site files — edit locally, auto-deploy"
        }
    }

    var setupInstructions: String {
        switch self {
        case .demo: return "The demo server runs locally. Enter any value as the API key."
        case .monday: return "Go to monday.com → Avatar → Developers → My Access Tokens"
        case .wix: return "Create an app at dev.wix.com and generate an API key"
        case .netlify: return "Go to User Settings → Applications → Personal Access Tokens"
        }
    }

    var setupURL: URL? {
        switch self {
        case .demo: return nil
        case .monday: return URL(string: "https://monday.com/apps/manage")
        case .wix: return URL(string: "https://dev.wix.com/apps")
        case .netlify: return URL(string: "https://app.netlify.com/user/applications")
        }
    }

    var keychainKey: String {
        "api2file.\(serviceId).key"
    }

    var adapterConfigJSON: String {
        // In a real app, these would be loaded from bundled .adapter.json files
        switch self {
        case .demo:
            return """
            {"service":"demo","displayName":"Demo Tasks API","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.demo.key","setup":{"instructions":"No auth needed"}},"globals":{"baseUrl":"http://localhost:8089"},"resources":[{"name":"tasks","pull":{"method":"GET","url":"http://localhost:8089/api/tasks","dataPath":"$"},"push":{"create":{"method":"POST","url":"http://localhost:8089/api/tasks"},"update":{"method":"PUT","url":"http://localhost:8089/api/tasks/{id}"},"delete":{"method":"DELETE","url":"http://localhost:8089/api/tasks/{id}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"tasks.csv","format":"csv","idField":"id"},"sync":{"interval":10}}]}
            """
        case .monday:
            return """
            {"service":"monday","displayName":"Monday.com","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.monday.key"},"globals":{"baseUrl":"https://api.monday.com/v2","method":"POST"},"resources":[{"name":"boards","pull":{"url":"https://api.monday.com/v2","type":"graphql","query":"{ boards { id name } }","dataPath":"$.data.boards"},"fileMapping":{"strategy":"collection","directory":"boards","filename":"{name|slugify}.csv","format":"csv","idField":"id"},"sync":{"interval":60}}]}
            """
        case .wix, .netlify:
            return """
            {"service":"\(serviceId)","displayName":"\(displayName)","version":"1.0","auth":{"type":"bearer","keychainKey":"\(keychainKey)"},"globals":{"baseUrl":"https://api.example.com"},"resources":[]}
            """
        }
    }
}
