import AppKit
import Foundation

private func runSelfTests() -> Int32 {
    let cases: [(String, String?)] = [
        ("https://www.xiaohongshu.com/discovery/item/000000000000000000000001", "000000000000000000000001"),
        ("https://www.xiaohongshu.com/explore/000000000000000000000002", "000000000000000000000002"),
        ("xhsdiscover://item/000000000000000000000003", "000000000000000000000003"),
        ("000000000000000000000004", "000000000000000000000004"),
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
    https://www.xiaohongshu.com/discovery/item/000000000000000000000001
    https://www.xiaohongshu.com/discovery/item/000000000000000000000002
    https://www.xiaohongshu.com/discovery/item/000000000000000000000001
    000000000000000000000004
    """
    let expectedBatch = [
        "000000000000000000000001",
        "000000000000000000000002",
        "000000000000000000000004"
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
        for: "000000000000000000000001"
    ), deepLink.absoluteString == "xhsdiscover://item/000000000000000000000001" else {
        fputs("SELF-TEST FAILED: direct client link\n", stderr)
        return 1
    }

    guard runAutomationSafetyTests() else { return 1 }
    print("SELF-TEST PASSED")
    return 0
}

private func runXLSXSelfTest(destination: String) -> Int32 {
    let rows = [
        SpreadsheetExportRow(
            sequence: 1,
            original: "https://www.xiaohongshu.com/discovery/item/000000000000000000000001",
            noteID: "000000000000000000000001",
            status: "成功",
            newURL: "https://www.xiaohongshu.com/explore/000000000000000000000001?xsec_token=TEST_TOKEN%3D&xsec_source=app_share",
            note: "已展开为带 xsec_token 的完整链接",
            processedAt: Date()
        ),
        SpreadsheetExportRow(
            sequence: 2,
            original: "https://www.xiaohongshu.com/discovery/item/000000000000000000000002",
            noteID: "000000000000000000000002",
            status: "已删除",
            newURL: "",
            note: "客户端显示当前内容无法展示",
            processedAt: Date()
        ),
        SpreadsheetExportRow(
            sequence: 3,
            original: "000000000000000000000004",
            noteID: "000000000000000000000004",
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

    private var window: NSWindow!
    private var inputTextView: NSTextView!
    private var outputTextView: NSTextView!
    private var statusLabel: NSTextField!
    private var runButton: NSButton!
    private var stopButton: NSButton!
    private var copyButton: NSButton!
    private var excelButton: NSButton!
    private var coordinateCheckbox: NSButton!

    private var batchItems: [NoteReference] = []
    private var batchIndex = 0
    private var outcomes: [BatchOutcome] = []
    private var batchRunning = false
    private var stopRequested = false
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
        let contentSize = NSSize(width: 760, height: 680)
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
        title.frame = NSRect(x: 28, y: 620, width: 704, height: 32)
        content.addSubview(title)

        let subtitle = label(
            "每行一条，也可直接粘贴整列或表格；按顺序逐条处理并自动去重。",
            size: 13,
            color: .secondaryLabelColor
        )
        subtitle.frame = NSRect(x: 28, y: 590, width: 704, height: 24)
        content.addSubview(subtitle)

        let inputTitle = label("原始链接或笔记 ID", size: 13, weight: .medium)
        inputTitle.frame = NSRect(x: 28, y: 554, width: 260, height: 20)
        content.addSubview(inputTitle)

        let input = makeTextArea(frame: NSRect(x: 28, y: 362, width: 704, height: 184), editable: true)
        inputTextView = input.textView
        content.addSubview(input.scrollView)

        coordinateCheckbox = NSButton(
            checkboxWithTitle: "控件识别失败时按窗口位置点击（适配 iPad 版 9.45.2）",
            target: nil,
            action: nil
        )
        coordinateCheckbox.frame = NSRect(x: 28, y: 326, width: 520, height: 24)
        coordinateCheckbox.state = .on
        content.addSubview(coordinateCheckbox)

        runButton = NSButton(title: "开始批量转换", target: self, action: #selector(startBatch))
        runButton.frame = NSRect(x: 28, y: 274, width: 190, height: 38)
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        content.addSubview(runButton)

        stopButton = NSButton(title: "停止", target: self, action: #selector(stopBatch))
        stopButton.frame = NSRect(x: 230, y: 274, width: 90, height: 38)
        stopButton.isEnabled = false
        content.addSubview(stopButton)

        statusLabel = label("就绪", size: 13, color: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 338, y: 280, width: 394, height: 24)
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        let outputTitle = label("转换结果", size: 13, weight: .medium)
        outputTitle.frame = NSRect(x: 28, y: 238, width: 180, height: 20)
        content.addSubview(outputTitle)

        copyButton = NSButton(title: "复制成功链接", target: self, action: #selector(copySuccessfulResults))
        copyButton.frame = NSRect(x: 382, y: 232, width: 160, height: 30)
        copyButton.isEnabled = false
        content.addSubview(copyButton)

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

        batchItems = items
        batchIndex = 0
        outcomes = []
        batchRunning = true
        stopRequested = false
        outputTextView.string = ""
        runButton.isEnabled = false
        stopButton.isEnabled = true
        copyButton.isEnabled = false
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
            onStatus: { [weak self] text in
                guard let self else { return }
                self.statusLabel.stringValue = "第 \(position)/\(self.batchItems.count) 条：\(text)"
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let value):
                    self.outcomes.append(.success(item: item, url: value.url, expanded: value.expanded))
                case .failure(let error):
                    if let repairError = error as? RepairError {
                        switch repairError {
                        case .contentDeleted:
                            self.outcomes.append(.deleted(item: item))
                        case .accessibilityPermission, .navigationRecoveryFailed:
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

                self.statusLabel.stringValue = "第 \(position)/\(self.batchItems.count) 条完成，2 秒后继续…"
                DispatchQueue.main.asyncAfter(deadline: .now() + self.intervalBetweenItems) {
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

        let successes = successfulURLs()
        let deleted = outcomes.filter {
            if case .deleted = $0 { return true }
            return false
        }.count
        let failures = outcomes.count - successes.count - deleted
        copyButton.isEnabled = !successes.isEmpty

        if !successes.isEmpty {
            writeSuccessfulURLsToPasteboard(successes)
        }

        var excelError: Error?
        if !outcomes.isEmpty {
            do {
                let url = try XLSXWriter.makeDefaultOutputURL()
                try XLSXWriter.write(rows: spreadsheetRows(), to: url)
                lastExcelURL = url
                excelButton.isEnabled = true
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
            statusLabel.stringValue = "已停止：成功 \(successes.count)，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
        } else if successes.isEmpty {
            statusLabel.textColor = failures == 0 ? .systemOrange : .systemRed
            statusLabel.stringValue = "完成：成功 0，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
        } else {
            statusLabel.textColor = failures == 0 ? .systemGreen : .systemOrange
            statusLabel.stringValue = "完成：成功 \(successes.count)，已删除 \(deleted)，失败 \(failures)；已导出 Excel"
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
            case .success(_, let url, _):
                return url.absoluteString
            case .deleted(let item):
                return "【已删除】\(item.id)"
            case .failure(let item, let message):
                return "【失败】\(item.id) — \(message)"
            }
        }.joined(separator: "\n")
        outputTextView.scrollToEndOfDocument(nil)
    }

    private func successfulURLs() -> [URL] {
        outcomes.compactMap { outcome in
            if case .success(_, let url, _) = outcome { return url }
            return nil
        }
    }

    private func spreadsheetRows() -> [SpreadsheetExportRow] {
        outcomes.enumerated().map { offset, outcome in
            switch outcome {
            case .success(let item, let url, let expanded):
                return SpreadsheetExportRow(
                    sequence: offset + 1,
                    original: item.original,
                    noteID: item.id,
                    status: "成功",
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

    private func writeSuccessfulURLsToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            urls.map(\.absoluteString).joined(separator: "\n"),
            forType: .string
        )
    }

    @objc private func copySuccessfulResults() {
        let urls = successfulURLs()
        guard !urls.isEmpty else { return }
        writeSuccessfulURLsToPasteboard(urls)
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "已复制 \(urls.count) 条成功链接"
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
