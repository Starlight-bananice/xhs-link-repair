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

    guard runAutomationSafetyTests(), runExportSettingsTests() else { return 1 }
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
    private var folderLabel: NSTextField!
    private var excelButton: NSButton!
    private var coordinateCheckbox: NSButton!

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
        prefillFromClipboard()
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
            checkboxWithTitle: "控件识别失败时按窗口位置点击（适配 iPad 版 9.45.2）",
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
            "逐条串行处理；结束后自动生成并打开 Excel，失效内容标记为“已删除”。",
            size: 12,
            color: .tertiaryLabelColor
        )
        permissionHint.frame = NSRect(x: 28, y: 20, width: 704, height: 24)
        content.addSubview(permissionHint)

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
        guard !batchRunning else { return }
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
        stopRequested = false
        outputTextView.string = ""
        runButton.isEnabled = false
        stopButton.isEnabled = true
        folderButton.isEnabled = false
        historyButton.isEnabled = false
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

if let index = CommandLine.arguments.firstIndex(of: "--xlsx-self-test"),
   CommandLine.arguments.indices.contains(index + 1) {
    exit(runXLSXSelfTest(destination: CommandLine.arguments[index + 1]))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
