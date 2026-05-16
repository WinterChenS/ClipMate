import Foundation
import AppKit

// ============================================================
// UpdateChecker - 版本更新检查
// 通过 GitHub Releases API 获取最新版本 tag，与当前版本比较
// 网络异常时静默失败，绝不崩溃
// ============================================================

@MainActor
class UpdateChecker: ObservableObject {

    // MARK: - 发布状态

    struct ReleaseInfo: Sendable {
        let tagName: String       // e.g. "v1.2.0"
        let version: String      // e.g. "1.2.0"
        let htmlURL: String?      // release 页面链接
        let body: String?         // release notes
    }

    // MARK: - 公开状态

    /// 检查结果
    enum CheckResult: Equatable {
        case idle           // 未检查
        case upToDate       // 已是最新版本
        case updateAvailable // 有新版本
        case failed         // 检查失败
    }

    /// 是否有可用更新
    @Published var updateAvailable: Bool = false
    /// 最新版本信息
    @Published var latestRelease: ReleaseInfo?
    /// 是否正在检查
    @Published var isChecking: Bool = false
    /// 检查结果
    @Published var checkResult: CheckResult = .idle
    /// 错误信息（仅供调试，不展示给用户）
    @Published var lastError: String?

    // MARK: - 持久化（使用 UserDefaults，@AppStorage 仅限 SwiftUI View）

    /// 用户跳过的版本号（"不再提醒"）
    private var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: "skippedVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }

    /// 上次检查时间戳（限制检查频率，最多每天一次）
    private var lastCheckTimestamp: Double {
        get { UserDefaults.standard.double(forKey: "lastUpdateCheckTimestamp") }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheckTimestamp") }
    }

    // MARK: - 配置

    /// GitHub 仓库所有者
    private let repoOwner = "w1nterchen"
    /// GitHub 仓库名
    private let repoName = "ClipMate"
    /// 检查间隔（秒），默认 24 小时
    private let checkInterval: TimeInterval = 24 * 60 * 60

    // MARK: - 当前版本

    /// 当前应用版本（从 Bundle 获取）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查更新

    /// 自动检查（受频率限制 + 跳过版本过滤）
    func checkForUpdateIfNeeded() {
        // 频率限制：距离上次检查不足 24 小时则跳过
        let now = Date().timeIntervalSince1970
        guard now - lastCheckTimestamp >= checkInterval else {
            print("[UpdateChecker] 距上次检查不足 24h，跳过")
            return
        }

        performCheck()
    }

    /// 手动检查（忽略频率限制，但仍然尊重跳过版本）
    func checkForUpdate() {
        performCheck()
    }

    /// 强制检查（忽略频率限制和跳过版本，用于"关于"页面手动检查）
    func forceCheck() {
        performCheck(ignoreSkipped: true)
    }

    // MARK: - 内部实现

    private func performCheck(ignoreSkipped: Bool = false) {
        guard !isChecking else { return }

        isChecking = true
        lastError = nil
        checkResult = .idle

        let owner = repoOwner
        let repo = repoName

        Task { [weak self] in
            guard let self = self else { return }

            do {
                let release = try await fetchLatestRelease(owner: owner, repo: repo)

                // 更新时间戳
                self.lastCheckTimestamp = Date().timeIntervalSince1970

                // 解析版本号（去掉 v 前缀）
                let remoteVersion = release.version
                let localVersion = self.currentVersion

                print("[UpdateChecker] 远程版本: \(remoteVersion), 本地版本: \(localVersion)")

                if self.isNewer(remote: remoteVersion, local: localVersion) {
                    // 检查用户是否已跳过此版本
                    if !ignoreSkipped && self.skippedVersion == remoteVersion {
                        print("[UpdateChecker] 用户已跳过版本 \(remoteVersion)")
                        self.updateAvailable = false
                        self.latestRelease = nil
                        self.checkResult = .upToDate
                    } else {
                        self.latestRelease = release
                        self.updateAvailable = true
                        self.checkResult = .updateAvailable
                    }
                } else {
                    self.updateAvailable = false
                    self.latestRelease = nil
                    self.checkResult = .upToDate
                }
            } catch {
                // 网络异常静默处理，绝不崩溃
                print("[UpdateChecker] 检查更新失败: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                self.checkResult = .failed
            }

            self.isChecking = false
        }
    }

    /// 请求 GitHub Releases API
    private nonisolated func fetchLatestRelease(owner: String, repo: String) async throws -> ReleaseInfo {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15 // 15 秒超时

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        // 404 = 还没有 release，不算错误
        if httpResponse.statusCode == 404 {
            throw UpdateError.noRelease
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpError(statusCode: httpResponse.statusCode)
        }

        // 安全解析 JSON
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.invalidJSON
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let htmlURL = json["html_url"] as? String
        let body = json["body"] as? String

        return ReleaseInfo(
            tagName: tagName,
            version: version,
            htmlURL: htmlURL,
            body: body
        )
    }

    // MARK: - 版本比较

    /// 语义化版本比较：remote > local → true
    private func isNewer(remote: String, local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        // 补齐到 3 段 (major.minor.patch)
        var r = remoteParts
        var l = localParts
        while r.count < 3 { r.append(0) }
        while l.count < 3 { l.append(0) }

        for i in 0..<3 {
            if r[i] > l[i] { return true }
            if r[i] < l[i] { return false }
        }
        return false // 完全相同
    }

    // MARK: - 用户操作

    /// 跳过当前可用更新（不再提醒此版本）
    func skipCurrentUpdate() {
        if let release = latestRelease {
            skippedVersion = release.version
            updateAvailable = false
            latestRelease = nil
            print("[UpdateChecker] 用户跳过版本 \(release.version)")
        }
    }

    /// 打开下载页面
    func openDownloadPage() {
        if let urlString = latestRelease?.htmlURL,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            // fallback: 打开 GitHub releases 页面
            if let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - 错误类型

enum UpdateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidJSON
    case noRelease
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的请求地址"
        case .invalidResponse: return "无效的响应"
        case .invalidJSON: return "解析版本信息失败"
        case .noRelease: return "暂无发布版本"
        case .httpError(let code): return "请求失败 (HTTP \(code))"
        }
    }
}
