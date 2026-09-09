import Foundation

/// 只使用当前窗口的控件文字，避免把后台页面或菜单当作当前笔记。
struct NavigationSnapshot {
    let labels: [String]

    private var normalized: [String] {
        labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    var isUnavailable: Bool {
        normalized.contains { label in
            ["当前内容无法展示", "内容无法展示", "当前笔记无法查看", "跳转ta的主页", "跳转他的主页", "跳转她的主页"]
                .contains { label.hasPrefix($0) }
        }
    }

    var hasBackButton: Bool {
        normalized.contains { ["返回", "back", "后退"].contains($0) }
    }

    var hasSharePanel: Bool {
        normalized.contains { ["复制链接", "copy link"].contains($0) }
    }

    var isProfile: Bool {
        normalized.contains { $0.hasPrefix("小红书号：") || $0.hasPrefix("小红书号:") }
            && normalized.contains("获赞与收藏")
    }

    var isHome: Bool {
        normalized.contains("标签页栏") && !hasBackButton && !isUnavailable && !hasSharePanel
    }

    var isNoteCandidate: Bool {
        // iPad 图文笔记的返回/分享按钮可能完全没有标签，但底部操作有标签。
        let noteActions = normalized.contains("点赞") && normalized.contains("收藏") && normalized.contains("评论")
        return (hasBackButton || noteActions) && !isUnavailable && !isProfile && !hasSharePanel && !isHome
    }
}

enum NavigationRecovery {
    /// 先退出当前页面，再跨过旧失效页的 3 秒计时窗口。
    /// 即使旧计时器在返回后仍触发，也会再次退出作者主页；稳定在首页才允许下一条。
    static func restore(
        waitForPendingRedirect: Bool,
        snapshot: () -> NavigationSnapshot,
        goBack: () -> Bool,
        dismissPanel: () -> Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        let started = now()
        let deadline = started + 14
        var safeAfter = started + (waitForPendingRedirect ? 3.8 : 0)
        var unavailableObserved = false
        var stableHomeSince: TimeInterval?

        while now() < deadline {
            let page = snapshot()
            let time = now()
            guard time < deadline else { return false }
            if page.isUnavailable && !unavailableObserved {
                unavailableObserved = true
                safeAfter = max(safeAfter, time + 3.8)
            }

            if page.isHome {
                if stableHomeSince == nil { stableHomeSince = time }
                if time >= safeAfter, time - (stableHomeSince ?? time) >= 0.8 {
                    return true
                }
            } else {
                stableHomeSince = nil
                if page.hasSharePanel {
                    _ = dismissPanel()
                } else if page.hasBackButton || page.isNoteCandidate {
                    _ = goBack()
                }
            }
            sleep(0.25)
        }
        return false
    }
}
