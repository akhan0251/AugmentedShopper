import SwiftUI
import Foundation
import UIKit
import MWDATCore

@main
struct RayBanPriceScannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // ✅ REQUIRED for Meta Wearables SDK
        try? Wearables.configure()
        print("✅ Meta Wearables configured")
        #if DEBUG
        logWearablesSelectors()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleWearablesCallback(url)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 } ?? []
        print("ℹ️ App launched with bundle id: \(bundleID) | URL Schemes: \(schemes)")
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
            print("ℹ️ AppDelegate continue userActivity with URL: \(url)")
            handleWearablesCallback(url)
            return true
        }
        return false
    }

    @available(iOS, deprecated: 26.0, message: "Use UIScene openURLContexts")
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        print("ℹ️ AppDelegate received openURL: \(url)")
        handleWearablesCallback(url)
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let context = URLContexts.first else { return }
        let url = context.url
        print("ℹ️ SceneDelegate received openURL: \(url)")
        handleWearablesCallback(url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
            print("ℹ️ SceneDelegate continue userActivity with URL: \(url)")
            handleWearablesCallback(url)
        }
    }
}

func handleWearablesCallback(_ url: URL) {
    Task {
        print("ℹ️ Attempting to forward wearables callback: \(url.absoluteString)")
        do {
            _ = try await Wearables.shared.handleUrl(url)
            print("✅ Wearables handled callback URL")
        } catch {
            print("⚠️ Wearables handleUrl failed: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
private func logWearablesSelectors() {
    guard let cls: AnyClass = object_getClass(Wearables.shared) else {
        print("⚠️ Could not inspect Wearables.shared class")
        return
    }
    var count: UInt32 = 0
    if let methodList = class_copyMethodList(cls, &count) {
        var names: [String] = []
        for i in 0..<Int(count) {
            let sel = method_getName(methodList[i])
            names.append(NSStringFromSelector(sel))
        }
        free(methodList)
        let filtered = names.filter { $0.lowercased().contains("url") || $0.lowercased().contains("register") }
        print("ℹ️ Wearables.shared selectors matching url/register: \(filtered)")
    }
}
#endif
