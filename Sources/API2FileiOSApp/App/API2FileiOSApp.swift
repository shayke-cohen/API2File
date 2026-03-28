import SwiftUI
import BackgroundTasks

@main
struct API2FileiOSApp: App {
    @UIApplicationDelegateAdaptor(API2FileIOSAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = IOSAppState()

    init() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithDefaultBackground()
        navAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        navAppearance.backgroundColor = UIColor.systemGroupedBackground.withAlphaComponent(0.94)
        navAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.18)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        UINavigationBar.appearance().tintColor = .systemBlue
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        tabAppearance.backgroundColor = UIColor.systemGroupedBackground.withAlphaComponent(0.96)
        tabAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.18)

        UITabBar.appearance().tintColor = .systemBlue
        UITabBar.appearance().isTranslucent = true
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(appState: appState)
                .task {
                    API2FileIOSAppDelegate.sharedState = appState
                    await appState.startEngineIfNeeded()
                    await appState.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await appState.handleAppBecameActive() }
                    case .background:
                        API2FileIOSAppDelegate.scheduleBackgroundWork()
                    default:
                        break
                    }
                }
        }
    }
}

final class API2FileIOSAppDelegate: NSObject, UIApplicationDelegate {
    static weak var sharedState: IOSAppState?

    static let refreshTaskIdentifier = "com.api2file.ios.refresh"
    static let processingTaskIdentifier = "com.api2file.ios.processing"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.handle(task: task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Self.handle(task: task)
        }
        Self.scheduleBackgroundWork()
        return true
    }

    static func scheduleBackgroundWork() {
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refreshRequest)

        let processingRequest = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processingRequest)
    }

    private static func handle(task: BGTask) {
        scheduleBackgroundWork()

        let worker = Task {
            await sharedState?.performBackgroundSync()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            worker.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
