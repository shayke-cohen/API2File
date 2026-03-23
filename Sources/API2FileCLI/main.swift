import Foundation
import API2FileCore

// MARK: - ANSI Colors

enum Color {
    static let reset   = "\u{001B}[0m"
    static let bold    = "\u{001B}[1m"
    static let dim     = "\u{001B}[2m"
    static let red     = "\u{001B}[31m"
    static let green   = "\u{001B}[32m"
    static let yellow  = "\u{001B}[33m"
    static let blue    = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan    = "\u{001B}[36m"
}

func printError(_ message: String) {
    print("\(Color.red)\(Color.bold)Error:\(Color.reset) \(Color.red)\(message)\(Color.reset)")
}

func printSuccess(_ message: String) {
    print("\(Color.green)\(message)\(Color.reset)")
}

func printWarning(_ message: String) {
    print("\(Color.yellow)\(message)\(Color.reset)")
}

func printHeader(_ message: String) {
    print("\(Color.bold)\(message)\(Color.reset)")
}

// MARK: - Bundled Adapter Configs

enum BundledAdapter: String, CaseIterable {
    case demo
    case monday
    case wix
    case github
    case airtable

    var displayName: String {
        switch self {
        case .demo:     return "Demo Tasks API"
        case .monday:   return "Monday.com"
        case .wix:      return "Wix"
        case .github:   return "GitHub"
        case .airtable: return "Airtable"
        }
    }

    var description: String {
        switch self {
        case .demo:     return "Local demo server — no account needed"
        case .monday:   return "Boards and items as CSV files"
        case .wix:      return "Contacts, products, blog posts, bookings"
        case .github:   return "Repos, issues, gists, notifications"
        case .airtable: return "Records and bases as JSON files"
        }
    }

    var keychainKey: String {
        "api2file.\(rawValue).key"
    }

    var setupInstructions: String {
        switch self {
        case .demo:     return "The demo server runs locally. Enter any value as the API key."
        case .monday:   return "Go to monday.com -> Avatar -> Developers -> My Access Tokens"
        case .wix:      return "Generate an API key at dev.wix.com. After connecting, edit the adapter config to set your wix-site-id."
        case .github:   return "Go to GitHub -> Settings -> Developer Settings -> Personal Access Tokens -> Fine-grained tokens"
        case .airtable: return "Create a Personal Access Token at airtable.com/create/tokens. After connecting, edit the adapter config to set your BASE_ID and TABLE_NAME."
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
            {"service":"github","displayName":"GitHub — Repositories & Issues","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.github.key","setup":{"instructions":"Go to GitHub -> Settings -> Developer Settings -> Personal Access Tokens -> Fine-grained tokens","url":"https://github.com/settings/tokens?type=beta"}},"globals":{"baseUrl":"https://api.github.com","headers":{"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"}},"resources":[{"name":"repos","pull":{"method":"GET","url":"https://api.github.com/user/repos?sort=updated&direction=desc","dataPath":"$","pagination":{"type":"page","pageSize":30}},"fileMapping":{"strategy":"collection","directory":".","filename":"repos.csv","format":"csv","idField":"id","readOnly":true},"sync":{"interval":300}},{"name":"issues","pull":{"method":"GET","url":"https://api.github.com/issues?filter=assigned&state=open&sort=updated","dataPath":"$","pagination":{"type":"page","pageSize":50}},"push":{"update":{"method":"PATCH","url":"https://api.github.com/repos/{repo}/issues/{number}"}},"fileMapping":{"strategy":"collection","directory":".","filename":"issues.csv","format":"csv","idField":"id"},"sync":{"interval":120}},{"name":"notifications","pull":{"method":"GET","url":"https://api.github.com/notifications?all=false","dataPath":"$","pagination":{"type":"page","pageSize":50}},"fileMapping":{"strategy":"collection","directory":".","filename":"notifications.csv","format":"csv","idField":"id","readOnly":true},"sync":{"interval":60}}]}
            """
        case .airtable:
            return """
            {"service":"airtable","displayName":"Airtable — Spreadsheet Database","version":"1.0","auth":{"type":"bearer","keychainKey":"api2file.airtable.key","setup":{"instructions":"Create a Personal Access Token at airtable.com/create/tokens. Then edit adapter.json to set your BASE_ID and TABLE_NAME.","url":"https://airtable.com/create/tokens"}},"globals":{"baseUrl":"https://api.airtable.com/v0","headers":{"Content-Type":"application/json"}},"resources":[{"name":"records","pull":{"method":"GET","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME","dataPath":"$.records","pagination":{"type":"offset","pageSize":100}},"push":{"create":{"method":"POST","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME","bodyWrapper":"fields"},"update":{"method":"PATCH","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME/{id}","bodyWrapper":"fields"},"delete":{"method":"DELETE","url":"https://api.airtable.com/v0/BASE_ID/TABLE_NAME/{id}"}},"fileMapping":{"strategy":"one-per-record","directory":"records","filename":"{id}.json","format":"json","idField":"id"},"sync":{"interval":60}},{"name":"bases","pull":{"method":"GET","url":"https://api.airtable.com/v0/meta/bases","dataPath":"$.bases","pagination":{"type":"offset","pageSize":100}},"fileMapping":{"strategy":"collection","directory":".","filename":"bases.json","format":"json","idField":"id","readOnly":true},"sync":{"interval":600}}]}
            """
        }
    }
}

// MARK: - Helpers

let defaultSyncFolder: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("API2File-Data")
}()

let globalConfigURL: URL = {
    defaultSyncFolder.appendingPathComponent(".api2file.json")
}()

func loadGlobalConfig() -> GlobalConfig {
    return GlobalConfig.loadOrDefault(syncFolder: defaultSyncFolder)
}

/// Discover services by scanning the sync folder for directories with .api2file/adapter.json
func discoverServices(syncFolder: URL) -> [(serviceId: String, dir: URL)] {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(at: syncFolder, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return []
    }

    var services: [(String, URL)] = []
    for item in contents {
        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }

        let adapterPath = item.appendingPathComponent(".api2file/adapter.json")
        if fm.fileExists(atPath: adapterPath.path) {
            services.append((item.lastPathComponent, item))
        }
    }
    return services.sorted { $0.0 < $1.0 }
}

func formatDate(_ date: Date?) -> String {
    guard let date = date else { return "never" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Commands

func commandHelp() {
    print("")
    printHeader("  API2File — Cloud APIs as local files")
    print("")
    print("  \(Color.bold)USAGE:\(Color.reset) api2file <command> [arguments]")
    print("")
    print("  \(Color.bold)COMMANDS:\(Color.reset)")
    print("    \(Color.cyan)status\(Color.reset)            Show all services and their sync status")
    print("    \(Color.cyan)sync\(Color.reset) [service]    Trigger immediate sync (all or specific service)")
    print("    \(Color.cyan)pull\(Color.reset) [service]    Pull from API to local files")
    print("    \(Color.cyan)add\(Color.reset) <service>     Set up a new service (demo/monday/wix/github/airtable)")
    print("    \(Color.cyan)list\(Color.reset)              List available bundled adapters")
    print("    \(Color.cyan)init\(Color.reset)              Initialize ~/API2File-Data/ with global config")
    print("    \(Color.cyan)help\(Color.reset)              Show this help message")
    print("")
    print("  \(Color.bold)EXAMPLES:\(Color.reset)")
    print("    api2file init                 Set up the data directory")
    print("    api2file add demo             Add the demo service")
    print("    api2file add github           Add GitHub integration")
    print("    api2file status               Show status of all services")
    print("    api2file sync                 Sync all services now")
    print("    api2file sync github          Sync only GitHub")
    print("    api2file pull monday          Pull Monday.com data")
    print("")
}

func commandInit() {
    let fm = FileManager.default
    let syncFolder = defaultSyncFolder

    // Create directory
    do {
        try fm.createDirectory(at: syncFolder, withIntermediateDirectories: true)
    } catch {
        printError("Failed to create directory \(syncFolder.path): \(error.localizedDescription)")
        exit(1)
    }

    // Write default config if it doesn't exist
    if fm.fileExists(atPath: globalConfigURL.path) {
        printWarning("Global config already exists at \(globalConfigURL.path)")
        printSuccess("API2File data directory is ready at \(syncFolder.path)")
    } else {
        let config = GlobalConfig()
        do {
            try config.save(to: globalConfigURL)
            printSuccess("Initialized API2File data directory at \(syncFolder.path)")
            print("  Config: \(Color.dim)\(globalConfigURL.path)\(Color.reset)")
            print("")
            print("  \(Color.dim)Defaults:\(Color.reset)")
            print("    Sync interval:  \(config.defaultSyncInterval)s")
            print("    Git auto-commit: \(config.gitAutoCommit)")
            print("    Server port:    \(config.serverPort)")
            print("")
            print("  Next: run \(Color.cyan)api2file add <service>\(Color.reset) to connect a cloud service")
        } catch {
            printError("Failed to write config: \(error.localizedDescription)")
            exit(1)
        }
    }
}

func commandList() {
    print("")
    printHeader("  Available Services")
    print("")

    let maxNameLen = BundledAdapter.allCases.map { $0.displayName.count }.max() ?? 0

    for adapter in BundledAdapter.allCases {
        let padding = String(repeating: " ", count: maxNameLen - adapter.displayName.count + 2)
        print("    \(Color.cyan)\(adapter.rawValue)\(Color.reset)  \(Color.bold)\(adapter.displayName)\(Color.reset)\(padding)\(Color.dim)\(adapter.description)\(Color.reset)")
    }

    print("")
    print("  Add a service: \(Color.cyan)api2file add <service>\(Color.reset)")
    print("")
}

func commandStatus() {
    let config = loadGlobalConfig()
    let syncFolder = config.resolvedSyncFolder
    let fm = FileManager.default

    if !fm.fileExists(atPath: syncFolder.path) {
        printWarning("API2File data directory not found.")
        print("  Run \(Color.cyan)api2file init\(Color.reset) to set up.")
        exit(0)
    }

    let services = discoverServices(syncFolder: syncFolder)

    print("")
    printHeader("  API2File Status")
    print("  \(Color.dim)\(syncFolder.path)\(Color.reset)")
    print("")

    if services.isEmpty {
        printWarning("  No services configured.")
        print("  Run \(Color.cyan)api2file add <service>\(Color.reset) to connect a service.")
        print("")
        return
    }

    for (serviceId, serviceDir) in services {
        // Load adapter config
        let adapterPath = serviceDir.appendingPathComponent(".api2file/adapter.json")
        guard let data = try? Data(contentsOf: adapterPath),
              let adapterConfig = try? JSONDecoder().decode(AdapterConfig.self, from: data) else {
            print("  \(Color.red)\u{25CF}\(Color.reset) \(Color.bold)\(serviceId)\(Color.reset)  \(Color.red)config error\(Color.reset)")
            continue
        }

        // Load sync state
        let statePath = serviceDir.appendingPathComponent(".api2file/state.json")
        let state = try? SyncState.load(from: statePath)
        let fileCount = state?.files.count ?? 0

        // Count actual files on disk (excluding hidden dirs)
        var diskFileCount = 0
        if let enumerator = fm.enumerator(at: serviceDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile { diskFileCount += 1 }
            }
        }

        // Determine last sync time from state
        var lastSync: Date? = nil
        if let state = state {
            for (_, fileState) in state.files {
                if lastSync == nil || fileState.lastSyncTime > lastSync! {
                    lastSync = fileState.lastSyncTime
                }
            }
        }

        // Check if keychain has a key
        let hasKey = true // We can't easily check async from sync context, assume configured

        let statusIcon: String
        let statusText: String
        if fileCount > 0 || diskFileCount > 0 {
            statusIcon = "\(Color.green)\u{25CF}\(Color.reset)"
            statusText = "\(Color.green)connected\(Color.reset)"
        } else {
            statusIcon = "\(Color.yellow)\u{25CF}\(Color.reset)"
            statusText = "\(Color.yellow)no data yet\(Color.reset)"
        }

        let resourceCount = adapterConfig.resources.count
        let syncInterval = adapterConfig.resources.first?.sync?.interval ?? 60
        let lastSyncStr = formatDate(lastSync)

        print("  \(statusIcon) \(Color.bold)\(adapterConfig.displayName)\(Color.reset) (\(serviceId))")
        print("    Resources:  \(resourceCount)    Files: \(diskFileCount)    Interval: \(syncInterval)s")
        print("    Last sync:  \(lastSyncStr)    Status: \(statusText)")
        print("")
    }
}

func commandAdd(serviceName: String) {
    guard let adapter = BundledAdapter(rawValue: serviceName.lowercased()) else {
        printError("Unknown service: '\(serviceName)'")
        print("  Available services: \(BundledAdapter.allCases.map { $0.rawValue }.joined(separator: ", "))")
        print("  Run \(Color.cyan)api2file list\(Color.reset) for details.")
        exit(1)
    }

    let config = loadGlobalConfig()
    let syncFolder = config.resolvedSyncFolder
    let fm = FileManager.default
    let serviceDir = syncFolder.appendingPathComponent(adapter.rawValue)
    let api2fileDir = serviceDir.appendingPathComponent(".api2file")
    let adapterConfigPath = api2fileDir.appendingPathComponent("adapter.json")

    // Check if already exists
    if fm.fileExists(atPath: adapterConfigPath.path) {
        printWarning("\(adapter.displayName) is already configured at \(serviceDir.path)")
        print("  To reconfigure, delete \(api2fileDir.path) and try again.")
        exit(0)
    }

    // Create directories
    do {
        try fm.createDirectory(at: api2fileDir, withIntermediateDirectories: true)
    } catch {
        printError("Failed to create directory: \(error.localizedDescription)")
        exit(1)
    }

    // Prompt for API key
    print("")
    printHeader("  Add \(adapter.displayName)")
    print("")
    print("  \(Color.dim)\(adapter.setupInstructions)\(Color.reset)")
    print("")
    print("  \(Color.bold)Enter API key/token:\(Color.reset) ", terminator: "")
    fflush(stdout)

    guard let apiKey = readLine(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        printError("No API key provided. Aborting.")
        // Clean up
        try? fm.removeItem(at: api2fileDir)
        exit(1)
    }

    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

    // Write adapter config
    do {
        guard let configData = adapter.adapterConfigJSON.data(using: .utf8) else {
            printError("Failed to encode adapter config.")
            exit(1)
        }

        // Pretty-print the JSON
        let jsonObj = try JSONSerialization.jsonObject(with: configData)
        let prettyData = try JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys])
        try prettyData.write(to: adapterConfigPath, options: .atomic)
    } catch {
        printError("Failed to write adapter config: \(error.localizedDescription)")
        exit(1)
    }

    // Save API key to Keychain (async operation)
    let semaphore = DispatchSemaphore(value: 0)
    var keychainSuccess = false

    Task {
        let keychain = KeychainManager()
        keychainSuccess = await keychain.save(key: adapter.keychainKey, value: trimmedKey)
        semaphore.signal()
    }
    semaphore.wait()

    if !keychainSuccess {
        printWarning("Failed to save API key to Keychain. You may need to add it manually.")
    }

    // Init git repo
    let gitSemaphore = DispatchSemaphore(value: 0)
    var gitError: String? = nil

    Task {
        do {
            let git = GitManager(repoPath: serviceDir)
            try await git.initRepo()
            try await git.createGitignore()
        } catch {
            gitError = error.localizedDescription
        }
        gitSemaphore.signal()
    }
    gitSemaphore.wait()

    if let gitErr = gitError {
        printWarning("Git init: \(gitErr)")
    }

    print("")
    printSuccess("  \u{2713} \(adapter.displayName) configured successfully!")
    print("")
    print("  Service directory: \(Color.dim)\(serviceDir.path)\(Color.reset)")
    print("  Adapter config:   \(Color.dim)\(adapterConfigPath.path)\(Color.reset)")
    if keychainSuccess {
        print("  API key:           \(Color.dim)saved to Keychain (\(adapter.keychainKey))\(Color.reset)")
    }
    print("")
    print("  Next steps:")
    print("    \(Color.cyan)api2file sync \(adapter.rawValue)\(Color.reset)   — Pull data from \(adapter.displayName)")
    print("    \(Color.cyan)api2file status\(Color.reset)              — Check sync status")
    print("")
}

func commandSync(serviceName: String?) {
    let config = loadGlobalConfig()
    let syncFolder = config.resolvedSyncFolder
    let fm = FileManager.default

    if !fm.fileExists(atPath: syncFolder.path) {
        printError("API2File data directory not found. Run \(Color.cyan)api2file init\(Color.reset) first.")
        exit(1)
    }

    let services = discoverServices(syncFolder: syncFolder)

    if services.isEmpty {
        printWarning("No services configured. Run \(Color.cyan)api2file add <service>\(Color.reset) first.")
        exit(0)
    }

    // Filter to specific service if requested
    let targetServices: [(String, URL)]
    if let name = serviceName {
        targetServices = services.filter { $0.0 == name.lowercased() }
        if targetServices.isEmpty {
            printError("Service '\(name)' not found.")
            print("  Configured services: \(services.map { $0.0 }.joined(separator: ", "))")
            exit(1)
        }
    } else {
        targetServices = services
    }

    print("")
    printHeader("  Syncing \(targetServices.count) service(s)...")
    print("")

    let semaphore = DispatchSemaphore(value: 0)

    Task {
        let engine = SyncEngine(config: config)

        do {
            try await engine.start()

            // Trigger explicit sync for each target service
            for (serviceId, _) in targetServices {
                print("  \(Color.cyan)\u{2192}\(Color.reset) Syncing \(serviceId)...")
                await engine.triggerSync(serviceId: serviceId)
            }

            // Give time for async operations to complete
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // Print results
            let allServices = await engine.getServices()
            for (serviceId, _) in targetServices {
                if let info = allServices.first(where: { $0.serviceId == serviceId }) {
                    switch info.status {
                    case .connected:
                        printSuccess("  \u{2713} \(info.displayName) — \(info.fileCount) files synced")
                    case .syncing:
                        print("  \(Color.yellow)\u{25CB}\(Color.reset) \(info.displayName) — still syncing...")
                    case .error:
                        printError("  \u{2717} \(info.displayName) — \(info.errorMessage ?? "unknown error")")
                    default:
                        print("  \(Color.dim)\u{25CB}\(Color.reset) \(info.displayName) — \(info.status.rawValue)")
                    }
                }
            }

            await engine.stop()
        } catch {
            printError("Sync failed: \(error.localizedDescription)")
        }

        print("")
        semaphore.signal()
    }

    semaphore.wait()
}

func commandPull(serviceName: String?) {
    let config = loadGlobalConfig()
    let syncFolder = config.resolvedSyncFolder
    let fm = FileManager.default

    if !fm.fileExists(atPath: syncFolder.path) {
        printError("API2File data directory not found. Run \(Color.cyan)api2file init\(Color.reset) first.")
        exit(1)
    }

    let services = discoverServices(syncFolder: syncFolder)

    if services.isEmpty {
        printWarning("No services configured. Run \(Color.cyan)api2file add <service>\(Color.reset) first.")
        exit(0)
    }

    // Filter to specific service if requested
    let targetServices: [(String, URL)]
    if let name = serviceName {
        targetServices = services.filter { $0.0 == name.lowercased() }
        if targetServices.isEmpty {
            printError("Service '\(name)' not found.")
            print("  Configured services: \(services.map { $0.0 }.joined(separator: ", "))")
            exit(1)
        }
    } else {
        targetServices = services
    }

    print("")
    printHeader("  Pulling \(targetServices.count) service(s)...")
    print("")

    let semaphore = DispatchSemaphore(value: 0)

    Task {
        for (serviceId, serviceDir) in targetServices {
            print("  \(Color.cyan)\u{2192}\(Color.reset) Pulling \(serviceId)...")

            do {
                let adapterConfig = try AdapterEngine.loadConfig(from: serviceDir)
                let httpClient = HTTPClient()

                // Load auth token from Keychain
                let keychain = KeychainManager()
                if let token = await keychain.load(key: adapterConfig.auth.keychainKey) {
                    switch adapterConfig.auth.type {
                    case .bearer:
                        await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
                    case .apiKey:
                        await httpClient.setAuthHeader("Authorization", value: token)
                    case .basic:
                        await httpClient.setAuthHeader("Authorization", value: "Basic \(token)")
                    case .oauth2:
                        await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
                    }
                } else {
                    printWarning("  No API key found for \(serviceId). Set one with: api2file add \(serviceId)")
                }

                let engine = AdapterEngine(config: adapterConfig, serviceDir: serviceDir, httpClient: httpClient)
                let files = try await engine.pullAll()

                // Write files to disk
                for file in files {
                    let filePath = serviceDir.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.content.write(to: filePath, options: .atomic)
                }

                printSuccess("  \u{2713} \(adapterConfig.displayName) — pulled \(files.count) file(s)")

            } catch {
                printError("  \u{2717} \(serviceId) — \(error.localizedDescription)")
            }
        }
        print("")
        semaphore.signal()
    }

    semaphore.wait()
}

// MARK: - Main Entry Point

let args = CommandLine.arguments
let command = args.count > 1 ? args[1].lowercased() : "help"

switch command {
case "help", "--help", "-h":
    commandHelp()

case "init":
    commandInit()

case "list", "ls":
    commandList()

case "status", "st":
    commandStatus()

case "add":
    guard args.count > 2 else {
        printError("Missing service name.")
        print("  Usage: \(Color.cyan)api2file add <service>\(Color.reset)")
        print("  Run \(Color.cyan)api2file list\(Color.reset) to see available services.")
        exit(1)
    }
    commandAdd(serviceName: args[2])

case "sync":
    let service = args.count > 2 ? args[2] : nil
    commandSync(serviceName: service)

case "pull":
    let service = args.count > 2 ? args[2] : nil
    commandPull(serviceName: service)

default:
    printError("Unknown command: '\(command)'")
    commandHelp()
    exit(1)
}
