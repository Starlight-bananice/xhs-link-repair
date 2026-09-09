import AppKit

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: ExportSettings
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "暂无历史记录。完成转换后，导出的 Excel 会显示在这里。")
    private var items: [ExportHistoryItem] = []
    private let openButton = NSButton(title: "打开 Excel", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(settings: ExportSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "转换历史记录"
        window.minSize = NSSize(width: 720, height: 340)
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }

        summary.frame = NSRect(x: 20, y: 398, width: 744, height: 22)
        summary.autoresizingMask = [.width, .minYMargin]
        summary.lineBreakMode = .byTruncatingTail
        content.addSubview(summary)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshHistory))
        refresh.frame = NSRect(x: 790, y: 393, width: 90, height: 30)
        refresh.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(refresh)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 70, width: 860, height: 314))
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 30
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        for (id, title, width) in [("date", "修改时间", 165.0), ("name", "文件名", 320.0), ("folder", "保存位置", 345.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 100
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        scroll.documentView = table
        content.addSubview(scroll)

        emptyLabel.frame = NSRect(x: 40, y: 216, width: 820, height: 24)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        content.addSubview(emptyLabel)

        openButton.target = self
        openButton.action = #selector(openSelected)
        openButton.frame = NSRect(x: 600, y: 20, width: 120, height: 32)
        openButton.autoresizingMask = [.minXMargin]
        content.addSubview(openButton)
        revealButton.target = self
        revealButton.action = #selector(revealSelected)
        revealButton.frame = NSRect(x: 730, y: 20, width: 150, height: 32)
        revealButton.autoresizingMask = [.minXMargin]
        content.addSubview(revealButton)
        let hint = NSTextField(labelWithString: "汇总默认及历次选择的保存文件夹；双击报告可打开。")
        hint.frame = NSRect(x: 20, y: 25, width: 560, height: 20)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.autoresizingMask = [.width]
        content.addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadHistory() {
        let selectedURL = selectedItem?.url
        let history = settings.history()
        items = history.items
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        summary.stringValue = history.unreadableDirectories.isEmpty
            ? "共 \(items.count) 份报告，最近的记录排在最前。"
            : "共 \(items.count) 份报告；\(history.unreadableDirectories.count) 个保存文件夹暂时无法读取。"
        summary.toolTip = history.unreadableDirectories.map(\.path).joined(separator: "\n")
        if let selectedURL, let row = items.firstIndex(where: { $0.url == selectedURL }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedItem: ExportHistoryItem? {
        items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
    }

    private func updateButtons() {
        openButton.isEnabled = selectedItem != nil
        revealButton.isEnabled = selectedItem != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = formatter.string(from: item.modifiedAt)
        case "name": text = item.url.lastPathComponent
        default: text = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = item.url.path
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    @objc private func refreshHistory() { reloadHistory() }

    @objc private func openSelected() {
        guard let item = selectedItem else { return }
        if !NSWorkspace.shared.open(item.url) {
            let alert = NSAlert()
            alert.messageText = "无法打开这份报告"
            alert.informativeText = "文件可能已移动或删除，也可能没有可用的 Excel 阅读软件。"
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    @objc private func revealSelected() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
