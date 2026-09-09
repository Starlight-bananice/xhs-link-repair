import Foundation

func runExportSettingsTests() -> Bool {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("xhs-export-settings-\(UUID().uuidString)", isDirectory: true)
    let suite = "xhs-export-settings-test-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return false }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
    do {
        let original = root.appendingPathComponent("默认结果", isDirectory: true)
        let custom = root.appendingPathComponent("自选结果", isDirectory: true)
        let settings = ExportSettings(defaults: defaults, defaultDirectory: original)
        let initial = settings.history()
        check(settings.directory == original && initial.items.isEmpty && initial.unreadableDirectories.isEmpty,
              "首次启动使用默认位置，未生成目录时显示空历史")
        try settings.prepareDirectory()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let first = try XLSXWriter.makeOutputURL(in: original, at: date)
        let row = SpreadsheetExportRow(sequence: 1, original: "TEST", noteID: "f00000000000000000000001",
                                       status: "已删除", newURL: "", note: "测试", processedAt: date)
        try XLSXWriter.write(rows: [row], to: first)
        let second = try XLSXWriter.makeOutputURL(in: original, at: date)
        check(first != second, "同秒导出不能覆盖原报告")
        try XLSXWriter.write(rows: [row], to: second)
        settings.selectDirectory(custom)
        try settings.prepareDirectory()
        let third = try XLSXWriter.makeOutputURL(in: settings.directory, at: date)
        try XLSXWriter.write(rows: [row], to: third)
        check(third.deletingLastPathComponent() == custom, "报告保存到用户选择的目录")
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: first.path)
        try fm.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: second.path)
        try fm.setAttributes([.modificationDate: date.addingTimeInterval(2)], ofItemAtPath: third.path)
        try Data("unrelated".utf8).write(to: custom.appendingPathComponent("其他表格.xlsx"))
        try fm.createDirectory(at: custom.appendingPathComponent("假文件_小红书链接转换结果.xlsx"), withIntermediateDirectories: true)
        let reopened = ExportSettings(defaults: defaults, defaultDirectory: original)
        check(reopened.directory == custom, "重新创建设置后仍保留保存位置")
        let history = reopened.history()
        check(history.unreadableDirectories.isEmpty && history.items.map { $0.url.resolvingSymlinksInPath().path } == [third, second, first].map { $0.resolvingSymlinksInPath().path },
              "历史跨目录排序、去重，并排除无关表格和同名目录")
        let alias = root.appendingPathComponent("自选目录的别名")
        try fm.createSymbolicLink(at: alias, withDestinationURL: custom)
        reopened.selectDirectory(alias)
        check(reopened.history().items.count == 3, "同一文件夹的不同路径不能产生重复历史")
        reopened.selectDirectory(original)
        check(reopened.history().items.count == 3, "切回旧目录不会丢失或重复历史")
        try fm.removeItem(at: third)
        check(reopened.history().items.map { $0.url.resolvingSymlinksInPath().path } == [second, first].map { $0.resolvingSymlinksInPath().path }, "已删除的文件不保留失效历史项")
        let invalid = root.appendingPathComponent("不是文件夹")
        try Data().write(to: invalid)
        reopened.selectDirectory(invalid)
        do {
            try reopened.prepareDirectory()
            failures.append("文件路径不能当作保存目录")
        } catch { }
    } catch {
        failures.append(error.localizedDescription)
    }
    for failure in failures { fputs("EXPORT SETTINGS TEST FAILED: \(failure)\n", stderr) }
    if failures.isEmpty { print("EXPORT SETTINGS TESTS PASSED: saved folder, history, export and collision handling") }
    return failures.isEmpty
}
