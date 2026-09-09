import Foundation

struct ExportHistoryItem {
    let url: URL
    let modifiedAt: Date
}

final class ExportSettings {
    private let defaults: UserDefaults
    let defaultDirectory: URL
    private let directoryKey = "excelExportDirectory"
    private let knownDirectoriesKey = "excelExportKnownDirectories"

    init(defaults: UserDefaults = .standard, defaultDirectory: URL? = nil) {
        self.defaults = defaults
        self.defaultDirectory = defaultDirectory ?? FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("小红书链接转换结果", isDirectory: true)
    }

    var directory: URL {
        guard let path = defaults.string(forKey: directoryKey), !path.isEmpty else { return defaultDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func selectDirectory(_ url: URL) {
        // 记住历次使用的目录；切换位置后，旧目录中的报告仍可从历史记录打开。
        var paths = defaults.stringArray(forKey: knownDirectoriesKey) ?? []
        for directory in [defaultDirectory, self.directory, url] {
            let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
            if !paths.contains(path) { paths.append(path) }
        }
        defaults.set(paths, forKey: knownDirectoriesKey)
        defaults.set(url.resolvingSymlinksInPath().standardizedFileURL.path, forKey: directoryKey)
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
        }
    }

    func history() -> (items: [ExportHistoryItem], unreadableDirectories: [URL]) {
        let paths = (defaults.stringArray(forKey: knownDirectoriesKey) ?? [])
            + [defaultDirectory.path, directory.path]
        var seenDirectories = Set<String>()
        var seenFiles = Set<String>()
        var items: [ExportHistoryItem] = []
        var unreadable: [URL] = []
        let fm = FileManager.default
        for path in paths {
            let folder = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard seenDirectories.insert(folder.path).inserted else { continue }
            do {
                let urls = try fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                for url in urls where url.lastPathComponent.hasSuffix("_小红书链接转换结果.xlsx") {
                    guard seenFiles.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted,
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                          values.isRegularFile == true else { continue }
                    items.append(ExportHistoryItem(url: url, modifiedAt: values.contentModificationDate ?? .distantPast))
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // 默认目录尚未生成或报告文件夹已被删除时，历史中不显示该目录。
                continue
            } catch {
                unreadable.append(folder)
            }
        }
        return (items.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.url.path > $1.url.path
        }, unreadable)
    }
}
