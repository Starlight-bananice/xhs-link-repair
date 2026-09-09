import AppKit
import ApplicationServices
import Foundation

enum RepairError: LocalizedError {
    case invalidInput
    case accessibilityPermission
    case deepLinkOpenFailed
    case appNotFound
    case contentDeleted
    case windowNotFound
    case shareButtonNotFound
    case copyButtonNotFound
    case clipboardTimeout
    case copiedTextHasNoURL
    case copiedWrongNote
    case unexpectedPage
    case navigationRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "没有识别到小红书笔记 ID，请粘贴裸链接、完整链接或 24 位笔记 ID。"
        case .accessibilityPermission:
            return "需要“辅助功能”权限。请在系统设置里允许本工具控制电脑，然后回来再点一次。"
        case .deepLinkOpenFailed:
            return "无法调用小红书客户端，请确认 iPad 版小红书已经安装。"
        case .appNotFound:
            return "小红书客户端没有启动，请先手动打开一次后重试。"
        case .contentDeleted:
            return "客户端显示当前内容无法展示。"
        case .windowNotFound:
            return "没有找到小红书窗口，请把笔记窗口放在屏幕上后重试。"
        case .shareButtonNotFound:
            return "没有找到右上角分享按钮；可能是页面仍在加载或客户端版式已变化。"
        case .copyButtonNotFound:
            return "分享面板已打开，但没有找到“复制链接”。"
        case .clipboardTimeout:
            return "点击后剪贴板没有出现新内容。请确认分享面板已完整显示。"
        case .copiedTextHasNoURL:
            return "客户端复制了内容，但其中没有识别到网页链接。"
        case .copiedWrongNote:
            return "复制到的链接不是当前笔记，已丢弃并恢复页面。"
        case .unexpectedPage:
            return "客户端停留在首页或作者主页，未打开目标笔记。"
        case .navigationRecoveryFailed:
            return "未能恢复小红书首页，已停止批次。请在客户端返回首页后重新开始。"
        }
    }
}

final class AutomationRunner {
    private let xiaohongshuBundleID = "com.xingin.discover"
    private let sharePointRatio = CGPoint(x: 0.968, y: 0.078)
    private let copyPointRatio = CGPoint(x: 0.786, y: 0.380)

    private var isRunning = false

    private var needsRedirectGuard = true

    func run(
        input: String,
        useCoordinateFallback: Bool,
        onStatus: @escaping (String) -> Void,
        completion: @escaping (Result<(url: URL, expanded: Bool), Error>) -> Void
    ) {
        // run 和 finish 中的运行标记都在主线程访问，直到链接展开完成才释放。
        guard !isRunning else { return }
        guard let noteID = LinkTools.extractNoteID(from: input),
              let deepLink = LinkTools.deepLink(for: noteID) else {
            completion(.failure(RepairError.invalidInput))
            return
        }
        let permissionOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(permissionOptions) else {
            completion(.failure(RepairError.accessibilityPermission))
            return
        }

        isRunning = true
        onStatus("正在准备小红书客户端…")
        if NSRunningApplication.runningApplications(withBundleIdentifier: xiaohongshuBundleID).isEmpty {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xiaohongshuBundleID) else {
                finish(.failure(RepairError.appNotFound), completion: completion)
                return
            }
            // 冷启动只打开应用；恢复页面之后才发送本条笔记链接。
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil
            )
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let app = waitForApplication(timeout: 12) else {
                finish(.failure(RepairError.appNotFound), completion: completion)
                return
            }
            _ = DispatchQueue.main.sync { app.activate(options: [.activateAllWindows]) }
            postStatus("正在返回首页，清理上一条页面…", handler: onStatus)
            guard restoreNavigation(in: app.processIdentifier, waitForPendingRedirect: needsRedirectGuard) else {
                needsRedirectGuard = true
                finish(.failure(RepairError.navigationRecoveryFailed), completion: completion)
                return
            }
            needsRedirectGuard = false

            postStatus("正在用小红书客户端打开笔记…", handler: onStatus)
            guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(deepLink) }) else {
                finish(.failure(RepairError.deepLinkOpenFailed), completion: completion)
                return
            }

            do {
                try waitForNotePage(in: app.processIdentifier)
                postStatus("正在点击右上角的分享按钮…", handler: onStatus)
                var sharePressed = pressElement(in: app.processIdentifier, containingAny: ["分享", "share"])
                if !sharePressed && useCoordinateFallback {
                    sharePressed = clickWindowPoint(for: app.processIdentifier, ratio: sharePointRatio)
                }
                guard sharePressed else { throw RepairError.shareButtonNotFound }

                // 打开分享面板期间也监测失效提示，不能只检查最初 3 秒。
                let panelDeadline = ProcessInfo.processInfo.systemUptime + 1.4
                repeat {
                    try checkForInvalidPage(in: app.processIdentifier)
                    Thread.sleep(forTimeInterval: 0.15)
                } while ProcessInfo.processInfo.systemUptime < panelDeadline
                postStatus("正在点击“复制链接”…", handler: onStatus)
                // 基准放在复制动作之前，忽略打开笔记过程中无关的剪贴板变化。
                let pasteboardCount = DispatchQueue.main.sync { NSPasteboard.general.changeCount }
                var copyPressed = pressElement(in: app.processIdentifier, containingAny: ["复制链接", "copy link"])
                if !copyPressed && useCoordinateFallback {
                    copyPressed = clickWindowPoint(for: app.processIdentifier, ratio: copyPointRatio)
                }
                guard copyPressed else { throw RepairError.copyButtonNotFound }
                guard let copiedText = try waitForClipboardChange(
                    after: pasteboardCount, timeout: 10, pid: app.processIdentifier
                ) else { throw RepairError.clipboardTimeout }
                guard let copiedURL = LinkTools.extractWebURL(from: copiedText) else {
                    throw RepairError.copiedTextHasNoURL
                }
                guard LinkTools.isShareURL(copiedURL, for: noteID) else {
                    throw RepairError.copiedWrongNote
                }

                postStatus("客户端已生成新链接，正在整理为浏览器可用格式…", handler: onStatus)
                ShareURLResolver.browserReadyURL(from: copiedURL) { [self] finalURL, expanded in
                    // 网络回调可能在任意队列；页面恢复仍在后台串行完成，再通知批次继续。
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        guard LinkTools.isShareURL(finalURL, for: noteID) else {
                            finishAfterRecovery(
                                RepairError.copiedWrongNote, app: app,
                                onStatus: onStatus, completion: completion
                            )
                            return
                        }
                        finish(.success((LinkTools.compactShareURL(finalURL), expanded)), completion: completion)
                    }
                }
            } catch {
                finishAfterRecovery(error, app: app, onStatus: onStatus, completion: completion)
            }
        }
    }

    private func finishAfterRecovery(
        _ error: Error,
        app: NSRunningApplication,
        onStatus: @escaping (String) -> Void,
        completion: @escaping (Result<(url: URL, expanded: Bool), Error>) -> Void
    ) {
        postStatus("当前链接未成功，正在退出页面并等待跳转结束…", handler: onStatus)
        needsRedirectGuard = !restoreNavigation(in: app.processIdentifier, waitForPendingRedirect: true)
        // 保留本条原始原因（尤其是“已删除”）；若恢复失败，下条开头会停止批次。
        finish(.failure(error), completion: completion)
    }

    private func restoreNavigation(in pid: pid_t, waitForPendingRedirect: Bool) -> Bool {
        NavigationRecovery.restore(
            waitForPendingRedirect: waitForPendingRedirect,
            snapshot: { self.navigationSnapshot(in: pid) },
            goBack: { self.pressBackButton(in: pid) },
            dismissPanel: { self.dismissSharePanel(in: pid) }
        )
    }

    private func waitForNotePage(in pid: pid_t) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 10
        repeat {
            let page = navigationSnapshot(in: pid)
            if page.isUnavailable { throw RepairError.contentDeleted }
            if ProcessInfo.processInfo.systemUptime - started >= 3, page.isNoteCandidate { return }
            Thread.sleep(forTimeInterval: 0.15)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw RepairError.unexpectedPage
    }

    private func checkForInvalidPage(in pid: pid_t) throws {
        let page = navigationSnapshot(in: pid)
        if page.isUnavailable { throw RepairError.contentDeleted }
        if page.isProfile || page.isHome { throw RepairError.unexpectedPage }
    }

    private func navigationSnapshot(in pid: pid_t) -> NavigationSnapshot {
        guard let window = currentWindow(in: pid) else { return NavigationSnapshot(labels: []) }
        var labels: [String] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count && index < 1_500 {
            let (element, depth) = queue[index]
            index += 1
            labels.append(contentsOf: accessibilityStrings(for: element))
            if depth < 20 {
                queue.append(contentsOf: attributeElements(element, kAXChildrenAttribute as CFString).map { ($0, depth + 1) })
            }
        }
        return NavigationSnapshot(labels: labels)
    }

    private func currentWindow(in pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        return attributeElement(application, kAXFocusedWindowAttribute as CFString)
            ?? attributeElement(application, kAXMainWindowAttribute as CFString)
            ?? attributeElements(application, kAXWindowsAttribute as CFString).first
    }

    private func dismissSharePanel(in pid: pid_t) -> Bool {
        if pressElement(in: pid, containingAny: ["取消", "cancel"], exactMatch: true) { return true }
        guard let window = currentWindow(in: pid) else { return false }
        var queue = [window]
        var index = 0
        while index < queue.count && index < 80 {
            let element = queue[index]
            index += 1
            if AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success { return true }
            queue.append(contentsOf: attributeElements(element, kAXChildrenAttribute as CFString))
        }
        return false
    }

    private func pressBackButton(in pid: pid_t) -> Bool {
        if pressElement(in: pid, containingAny: ["返回", "back", "后退"], exactMatch: true) { return true }
        // 正常图文笔记的左上角按钮没有文字；只在已识别的笔记页寻找该区域的实际 AX 按钮。
        guard navigationSnapshot(in: pid).isNoteCandidate,
              let window = currentWindow(in: pid),
              let frame = frontWindowFrame(for: pid) else { return false }
        var queue = [window]
        var index = 0
        while index < queue.count && index < 250 {
            let element = queue[index]
            index += 1
            if attributeString(element, kAXRoleAttribute as CFString) == kAXButtonRole as String,
               let rect = accessibilityRect(for: element),
               rect.width > 0, rect.height > 0,
               rect.midX >= frame.minX, rect.midX < frame.minX + frame.width * 0.10,
               rect.midY > frame.minY + 32, rect.midY < frame.minY + frame.height * 0.15 {
                return press(element)
            }
            queue.append(contentsOf: attributeElements(element, kAXChildrenAttribute as CFString))
        }
        return false
    }

    private func waitForApplication(timeout: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: xiaohongshuBundleID
            ).first(where: { !$0.isTerminated }) {
                return app
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private func waitForClipboardChange(after initialCount: Int, timeout: TimeInterval, pid: pid_t) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try checkForInvalidPage(in: pid)
            let snapshot: (Int, String?) = DispatchQueue.main.sync {
                let pasteboard = NSPasteboard.general
                return (pasteboard.changeCount, pasteboard.string(forType: .string))
            }
            if snapshot.0 != initialCount, let text = snapshot.1, !text.isEmpty {
                return text
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    private func pressElement(in pid: pid_t, containingAny labels: [String], exactMatch: Bool = false) -> Bool {
        guard let window = currentWindow(in: pid) else { return false }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let needles = labels.map { $0.lowercased() }

        while !queue.isEmpty && visited < 1_500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let texts = accessibilityStrings(for: element).map { $0.lowercased() }
            let matches = texts.contains { text in
                needles.contains { exactMatch ? text == $0 : text.contains($0) }
            }
            let role = attributeString(element, kAXRoleAttribute as CFString)
            if matches && (role == kAXButtonRole as String || role == kAXStaticTextRole as String) {
                if press(element) { return true }
                if let parent = attributeElement(element, kAXParentAttribute as CFString),
                   press(parent) {
                    return true
                }
            }

            if depth < 14 {
                for child in attributeElements(element, kAXChildrenAttribute as CFString) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return false
    }

    private func accessibilityStrings(for element: AXUIElement) -> [String] {
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXIdentifierAttribute as CFString,
            kAXValueAttribute as CFString
        ]
        return attributes.compactMap { attributeString(element, $0) }
    }

    private func press(_ element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        guard let rect = accessibilityRect(for: element) else { return false }
        return click(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func clickWindowPoint(for pid: pid_t, ratio: CGPoint) -> Bool {
        guard let frame = frontWindowFrame(for: pid) else { return false }
        let point = CGPoint(
            x: frame.minX + frame.width * ratio.x,
            y: frame.minY + frame.height * ratio.y
        )
        return click(at: point)
    }

    private func click(at point: CGPoint) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func frontWindowFrame(for pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var candidates: [CGRect] = []
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else {
                continue
            }
            if rect.width > 400 && rect.height > 300 {
                candidates.append(rect)
            }
        }
        return candidates.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func attributeValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func attributeString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        attributeValue(element, attribute) as? String
    }

    private func attributeElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func attributeElements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        attributeValue(element, attribute) as? [AXUIElement] ?? []
    }

    private func accessibilityRect(for element: AXUIElement) -> CGRect? {
        guard let positionValue = attributeValue(element, kAXPositionAttribute as CFString),
              let sizeValue = attributeValue(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func postStatus(_ text: String, handler: @escaping (String) -> Void) {
        DispatchQueue.main.async { handler(text) }
    }

    private func finish<T>(
        _ result: Result<T, Error>,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            self.isRunning = false
            completion(result)
        }
    }
}
