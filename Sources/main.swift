import AppKit
import Foundation

private func runSelfTests() -> Int32 {
    let cases: [(String, String?)] = [
        ("https://www.xiaohongshu.com/discovery/item/f00000000000000000000001", "f00000000000000000000001"),
        ("https://www.xiaohongshu.com/explore/f00000000000000000000002", "f00000000000000000000002"),
        ("xhsdiscover://item/f00000000000000000000003", "f00000000000000000000003"),
        ("F00000000000000000000004", "f00000000000000000000004"),
        ("not a link", nil)
    ]
    for (input, expected) in cases {
        let actual = LinkTools.extractNoteID(from: input)
        guard actual == expected else {
            fputs("SELF-TEST FAILED: \(input) -> \(actual ?? "nil")\n", stderr)
            return 1
        }
    }

    let batchInput = """
    https://www.xiaohongshu.com/discovery/item/f00000000000000000000001
    https://www.xiaohongshu.com/discovery/item/f00000000000000000000002
    https://www.xiaohongshu.com/discovery/item/f00000000000000000000001
    F00000000000000000000004
    """
    let expectedBatch = [
        "f00000000000000000000001",
        "f00000000000000000000002",
        "f00000000000000000000004"
    ]
    guard LinkTools.extractNoteIDs(from: batchInput) == expectedBatch else {
        fputs("SELF-TEST FAILED: batch extraction or deduplication\n", stderr)
        return 1
    }
    let references = LinkTools.extractNoteReferences(from: batchInput)
    guard references.map(\.id) == expectedBatch,
          references.first?.original.contains("xiaohongshu.com") == true else {
        fputs("SELF-TEST FAILED: original link preservation\n", stderr)
        return 1
    }

    let shareText = "复制后打开小红书 https://xhslink.com/a/AbCdEf123456 ，查看笔记"
    guard LinkTools.extractWebURL(from: shareText)?.host == "xhslink.com" else {
        fputs("SELF-TEST FAILED: share URL extraction\n", stderr)
        return 1
    }

    guard let deepLink = LinkTools.deepLink(
        for: "f00000000000000000000001"
    ), deepLink.absoluteString == "xhsdiscover://item/f00000000000000000000001" else {
        fputs("SELF-TEST FAILED: direct client link\n", stderr)
        return 1
    }

    guard runAutomationSafetyTests(), runExportSettingsTests(), runAppUpdaterTests() else { return 1 }
    print("SELF-TEST PASSED")
    return 0
}

private func runXLSXSelfTest(destination: String) -> Int32 {
    let rows = [
        SpreadsheetExportRow(
            sequence: 1,
            original: "https://www.xiaohongshu.com/discovery/item/f00000000000000000000001",
            noteID: "f00000000000000000000001",
            status: "成功",
            newURL: "https://www.xiaohongshu.com/explore/f00000000000000000000001?xsec_token=TEST_TOKEN%3D&xsec_source=app_share",
            note: "已展开为带 xsec_token 的完整链接",
            processedAt: Date()
        ),
        SpreadsheetExportRow(
            sequence: 2,
            original: "https://www.xiaohongshu.com/discovery/item/f00000000000000000000002",
            noteID: "f00000000000000000000002",
            status: "已删除",
            newURL: "",
            note: "客户端显示当前内容无法展示",
            processedAt: Date()
        ),
        SpreadsheetExportRow(
            sequence: 3,
            original: "f00000000000000000000004",
            noteID: "f00000000000000000000004",
            status: "失败",
            newURL: "",
            note: "示例自动化失败信息",
            processedAt: Date()
        )
    ]
    do {
        try XLSXWriter.write(rows: rows, to: URL(fileURLWithPath: destination))
        print(destination)
        return 0
    } catch {
        fputs("XLSX SELF-TEST FAILED: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private enum BatchOutcome {
    case success(item: NoteReference, url: URL, expanded: Bool)
    case deleted(item: NoteReference)
    case failure(item: NoteReference, message: String)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runner = AutomationRunner()
    private let intervalBetweenItems: TimeInterval = 2.0
    private let exportSettings = ExportSettings()
    private var historyController: HistoryWindowController?

    private var window: NSWindow!
    private var inputTextView: NSTextView!
    private var outputTextView: NSTextView!
    private var statusLabel: NSTextField!
    private var runButton: NSButton!
    private var stopButton: NSButton!
    private var folderButton: NSButton!
    private var historyButton: NSButton!
    private var browserHelperButton: NSButton!
    private var folderLabel: NSTextField!
    private var excelButton: NSButton!
    private var coordinateCheckbox: NSButton!
    private var updateButton: NSButton!
    private var availableRelease: AppRelease?
    private var updateBusy = false
    private var installingUpdate = false
    private var updateTask: Task<Void, Never>?


    private var batchItems: [NoteReference] = []
    private var batchIndex = 0
    private var outcomes: [BatchOutcome] = []
    private var batchRunning = false
    private var stopRequested = false
    private var retryCount = 0
    private var lastExcelURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppMenu.install(on: NSApp)
        buildWindow()
        restoreUpdateSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkForUpdates(manual: false) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let contentSize = NSSize(width: 760, height: 720)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "小红书链接批量修复"
        window.center()
        window.isReleasedWhenClosed = false

        guard let content = window.contentView else { return }

        let title = label("批量生成浏览器可打开的小红书链接", size: 22, weight: .semibold)
        title.frame = NSRect(x: 28, y: 660, width: 704, height: 32)
        content.addSubview(title)

        let subtitle = label(
            "每行一条，也可直接粘贴整列或表格；按顺序逐条处理并自动去重。",
            size: 13,
            color: .secondaryLabelColor
        )
        subtitle.frame = NSRect(x: 28, y: 630, width: 704, height: 24)
        content.addSubview(subtitle)

        let inputTitle = label("原始链接或笔记 ID", size: 13, weight: .medium)
        inputTitle.frame = NSRect(x: 28, y: 594, width: 260, height: 20)
        content.addSubview(inputTitle)

        let input = makeTextArea(frame: NSRect(x: 28, y: 402, width: 704, height: 184), editable: true)
        inputTextView = input.textView
        content.addSubview(input.scrollView)

        coordinateCheckbox = NSButton(
            checkboxWithTitle: "控件识别失败时按窗口位置点击（适配 iPad 版 9.46.2）",
            target: nil,
            action: nil
        )
        coordinateCheckbox.frame = NSRect(x: 28, y: 366, width: 520, height: 24)
        coordinateCheckbox.state = .on
        content.addSubview(coordinateCheckbox)

        runButton = NSButton(title: "开始批量转换", target: self, action: #selector(startBatch))
        runButton.frame = NSRect(x: 28, y: 314, width: 190, height: 38)
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        content.addSubview(runButton)

        stopButton = NSButton(title: "停止", target: self, action: #selector(stopBatch))
        stopButton.frame = NSRect(x: 230, y: 314, width: 90, height: 38)
        stopButton.isEnabled = false
        content.addSubview(stopButton)

        statusLabel = label("就绪", size: 13, color: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 338, y: 320, width: 394, height: 24)
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        let folderTitle = label("Excel 保存到", size: 12, color: .secondaryLabelColor)
        folderTitle.frame = NSRect(x: 28, y: 276, width: 90, height: 22)
        content.addSubview(folderTitle)
        folderLabel = label("", size: 12, color: .secondaryLabelColor)
        folderLabel.frame = NSRect(x: 122, y: 276, width: 470, height: 22)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(folderLabel)
        folderButton = NSButton(title: "选择保存位置…", target: self, action: #selector(chooseExportDirectory))
        folderButton.frame = NSRect(x: 604, y: 270, width: 128, height: 32)
        content.addSubview(folderButton)
        updateFolderLabel()

        let outputTitle = label("转换结果", size: 13, weight: .medium)
        outputTitle.frame = NSRect(x: 28, y: 238, width: 180, height: 20)
        content.addSubview(outputTitle)

        browserHelperButton = NSButton(title: "恢复浏览器打开…", target: self, action: #selector(openBrowserHelper))
        browserHelperButton.frame = NSRect(x: 220, y: 232, width: 172, height: 30)
        browserHelperButton.toolTip = "在 Safari 中完成打开方式选择，再回原应用验证链接"
        content.addSubview(browserHelperButton)

        historyButton = NSButton(title: "查看历史记录", target: self, action: #selector(showHistory))
        historyButton.frame = NSRect(x: 402, y: 232, width: 140, height: 30)
        content.addSubview(historyButton)

        excelButton = NSButton(title: "打开 Excel", target: self, action: #selector(openLastExcel))
        excelButton.frame = NSRect(x: 552, y: 232, width: 180, height: 30)
        excelButton.isEnabled = false
        content.addSubview(excelButton)

        let output = makeTextArea(frame: NSRect(x: 28, y: 58, width: 704, height: 166), editable: false)
        outputTextView = output.textView
        content.addSubview(output.scrollView)

        let permissionHint = label(
            "逐条处理；结束后生成 Excel，失效内容标记为“已删除”。",
            size: 12,
            color: .tertiaryLabelColor
        )
        permissionHint.frame = NSRect(x: 28, y: 20, width: 510, height: 24)
        content.addSubview(permissionHint)

        let versionLabel = label("v\(AppUpdater.currentVersion)", size: 11, color: .secondaryLabelColor)
        versionLabel.frame = NSRect(x: 546, y: 23, width: 72, height: 20)
        versionLabel.alignment = .right
        content.addSubview(versionLabel)
        updateButton = NSButton(title: "检查更新", target: self, action: #selector(updateClicked))
        updateButton.frame = NSRect(x: 628, y: 17, width: 104, height: 28)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: 11)
        content.addSubview(updateButton)

        // 标签使用自身固有高度，与同排按钮垂直居中，避免固定文本框高度造成视觉错位。
        let textRows: [(NSTextField, NSButton)] = [
            (statusLabel, runButton), (folderTitle, folderButton), (folderLabel, folderButton),
            (outputTitle, excelButton), (permissionHint, updateButton), (versionLabel, updateButton)
        ]
        for (field, button) in textRows {
            let frame = field.frame
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: frame.minX),
                field.widthAnchor.constraint(equalToConstant: frame.width),
                field.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
        }

        window.makeKeyAndOrderFront(nil)
    }

    private func makeTextArea(frame: NSRect, editable: Bool) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = NSScrollView(frame: frame)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        if !editable {
            textView.backgroundColor = .controlBackgroundColor
        }
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func prefillFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !LinkTools.extractNoteIDs(from: text).isEmpty else { return }
        inputTextView.string = text
    }

    @objc private func startBatch() {
        guard !batchRunning, !installingUpdate else { return }
        let items = LinkTools.extractNoteReferences(from: inputTextView.string)
        guard !items.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "没有识别到小红书笔记 ID"
            NSSound.beep()
            return
        }

        do {
            try exportSettings.prepareDirectory()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "保存文件夹不可用，请重新选择保存位置"
            let alert = NSAlert()
            alert.messageText = "无法使用当前保存位置"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
            return
        }
        retryCount = 0
        batchItems = items
        batchIndex = 0
        outcomes = []
        batchRunning = true
        updateButton.isEnabled = false
        stopRequested = false
        outputTextView.string = ""
        runButton.isEnabled = false
        stopButton.isEnabled = true
        folderButton.isEnabled = false
        historyButton.isEnabled = false
        browserHelperButton.isEnabled = false
        excelButton.isEnabled = false
        lastExcelURL = nil
        statusLabel.textColor = .secondaryLabelColor
        processNextItem()
    }

    private func processNextItem() {
        if stopRequested || batchIndex >= batchItems.count {
            finishBatch(stopped: stopRequested)
            return
        }

        let position = batchIndex + 1
        let item = batchItems[batchIndex]
        statusLabel.stringValue = "第 \(position)/\(batchItems.count) 条：准备打开 \(item.id)"

        runner.run(
            input: item.id,
            useCoordinateFallback: coordinateCheckbox.state == .on,
            minimumInterval: intervalBetweenItems,
            onStatus: { [weak self] text in
                guard let self else { return }
                self.statusLabel.stringValue = "第 \(position)/\(self.batchItems.count) 条：\(text)"
            },
            completion: { [weak self] result in
                guard let self else { return }

                if case .failure(let error) = result,
                   let repairError = error as? RepairError,
                   [.clipboardTimeout, .shareButtonNotFound, .copyButtonNotFound, .unexpectedPage].contains(repairError),
                   self.retryCount == 0, !self.stopRequested {
                    self.retryCount = 1
                    self.statusLabel.stringValue = "页面已恢复，2 秒后重试当前链接（仅一次）…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.intervalBetweenItems) {
                        self.processNextItem()
                    }
                    return
                }
                self.retryCount = 0
                var nextItemDelay = self.intervalBetweenItems
                switch result {
                case .success(let value):
                    nextItemDelay = value.nextItemDelay
                    self.outcomes.append(.success(item: item, url: value.url, expanded: value.expanded))
                case .failure(let error):
                    if let repairError = error as? RepairError {
                        switch repairError {
                        case .contentDeleted:
                            self.outcomes.append(.deleted(item: item))
                        case .accessibilityPermission, .navigationRecoveryFailed, .foregroundChanged:
                            self.outcomes.append(.failure(item: item, message: error.localizedDescription))
                            self.stopRequested = true
                        default:
                            self.outcomes.append(.failure(item: item, message: error.localizedDescription))
                        }
                    } else {
                        self.outcomes.append(.failure(item: item, message: error.localizedDescription))
                    }
                }

                self.batchIndex += 1
                self.updateOutput()

                if self.stopRequested || self.batchIndex >= self.batchItems.count {
                    self.finishBatch(stopped: self.stopRequested)
                    return
                }

                self.statusLabel.stringValue = nextItemDelay > 0
                    ? "第 \(position)/\(self.batchItems.count) 条完成，稍后继续…"
                    : "第 \(position)/\(self.batchItems.count) 条完成，正在继续…"
                DispatchQueue.main.asyncAfter(deadline: .now() + nextItemDelay) {
                    self.processNextItem()
                }
            }
        )
    }

    @objc private func stopBatch() {
        guard batchRunning else { return }
        stopRequested = true
        stopButton.isEnabled = false
        statusLabel.textColor = .systemOrange
        statusLabel.stringValue = "将在当前链接处理完成后停止…"
    }

    private func finishBatch(stopped: Bool) {
        batchRunning = false
        updateButton.isEnabled = !updateBusy
        runButton.isEnabled = true
        stopButton.isEnabled = false

        let successes = outcomes.filter {
            if case .success(_, _, true) = $0 { return true }
            return false
        }
        let deleted = outcomes.filter {
            if case .deleted = $0 { return true }
            return false
        }.count
        let pending = outcomes.filter {
            if case .success(_, _, false) = $0 { return true }
            return false
        }.count
        let failures = outcomes.count - successes.count - deleted - pending
        folderButton.isEnabled = true
        historyButton.isEnabled = true
        browserHelperButton.isEnabled = true

        var excelError: Error?
        if !outcomes.isEmpty {
            do {
                let url = try XLSXWriter.makeOutputURL(in: exportSettings.directory)
                try XLSXWriter.write(rows: spreadsheetRows(), to: url)
                lastExcelURL = url
                excelButton.isEnabled = true
                historyController?.reloadHistory()
            } catch {
                excelError = error
            }
        }

        if let excelError {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Excel 保存失败：\(excelError.localizedDescription)"
            NSSound.beep()
        } else if stopped {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "已停止：成功 \(successes.count)，待核验 \(pending)，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
        } else if successes.isEmpty {
            statusLabel.textColor = failures == 0 ? .systemOrange : .systemRed
            statusLabel.stringValue = "完成：成功 0，待核验 \(pending)，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
        } else {
            statusLabel.textColor = failures == 0 && pending == 0 ? .systemGreen : .systemOrange
            statusLabel.stringValue = "完成：成功 \(successes.count)，待核验 \(pending)，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let lastExcelURL, excelError == nil {
            _ = NSWorkspace.shared.open(lastExcelURL)
        }
    }

    private func updateOutput() {
        outputTextView.string = outcomes.map { outcome in
            switch outcome {
            case .success(_, let url, let expanded):
                return expanded ? url.absoluteString : "【待核验】\(url.absoluteString)"
            case .deleted(let item):
                return "【已删除】\(item.id)"
            case .failure(let item, let message):
                return "【失败】\(item.id) — \(message)"
            }
        }.joined(separator: "\n")
        outputTextView.scrollToEndOfDocument(nil)
    }

    private func spreadsheetRows() -> [SpreadsheetExportRow] {
        outcomes.enumerated().map { offset, outcome in
            switch outcome {
            case .success(let item, let url, let expanded):
                return SpreadsheetExportRow(
                    sequence: offset + 1,
                    original: item.original,
                    noteID: item.id,
                    status: expanded ? "成功" : "待核验",
                    newURL: url.absoluteString,
                    note: expanded ? "已核验笔记 ID 的完整链接" : "官方分享短链（未展开核验）",
                    processedAt: Date()
                )
            case .deleted(let item):
                return SpreadsheetExportRow(
                    sequence: offset + 1,
                    original: item.original,
                    noteID: item.id,
                    status: "已删除",
                    newURL: "",
                    note: "客户端显示当前内容无法展示",
                    processedAt: Date()
                )
            case .failure(let item, let message):
                return SpreadsheetExportRow(
                    sequence: offset + 1,
                    original: item.original,
                    noteID: item.id,
                    status: "失败",
                    newURL: "",
                    note: message,
                    processedAt: Date()
                )
            }
        }
    }

    private func restoreUpdateSession() {
        do {
            if let saved = try UpdateSession.take() {
                inputTextView.string = saved.input
                outputTextView.string = saved.output
                statusLabel.stringValue = saved.status
                if let fallback = saved.coordinateFallback { coordinateCheckbox.state = fallback ? .on : .off }
                if let path = saved.excelPath, FileManager.default.fileExists(atPath: path) {
                    lastExcelURL = URL(fileURLWithPath: path)
                    excelButton.isEnabled = true
                }
            } else {
                prefillFromClipboard()
            }
        } catch {
            statusLabel.stringValue = "上次更新的输入未能恢复，请重新粘贴链接"
        }
        if let message = try? String(contentsOf: UpdateSession.failureFile, encoding: .utf8) {
            statusLabel.stringValue = message
            statusLabel.textColor = .systemOrange
            try? FileManager.default.removeItem(at: UpdateSession.failureFile)
        }
    }

    @objc private func updateClicked() {
        guard !batchRunning, !updateBusy else { return }
        if let release = availableRelease { downloadUpdate(release) }
        else { checkForUpdates(manual: true) }
    }

    private func checkForUpdates(manual: Bool) {
        guard !updateBusy else { return }
        updateBusy = true
        updateButton.title = "检查中…"
        updateButton.isEnabled = false
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.availableRelease = try await AppUpdater.check(currentVersion: AppUpdater.currentVersion)
                self.updateButton.title = self.availableRelease == nil ? "已是最新版" : "更新"
                self.updateButton.toolTip = self.availableRelease.map { "更新到 v\($0.version)，下载后安装并重启" }
                if manual, self.availableRelease == nil {
                    self.statusLabel.stringValue = "当前已是最新版 v\(AppUpdater.currentVersion)"
                    self.statusLabel.textColor = .secondaryLabelColor
                }
            } catch {
                self.updateButton.title = "重试检查"
                self.updateButton.toolTip = error.localizedDescription
                if manual { self.showUpdateError("检查更新失败", error: error) }
            }
            self.updateBusy = false
            self.updateButton.isEnabled = !self.batchRunning
        }
    }

    private func downloadUpdate(_ release: AppRelease) {
        guard !batchRunning, !updateBusy else { return }
        updateBusy = true
        installingUpdate = true
        updateButton.isEnabled = false
        runButton.isEnabled = false
        folderButton.isEnabled = false
        historyButton.isEnabled = false
        browserHelperButton.isEnabled = false
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var prepared: PreparedAppUpdate?
            var savedSession = false
            do {
                let update = try await AppUpdater.prepare(release) { [weak self] text in
                    DispatchQueue.main.async { self?.updateButton.title = text }
                }
                prepared = update
                let snapshot = UpdateSession(input: self.inputTextView.string, output: self.outputTextView.string,
                                             status: self.statusLabel.stringValue, excelPath: self.lastExcelURL?.path,
                                             coordinateFallback: self.coordinateCheckbox.state == .on)
                try snapshot.save()
                savedSession = true
                try? FileManager.default.removeItem(at: UpdateSession.failureFile)
                try AppUpdater.launchInstaller(update, parentPID: ProcessInfo.processInfo.processIdentifier)
                self.updateButton.title = "正在重启…"
                NSApp.terminate(nil)
            } catch {
                if savedSession { try? FileManager.default.removeItem(at: UpdateSession.file) }
                if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
                self.updateBusy = false
                self.installingUpdate = false
                self.updateButton.title = "重试更新"
                self.updateButton.isEnabled = true
                self.runButton.isEnabled = true
                self.folderButton.isEnabled = true
                self.historyButton.isEnabled = true
                self.browserHelperButton.isEnabled = true
                self.showUpdateError("更新未完成", error: error)
            }
        }
    }

    private func showUpdateError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "打开发布页")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { _ = NSWorkspace.shared.open(AppUpdater.releasePage) }
        }
    }

    @objc private func openBrowserHelper() {
        guard !batchRunning, !installingUpdate else { return }
        guard let page = Bundle.main.url(forResource: "BrowserLinkHelper", withExtension: "html"),
              let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            let alert = NSAlert()
            alert.messageText = "无法打开浏览器助手"
            alert.informativeText = "请确认 Safari 已安装且应用资源完整。"
            alert.beginSheetModal(for: window)
            return
        }
        NSWorkspace.shared.open([page], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "无法打开 Safari 助手"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: self.window)
                } else {
                    self.statusLabel.stringValue = "已打开 Safari 助手，请按页面提示操作后验证原链接"
                    self.statusLabel.textColor = .secondaryLabelColor
                }
            }
        }
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = (exportSettings.directory.path as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = exportSettings.directory.path
    }

    @objc private func chooseExportDirectory() {
        guard !batchRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Excel 保存文件夹"
        panel.message = "之后的转换结果会自动保存到此文件夹；以前的报告仍可从历史记录查看。"
        panel.prompt = "选择此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportSettings.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.exportSettings.selectDirectory(url)
            self.updateFolderLabel()
            self.historyController?.reloadHistory()
        }
    }

    @objc private func showHistory() {
        guard !batchRunning else { return }
        if historyController == nil { historyController = HistoryWindowController(settings: exportSettings) }
        historyController?.reloadHistory()
        historyController?.showWindow(nil)
        historyController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLastExcel() {
        guard let lastExcelURL else { return }
        _ = NSWorkspace.shared.open(lastExcelURL)
    }
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
}

if CommandLine.arguments.contains("--test-update-download") {
    Task.detached {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xhs-update-download-test-\(UUID().uuidString)")
        do {
            defer { try? FileManager.default.removeItem(at: root) }
            guard let release = try await AppUpdater.check(currentVersion: "0.0.0") else { throw UpdateFailure("没有可测试的正式版") }
            let target = root.appendingPathComponent("fixture.app")
            try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": AppUpdater.bundleID], format: .xml, options: 0)
            try info.write(to: target.appendingPathComponent("Contents/Info.plist"))
            let prepared = try await AppUpdater.prepare(release, target: target) { print($0) }
            guard FileManager.default.fileExists(atPath: prepared.source.appendingPathComponent("Contents/MacOS/XHSLinkRepair").path) else {
                throw UpdateFailure("下载验证未完成")
            }
            try FileManager.default.removeItem(at: root)
            print("LIVE UPDATE DOWNLOAD PASSED: \(release.version); installed app was not changed")
            exit(0)
        } catch { try? FileManager.default.removeItem(at: root); fputs("LIVE UPDATE DOWNLOAD FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--check-update"),
   CommandLine.arguments.indices.contains(index + 1) {
    let version = CommandLine.arguments[index + 1]
    Task.detached {
        do {
            if let release = try await AppUpdater.check(currentVersion: version) { print("UPDATE AVAILABLE: \(release.version)") }
            else { print("NO NEWER RELEASE") }
            exit(0)
        } catch { fputs("UPDATE CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--xlsx-self-test"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(runXLSXSelfTest(destination: CommandLine.arguments[index + 1]))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
