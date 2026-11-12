import Combine
import Foundation
import Sparkle

/// The UI observes Sparkle's own preferences; it does not keep a second copy.
@MainActor
protocol AppUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var onChange: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
final class AppUpdateModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var errorMessage: String? {
        didSet {
            if let errorMessage {
                Log.settings.error("Updater: \(errorMessage, privacy: .public)")
            }
        }
    }
    @Published private(set) var isConfigured = false
    private var driver: AppUpdateDriving?

    func start(bundle: Bundle = .main) {
        guard driver == nil else { return }
        guard Self.hasValidConfiguration(bundle.infoDictionary ?? [:]), bundle.bundleURL.pathExtension == "app" else {
            errorMessage = "此构建尚未配置更新，请从版本历史下载正式版。"
            return
        }
        start(driver: SparkleUpdateDriver())
    }

    static func hasValidConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start(driver: AppUpdateDriving) {
        guard self.driver == nil else { return }
        self.driver = driver
        driver.onChange = { [weak self] in self?.refresh() }
        driver.onError = { [weak self] message in self?.errorMessage = message }
        do {
            try driver.start()
            isConfigured = true
            errorMessage = nil
            refresh()
        } catch {
            driver.onChange = nil
            driver.onError = nil
            self.driver = nil
            errorMessage = "更新服务无法启动：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        errorMessage = nil
        driver?.checkForUpdates()
        refresh()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        driver?.automaticallyChecksForUpdates = enabled
        refresh()
    }

    private func refresh() {
        guard let driver else { return }
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        lastUpdateCheckDate = driver.lastUpdateCheckDate
    }
}

enum AppUpdateReleasePolicy {
    static func bestUpdate(in items: [SUAppcastItem], currentVersion: String) -> SUAppcastItem {
        let comparator = SUStandardVersionComparator()
        let latest = items.max {
            let releaseOrder = comparator.compareVersion($0.displayVersionString, toVersion: $1.displayVersionString)
            if releaseOrder == .orderedSame {
                return comparator.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending
            }
            return releaseOrder == .orderedAscending
        }
        // Local builds use a release version for CFBundleVersion, while CI uses
        // a run number. Only a newer display version represents a new release.
        guard let latest,
              comparator.compareVersion(latest.displayVersionString, toVersion: currentVersion) == .orderedDescending else {
            // Sparkle presents its normal "up to date" result for an empty selection.
            return SUAppcastItem.empty()
        }
        return latest
    }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, AppUpdateDriving, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func start() throws {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        try controller.updater.start()
        // Sparkle delivers updater state on the main thread. Keep the UI in
        // sync even when the standard update window changes a preference.
        observations = [
            controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            },
            controller.updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            },
        ]
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        AppUpdateReleasePolicy.bestUpdate(in: appcast.items, currentVersion: AppInfo.version)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // A successful "no update" result is presented by Sparkle itself.
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain,
           [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) { return }
        onError?("检查更新失败：\(error.localizedDescription)")
    }
}
