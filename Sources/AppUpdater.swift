import Foundation
import CryptoKit

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct AppVersion: Comparable {
    let parts: [Int]
    init(_ text: String) throws {
        guard text.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw UpdateFailure("版本号格式不正确")
        }
        let values = text.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { throw UpdateFailure("版本号格式不正确") }
        parts = values
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Equatable {
    let version: String
    let filename: String
    let url: URL
    let sha256: String
    let size: Int
}

struct PreparedAppUpdate {
    let directory: URL
    let source: URL
    let target: URL
}

struct UpdateSession: Codable, Equatable {
    let input: String
    let output: String
    let status: String
    let excelPath: String?
    var coordinateFallback: Bool? = nil

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XHSLinkRepair", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("pending-update-session.json") }
    static var failureFile: URL { directory.appendingPathComponent("update-failed.txt") }

    func save(to url: URL = Self.file) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // 明确使用私有权限，临时保留当前输入和结果；更新重启读取后即移除。
        let data = try JSONEncoder().encode(self)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateFailure("无法保存当前输入，请稍后重试更新")
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temporary, to: url)
    }

    static func take(from url: URL = Self.file) throws -> UpdateSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(UpdateSession.self, from: Data(contentsOf: url))
        try FileManager.default.removeItem(at: url)
        return value
    }
}

enum AppUpdater {
    static let repository = "Starlight-bananice/xhs-link-repair"
    static let bundleID = "com.starlightbananice.xhslinkrepair"
    static let applicationName = "小红书链接修复.app"
    static let releasePage = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let maximumArchiveSize = 32 * 1024 * 1024
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private struct Payload: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?
            let size: Int
        }
    }

    static func release(from data: Data, currentVersion: String) throws -> AppRelease? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }
        let version = try AppVersion(payload.tag_name)
        guard version > (try AppVersion(currentVersion)) else { return nil }
        let text = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let filename = "XHSLinkRepair-\(text)-macOS-arm64.zip"
        let matching = payload.assets.filter { $0.name == filename }
        guard matching.count == 1, let asset = matching.first else {
            throw UpdateFailure("新版安装包尚未准备好，请稍后重试")
        }
        let expectedURL = "https://github.com/\(repository)/releases/download/\(payload.tag_name)/\(filename)"
        guard asset.browser_download_url == expectedURL, let url = URL(string: expectedURL),
              asset.size > 0, asset.size <= maximumArchiveSize else {
            throw UpdateFailure("新版安装包信息不正确")
        }
        guard let digest = asset.digest,
              digest.range(of: #"^sha256:[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateFailure("新版缺少下载校验信息，请稍后重试或到发布页手动下载")
        }
        return AppRelease(version: text, filename: filename, url: url,
                          sha256: String(digest.dropFirst(7)).lowercased(), size: asset.size)
    }

    static func check(currentVersion: String) async throws -> AppRelease? {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("XHSLinkRepair/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        guard data.count < 2 * 1024 * 1024 else { throw UpdateFailure("版本信息过大，请稍后重试") }
        return try release(from: data, currentVersion: currentVersion)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    private static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateFailure(code == 429 ? "检查过于频繁，请稍后重试" : "更新服务暂不可用（\(code)）")
        }
    }

    static func validateDownload(_ data: Data, release: AppRelease) throws {
        guard data.count == release.size, data.count <= maximumArchiveSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == release.sha256 else {
            throw UpdateFailure("安装包校验失败，请重新下载")
        }
        try UpdateArchive.validate(data)
    }

    static func validateApplication(_ application: URL, version: String) throws {
        let data = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleExecutable"] as? String == "XHSLinkRepair",
              FileManager.default.isExecutableFile(atPath: application.appendingPathComponent("Contents/MacOS/XHSLinkRepair").path)
        else { throw UpdateFailure("安装包中的应用或版本不匹配") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
    }

    static func prepare(_ release: AppRelease, target: URL = Bundle.main.bundleURL,
                        progress: @escaping (String) -> Void) async throws -> PreparedAppUpdate {
        let fm = FileManager.default
        guard target.pathExtension == "app", target.lastPathComponent != "",
              let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateFailure("请从正式版 App 使用更新功能")
        }
        let work = target.deletingLastPathComponent().appendingPathComponent(".xhs-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateFailure("安装目录不可写，请将 App 放到可写目录，或到发布页手动更新")
        }
        do {
            progress("下载中…")
            let session = makeSession()
            defer { session.finishTasksAndInvalidate() }
            let (temporary, response) = try await session.download(from: release.url)
            defer { try? fm.removeItem(at: temporary) }
            try validateResponse(response)
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == release.size, size <= maximumArchiveSize else { throw UpdateFailure("安装包大小不正确") }
            let archive = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: temporary, to: archive)
            progress("校验中…")
            try validateDownload(Data(contentsOf: archive), release: release)
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            let source = unpacked.appendingPathComponent(applicationName)
            try validateApplication(source, version: release.version)
            try Task.checkCancellation()
            return PreparedAppUpdate(directory: work, source: source, target: target)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    @discardableResult
    static func launchInstaller(_ update: PreparedAppUpdate, parentPID: Int32,
                                failureFile: URL = UpdateSession.failureFile,
                                opener: String = "/usr/bin/open") throws -> Process {
        let script = update.directory.appendingPathComponent("install.sh")
        try installerScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(parentPID), update.source.path, update.target.path,
                             update.directory.path, failureFile.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    // 所有路径均通过参数传入，不把用户目录拼入 shell 代码。
    static let installerScript = #"""
#!/bin/sh
set -eu
umask 077
parent="$1"; source="$2"; target="$3"; work="$4"; failure="$5"; opener="$6"
backup="$work/previous.app"
count=0
while kill -0 "$parent" 2>/dev/null; do
  count=$((count + 1))
  if [ "$count" -ge 120 ]; then
    printf '%s' '等待旧版本退出超时，请重试更新。' > "$failure"
    exit 1
  fi
  sleep 0.5
done
moved=0
rollback() {
  code=$?
  if [ "$code" -ne 0 ]; then
    printf '%s' '自动更新未完成，已尝试恢复原版本。请重试更新或到发布页手动安装。' > "$failure"
    if [ "$moved" = 1 ]; then
      [ ! -e "$target" ] || /bin/mv "$target" "$work/failed.app"
      /bin/mv "$backup" "$target"
      "$opener" "$target" || true
    fi
  fi
}
trap rollback EXIT
/bin/mv "$target" "$backup"
moved=1
/bin/mv "$source" "$target"
"$opener" "$target"
moved=0
trap - EXIT
/bin/rm -rf "$work"
"""#

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateFailure("安装包验证失败。\(detail.prefix(180))")
        }
    }
}
