import Foundation
import CryptoKit

func runAppUpdaterTests() -> Bool {
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
    func rejects(_ message: String, _ block: () throws -> Void) {
        do { try block(); failures.append(message) } catch { }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xhs-update-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func payload(_ version: String = "0.5.10") -> [String: Any] {
            let file = "XHSLinkRepair-\(version)-macOS-arm64.zip"
            return ["tag_name": "v\(version)", "draft": false, "prerelease": false,
                    "assets": [["name": file, "browser_download_url": "https://github.com/\(AppUpdater.repository)/releases/download/v\(version)/\(file)",
                                "digest": "sha256:" + String(repeating: "a", count: 64), "size": 1024]]]
        }
        func parse(_ value: [String: Any], current: String = "0.5.9") throws -> AppRelease? {
            try AppUpdater.release(from: JSONSerialization.data(withJSONObject: value), currentVersion: current)
        }
        check(try AppVersion("0.5.10") > AppVersion("v0.5.9"), "版本需按数值比较")
        check(try parse(payload())?.version == "0.5.10", "找到对应 macOS 安装包")
        check(try parse(payload("0.5.8")) == nil && parse(payload("0.5.9")) == nil, "不降级也不重复更新")
        for key in ["draft", "prerelease"] {
            var value = payload(); value[key] = true
            check(try parse(value) == nil, "不安装草稿或预发布版本")
        }
        var broken = payload(); broken["tag_name"] = "v0.5.10-rc1"
        rejects("非法正式版标签必须拒绝") { _ = try parse(broken) }
        broken = payload(); broken["assets"] = []
        rejects("缺少平台安装包不能报告可更新") { _ = try parse(broken) }
        for (key, value) in [("browser_download_url", "https://example.com/app.zip"), ("digest", "sha256:invalid")] {
            broken = payload()
            var assets = broken["assets"] as! [[String: Any]]
            assets[0][key] = value; broken["assets"] = assets
            rejects("错误地址或校验信息必须拒绝") { _ = try parse(broken) }
        }

        let prefix = "\(AppUpdater.applicationName)/Contents/"
        let safe = updateTestZIP([(prefix + "Info.plist", Data("plist".utf8), 0o100644),
                                  (prefix + "MacOS/XHSLinkRepair", Data("executable".utf8), 0o100755)])
        try UpdateArchive.validate(safe)
        let digest = SHA256.hash(data: safe).map { String(format: "%02x", $0) }.joined()
        let release = AppRelease(version: "0.5.10", filename: "test.zip", url: AppUpdater.releasePage,
                                 sha256: digest, size: safe.count)
        try AppUpdater.validateDownload(safe, release: release)
        var corrupt = safe; corrupt[10] ^= 1
        rejects("下载内容损坏时必须拒绝安装") { try AppUpdater.validateDownload(corrupt, release: release) }
        for path in ["../outside", "/absolute", "C:/outside", "folder\\outside", prefix + "../outside"] {
            let unsafe = updateTestZIP([(prefix + "Info.plist", Data(), 0o100644),
                                        (prefix + "MacOS/XHSLinkRepair", Data(), 0o100755), (path, Data(), 0o100644)])
            rejects("ZIP 路径不能越界：\(path)") { try UpdateArchive.validate(unsafe) }
        }
        let symlink = updateTestZIP([(prefix + "Info.plist", Data(), 0o100644),
                                    (prefix + "MacOS/XHSLinkRepair", Data("/outside".utf8), 0o120777)])
        rejects("安装包不能包含符号链接") { try UpdateArchive.validate(symlink) }
        var mismatched = safe; mismatched[30] ^= 1
        rejects("本地文件头与中央目录不一致时必须拒绝") { try UpdateArchive.validate(mismatched) }
        rejects("截断安装包必须拒绝") { try UpdateArchive.validate(safe.prefix(safe.count - 4)) }

        let sessionURL = root.appendingPathComponent("support/pending.json")
        let snapshot = UpdateSession(input: "待处理输入", output: "已保存的结果", status: "完成", excelPath: "/test/report.xlsx", coordinateFallback: false)
        try snapshot.save(to: sessionURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "输入恢复文件仅当前用户可读写")
        check(try UpdateSession.take(from: sessionURL) == snapshot, "重启恢复输入和结果")
        check(try UpdateSession.take(from: sessionURL) == nil, "恢复后移除临时会话，避免重复载入")

        // 在隔离目录中运行真正的替换脚本；true/false 替代打开 App，不触碰当前安装。
        for success in [true, false] {
            let scenario = root.appendingPathComponent("更新 空格' \(success)")
            let work = scenario.appendingPathComponent("work")
            let target = scenario.appendingPathComponent("target.app")
            let source = work.appendingPathComponent("new.app")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("old"))
            try Data("new".utf8).write(to: source.appendingPathComponent("new"))
            let failure = scenario.appendingPathComponent("failure.txt")
            let process = try AppUpdater.launchInstaller(
                PreparedAppUpdate(directory: work, source: source, target: target),
                parentPID: 99_999_999, failureFile: failure, opener: success ? "/usr/bin/true" : "/usr/bin/false"
            )
            process.waitUntilExit()
            check((process.terminationStatus == 0) == success, "安装脚本返回正确状态")
            check(FileManager.default.fileExists(atPath: target.appendingPathComponent(success ? "new" : "old").path),
                  "安装成功替换，启动失败恢复原版")
            check(FileManager.default.fileExists(atPath: failure.path) == !success, "失败原因保留供重启提示")
            if success { check(!FileManager.default.fileExists(atPath: work.path), "安装成功后清理临时副本") }
        }
    } catch { failures.append(error.localizedDescription) }
    for failure in failures { fputs("APP UPDATE TEST FAILED: \(failure)\n", stderr) }
    if failures.isEmpty { print("APP UPDATE TESTS PASSED: release checks, archive validation, session restore, install and rollback") }
    return failures.isEmpty
}

private func updateTestZIP(_ files: [(String, Data, Int)]) -> Data {
    var result = Data()
    var central = Data()
    func bytes(_ value: Int, _ count: Int) -> Data {
        Data((0..<count).map { UInt8((value >> ($0 * 8)) & 255) })
    }
    for (path, contents, mode) in files {
        let name = Data(path.utf8)
        let offset = result.count
        var header = Data(repeating: 0, count: 30)
        header.replaceSubrange(0..<4, with: bytes(0x04034b50, 4))
        header.replaceSubrange(18..<22, with: bytes(contents.count, 4))
        header.replaceSubrange(22..<26, with: bytes(contents.count, 4))
        header.replaceSubrange(26..<28, with: bytes(name.count, 2))
        result.append(header); result.append(name); result.append(contents)
        var entry = Data(repeating: 0, count: 46)
        entry.replaceSubrange(0..<4, with: bytes(0x02014b50, 4))
        entry.replaceSubrange(20..<24, with: bytes(contents.count, 4))
        entry.replaceSubrange(24..<28, with: bytes(contents.count, 4))
        entry.replaceSubrange(28..<30, with: bytes(name.count, 2))
        entry.replaceSubrange(38..<42, with: bytes(mode << 16, 4))
        entry.replaceSubrange(42..<46, with: bytes(offset, 4))
        central.append(entry); central.append(name)
    }
    var end = Data(repeating: 0, count: 22)
    end.replaceSubrange(0..<4, with: bytes(0x06054b50, 4))
    end.replaceSubrange(8..<10, with: bytes(files.count, 2))
    end.replaceSubrange(10..<12, with: bytes(files.count, 2))
    end.replaceSubrange(12..<16, with: bytes(central.count, 4))
    end.replaceSubrange(16..<20, with: bytes(result.count, 4))
    result.append(central); result.append(end)
    return result
}
