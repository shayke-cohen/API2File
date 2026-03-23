import SwiftUI
import API2FileCore

struct AddServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedService: BundledService?
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
    }

    private var dynamicHeight: CGFloat {
        if step == .enterCredentials, let service = selectedService, !service.extraFields.isEmpty {
            return 300 + CGFloat(service.extraFields.count) * 60
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

            ForEach(BundledService.allCases, id: \.self) { service in
                Button {
                    selectedService = service
                    extraFieldValues = [:]
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

                // Service-specific extra fields
                ForEach(service.extraFields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        if field.isSecure {
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
        guard let service = selectedService else { return false }
        if apiKey.isEmpty { return false }
        for field in service.extraFields {
            if (extraFieldValues[field.key] ?? "").isEmpty { return false }
        }
        return true
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

                // Apply extra field substitutions to the adapter config
                var configJSON = service.adapterConfigJSON
                for (key, value) in extraFieldValues {
                    switch key {
                    case "wix-site-id":
                        configJSON = configJSON.replacingOccurrences(of: "YOUR_SITE_ID_HERE", with: value)
                    case "base-id":
                        configJSON = configJSON.replacingOccurrences(of: "BASE_ID", with: value)
                    case "table-name":
                        configJSON = configJSON.replacingOccurrences(of: "TABLE_NAME", with: value)
                    default:
                        break
                    }
                }

                let configData = configJSON.data(using: .utf8)!
                try configData.write(to: api2fileDir.appendingPathComponent("adapter.json"), options: .atomic)

                // Init git
                let git = GitManager(repoPath: serviceDir)
                try await git.initRepo()
                try await git.createGitignore()

                let completedServiceId = service.serviceId

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

// MARK: - Extra Field Definition

struct ExtraField: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let helpText: String?
}

// MARK: - Bundled Services

enum BundledService: String, CaseIterable {
    case demo
    case monday
    case wix
    case github
    case airtable

    var displayName: String {
        switch self {
        case .demo: return "Demo Tasks API"
        case .monday: return "Monday.com"
        case .wix: return "Wix"
        case .github: return "GitHub"
        case .airtable: return "Airtable"
        }
    }

    var serviceId: String { rawValue }

    var icon: String {
        switch self {
        case .demo: return "laptopcomputer"
        case .monday: return "calendar.badge.checkmark"
        case .wix: return "globe"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .airtable: return "tablecells"
        }
    }

    var description: String {
        switch self {
        case .demo: return "Local demo server — no account needed"
        case .monday: return "Boards and items as CSV files"
        case .wix: return "Contacts, products, blog posts, bookings"
        case .github: return "Repos, issues, gists, notifications"
        case .airtable: return "Records and bases as JSON files"
        }
    }

    var setupInstructions: String {
        switch self {
        case .demo: return "The demo server runs locally. Enter any value as the API key."
        case .monday: return "Go to monday.com → Avatar → Developers → My Access Tokens"
        case .wix: return "Generate an API key at dev.wix.com, then enter your Site ID below."
        case .github: return "Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens"
        case .airtable: return "Create a Personal Access Token at airtable.com/create/tokens, then enter your Base ID and Table Name below."
        }
    }

    var setupURL: URL? {
        switch self {
        case .demo: return nil
        case .monday: return URL(string: "https://monday.com/apps/manage")
        case .wix: return URL(string: "https://dev.wix.com/apps")
        case .github: return URL(string: "https://github.com/settings/tokens?type=beta")
        case .airtable: return URL(string: "https://airtable.com/create/tokens")
        }
    }

    var keychainKey: String {
        "api2file.\(serviceId).key"
    }

    var extraFields: [ExtraField] {
        switch self {
        case .wix:
            return [
                ExtraField(
                    key: "wix-site-id",
                    label: "Site ID",
                    placeholder: "abc123-def456-...",
                    isSecure: false,
                    helpText: "Find in your Wix dashboard URL after /dashboard/"
                )
            ]
        case .airtable:
            return [
                ExtraField(
                    key: "base-id",
                    label: "Base ID",
                    placeholder: "appXXXXXXXXXX",
                    isSecure: false,
                    helpText: "Find in the Airtable URL: airtable.com/appXXX/..."
                ),
                ExtraField(
                    key: "table-name",
                    label: "Table Name",
                    placeholder: "My Table",
                    isSecure: false,
                    helpText: "The name of the table you want to sync"
                )
            ]
        default:
            return []
        }
    }

    var adapterConfigJSON: String {
        switch self {
        case .demo:
            return """
            {"service":"demo","displayName":"Demo Tasks API","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.demo.key","setup":{"instructions":"No auth needed"}},"globals":{"baseUrl":"http://localhost:8089"},"resources":[{"name":"tasks","pull":{"method":"GET","url":"http://localhost:8089/api/tasks","dataPath":"$"},"push":{"create":{"method":"POST","url":"http://localhost:8089/api/tasks"},"update":{"method":"PUT","url":"http://localhost:8089/api/tasks/{id}"},"delete":{"method":"DELETE","url":"http://localhost:8089/api/tasks/{id}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"tasks.csv","format":"csv","idField":"id"},"sync":{"interval":10}}]}
            """
        case .monday:
            return """
            {"service":"monday","displayName":"Monday.com","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.monday.key"},"globals":{"baseUrl":"https://api.monday.com/v2","method":"POST"},"resources":[{"name":"boards","pull":{"url":"https://api.monday.com/v2","type":"graphql","query":"{ boards { id name } }","dataPath":"$.data.boards"},"fileMapping":{"strategy":"collection","directory":"boards","filename":"{name|slugify}.csv","format":"csv","idField":"id"},"sync":{"interval":60}}]}
            """
        case .wix:
            return """
            {"service":"wix","displayName":"Wix — Website & Business Platform","version":"1.0","auth":{"type":"apiKey","keychainKey":"api2file.wix.key","setup":{"instructions":"Generate an API key at dev.wix.com. Then edit adapter.json to set your wix-site-id.","url":"https://dev.wix.com/apps"}},"globals":{"baseUrl":"https://www.wixapis.com","headers":{"Content-Type":"application/json","wix-site-id":"YOUR_SITE_ID_HERE"}},"resources":[{"name":"contacts","pull":{"method":"POST","url":"https://www.wixapis.com/contacts/v4/contacts/query","body":{"query":{"paging":{"limit":100}}},"dataPath":"$.contacts"},"push":{"create":{"method":"POST","url":"https://www.wixapis.com/contacts/v4/contacts","bodyWrapper":"info"},"update":{"method":"PATCH","url":"https://www.wixapis.com/contacts/v4/contacts/{id}","bodyWrapper":"info"},"delete":{"method":"DELETE","url":"https://www.wixapis.com/contacts/v4/contacts/{id}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"contacts.csv","format":"csv","idField":"id"},"sync":{"interval":120}},{"name":"products","pull":{"method":"POST","url":"https://www.wixapis.com/stores/v1/products/query","body":{"query":{"paging":{"limit":100}}},"dataPath":"$.products"},"push":{"create":{"method":"POST","url":"https://www.wixapis.com/stores/v1/products","bodyWrapper":"product"},"update":{"method":"PATCH","url":"https://www.wixapis.com/stores/v1/products/{id}","bodyWrapper":"product"},"delete":{"method":"DELETE","url":"https://www.wixapis.com/stores/v1/products/{id}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"products.csv","format":"csv","idField":"id"},"sync":{"interval":120}},{"name":"blog-posts","pull":{"method":"POST","url":"https://www.wixapis.com/blog/v3/posts/query","body":{"query":{"paging":{"limit":50}}},"dataPath":"$.posts"},"fileMapping":{"strategy":"one-per-record","directory":"blog","filename":"{slug|slugify}.md","format":"md","idField":"id","contentField":"richContent"},"sync":{"interval":120}}]}
            """
        case .github:
            return """
            {"service":"github","displayName":"GitHub — Repositories & Issues","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.github.key","setup":{"instructions":"Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens","url":"https://github.com/settings/tokens?type=beta"}},"globals":{"baseUrl":"https://api.github.com","headers":{"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"}},"resources":[{"name":"repos","pull":{"method":"GET","url":"https://api.github.com/user/repos?sort=updated&direction=desc","dataPath":"$","pagination":{"type":"page","pageSize":30}},"fileMapping":{"strategy":"collection","directory":".","filename":"repos.csv","format":"csv","idField":"id","readOnly":true},"sync":{"interval":300}},{"name":"issues","pull":{"method":"GET","url":"https://api.github.com/issues?filter=assigned&state=open&sort=updated","dataPath":"$","pagination":{"type":"page","pageSize":50}},"push":{"update":{"method":"PATCH","url":"https://api.github.com/repos/{repo}/issues/{number}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"issues.csv","format":"csv","idField":"id"},"sync":{"interval":120}},{"name":"notifications","pull":{"method":"GET","url":"https://api.github.com/notifications?all=false","dataPath":"$","pagination":{"type":"page","pageSize":50}},"fileMapping":{"strategy":"collection","directory":".","filename":"notifications.csv","format":"csv","idField":"id","readOnly":true},"sync":{"interval":60}}]}
            """
        case .airtable:
            return """
            {"service":"airtable","displayName":"Airtable — Spreadsheet Database","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.airtable.key","setup":{"instructions":"Create a Personal Access Token at airtable.com/create/tokens. Then edit adapter.json to set your BASE_ID and TABLE_NAME.","url":"https://airtable.com/create/tokens"}},"globals":{"baseUrl":"https://api.airtable.com/v0","headers":{"Content-Type":"application/json"}},"resources":[{"name":"records","pull":{"method":"GET","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME","dataPath":"$.records","pagination":{"type":"offset","pageSize":100}},"push":{"create":{"method":"POST","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME","bodyWrapper":"fields"},"update":{"method":"PATCH","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME/{id}","bodyWrapper":"fields"},"delete":{"method":"DELETE","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME/{id}"}},"fileMapping":{"strategy":"one-per-record","directory":"records","filename":"{id}.json","format":"json","idField":"id"},"sync":{"interval":60}},{"name":"bases","pull":{"method":"GET","url":"https://api.airtable.com/v0/meta/bases","dataPath":"$.bases","pagination":{"type":"offset","pageSize":100}},"fileMapping":{"strategy":"collection","directory":".","filename":"bases.json","format":"json","idField":"id","readOnly":true},"sync":{"interval":600}}]}
            """
        }
    }
}
