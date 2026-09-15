import Foundation

/// 使用虚拟时钟重现客户端的延迟跳转，不点击真实桌面、不请求网络。
func runAutomationSafetyTests() -> Bool {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
    var readiness = PageReadiness()
    check(!readiness.observe(ready: true, now: 0), "首次就绪不能立即点击")
    check(!readiness.observe(ready: false, now: 0.3), "加载中应重置稳定窗口")
    check(!readiness.observe(ready: true, now: 0.4), "重新就绪需要重新等待")
    check(!readiness.observe(ready: true, now: 0.7), "未稳定不能提前点击")
    check(readiness.observe(ready: true, now: 0.9), "稳定页面无需固定等待三秒")
    let home = NavigationSnapshot(labels: ["标签页栏", "发现"])
    let deleted = NavigationSnapshot(labels: ["返回", "当前内容无法展示", "跳转Ta的主页 · 3秒"])
    let profile = NavigationSnapshot(labels: ["返回", "小红书号：123456", "获赞与收藏", "更多"])
    let note = NavigationSnapshot(labels: ["点赞", "收藏", "评论", "笔记正文"])
    let panel = NavigationSnapshot(labels: ["返回", "复制链接", "取消"])
    check(deleted.isUnavailable, "失效提示识别")
    check(!profile.isNoteCandidate && !profile.isHome, "作者主页不能当作笔记或首页")
    check(note.isNoteCandidate, "正常笔记识别")
    check(NavigationSnapshot(labels: ["返回", "分享"]).isNoteCandidate, "有标签的笔记仍可识别")
    check(!NavigationSnapshot(labels: ["标签页栏", "返回"]).isHome, "后台标签页不能证明已返回首页")

    let compactWindow = CGRect(x: 0, y: 0, width: 780, height: 668)
    let tallWindow = CGRect(x: -900, y: 40, width: 780, height: 1_100)
    check(ShareButtonTarget.contains(CGRect(x: 730, y: 50, width: 32, height: 30), in: compactWindow),
          "当前小窗口的右上角按钮应被识别")
    check(ShareButtonTarget.contains(CGRect(x: -170, y: 90, width: 32, height: 30), in: tallWindow),
          "改变窗口高度和显示器位置后仍应识别右上角按钮")
    check(!ShareButtonTarget.contains(CGRect(x: 730, y: 350, width: 32, height: 30), in: compactWindow),
          "不能把右侧正文按钮当作分享")
    check(ShareButtonTarget.fallbackPoint(in: compactWindow) == CGPoint(x: 746, y: 65)
          && ShareButtonTarget.fallbackPoint(in: tallWindow) == CGPoint(x: -154, y: 105),
          "无标签时按右上角固定边距点击，不随窗口高度漂移")

    // 关键回归：退出失效页后，旧计时器仍在 3 秒时将首页切到作者主页。
    var time: TimeInterval = 0
    var page = deleted
    var redirectFired = false
    var backCount = 0
    let recovered = NavigationRecovery.restore(
        waitForPendingRedirect: true,
        snapshot: {
            if time >= 3 && !redirectFired { redirectFired = true; page = profile }
            return page
        },
        goBack: { backCount += 1; page = home; return true },
        dismissPanel: { false },
        now: { time },
        sleep: { time += $0 }
    )
    check(recovered && redirectFired && backCount == 2 && page.isHome && time >= 3.8,
          "旧倒计时必须被等待且跳转主页后再次返回")
    // 此时才打开下一条，之后不会再被旧计时器覆盖。
    page = note
    time += 5
    if !redirectFired && time >= 3 { page = profile }
    check(page.isNoteCandidate, "失效条目之后的正常笔记仍可继续")

    time = 0
    page = profile
    check(NavigationRecovery.restore(
        waitForPendingRedirect: false,
        snapshot: { page }, goBack: { page = home; return true }, dismissPanel: { false },
        now: { time }, sleep: { time += $0 }
    ) && page.isHome, "已跳到作者主页时可恢复")

    time = 0
    page = panel
    var dismissed = 0
    check(NavigationRecovery.restore(
        waitForPendingRedirect: true,
        snapshot: { page }, goBack: { page = home; return true },
        dismissPanel: { dismissed += 1; page = note; return true },
        now: { time }, sleep: { time += $0 }
    ) && dismissed == 1 && page.isHome, "残留分享面板必须先关闭")

    time = 0
    check(!NavigationRecovery.restore(
        waitForPendingRedirect: true,
        snapshot: { profile }, goBack: { false }, dismissPanel: { false },
        now: { time }, sleep: { time += $0 }
    ) && time <= 14.25, "无法返回时必须有界失败")

    time = 0
    page = NavigationSnapshot(labels: [])
    var lateDeletion = false
    check(NavigationRecovery.restore(
        waitForPendingRedirect: false,
        snapshot: {
            if time >= 2.5 && !lateDeletion { lateDeletion = true; page = deleted }
            return page
        }, goBack: { page = home; return true }, dismissPanel: { false },
        now: { time }, sleep: { time += $0 }
    ) && time >= 6.3, "晚出现的失效提示应从观察时刻重新等待倒计时")

    time = 0
    check(!NavigationRecovery.restore(
        waitForPendingRedirect: false,
        snapshot: { NavigationSnapshot(labels: []) }, goBack: { false }, dismissPanel: { false },
        now: { time }, sleep: { time += $0 }
    ), "未知或无窗口状态不能当作恢复成功")

    let id = "f00000000000000000000005"
    let urlCases: [(String, Bool)] = [
        ("https://www.xiaohongshu.com/explore/\(id)?xsec_token=TEST", true),
        ("https://www.xiaohongshu.com/discovery/item/\(id)?xsec_token=TEST", true),
        ("https://www.xiaohongshu.com/user/profile/\(id)?xsec_token=TEST", false),
        ("https://www.xiaohongshu.com/explore/f00000000000000000000006?xsec_token=TEST", false),
        ("https://www.xiaohongshu.com/explore/\(id)", false),
        ("https://example.com/explore/\(id)?xsec_token=TEST", false),
        ("https://xiaohongshu.com.example.com/explore/\(id)?xsec_token=TEST", false),
        ("https://www.xiaohongshu.com/user/profile/abc?note_id=\(id)&xsec_token=TEST", false),
        ("https://xhslink.com/a/TestOfficialShortLink", true),
        ("https://xhslink.cn/o/TestOfficialShortLink", true),
        ("https://www.xiaohongshu.com/discovery/item/discovery.\(id)?xsec_token=TEST", true),
        ("https://xhslink.com/", false)
    ]
    for (raw, expected) in urlCases {
        check(LinkTools.isShareURL(URL(string: raw)!, for: id) == expected, "分享链接校验：\(raw)")
    }
    // 回归：短链先指向正确笔记，继续访问才会跳 /explore；应在第一跳保留目标。
    let shortURL = URL(string: "https://xhslink.cn/o/TestRedirect")!
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: shortURL) // 不 resume，不访问网络。
    let response = HTTPURLResponse(url: shortURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
    let redirectCases: [(String, Bool)] = [
        ("https://www.xiaohongshu.com/discovery/item/f00000000000000000000007?xsec_token=TEST", true),
        ("https://www.xiaohongshu.com/user/profile/abc", true),
        ("https://xhslink.com/o/AnotherHop", false)
    ]
    for (raw, shouldStop) in redirectCases {
        let delegate = ShareRedirectDelegate()
        let url = URL(string: raw)!
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: url)) { nextRequest in
            called = true
            check((nextRequest == nil) == shouldStop, "短链跳转是否应继续：\(raw)")
        }
        check(called && delegate.shareDestination == (shouldStop ? url : nil), "保留真实分享目标：\(raw)")
    }
    session.invalidateAndCancel()
    let verboseURL = URL(string: "https://www.xiaohongshu.com/discovery/item/\(id)?app_version=9.45.2&xsec_token=TEST%2B%2F%3D&share_id=unused&xsec_source=other")!
    let compactURL = LinkTools.compactShareURL(verboseURL)
    let compactParts = URLComponents(url: compactURL, resolvingAgainstBaseURL: false)!
    check(compactParts.path == "/explore/\(id)" && compactParts.queryItems == [
        URLQueryItem(name: "xsec_token", value: "TEST+/="),
        URLQueryItem(name: "xsec_source", value: "app_share")
    ], "精简输出只保留两个参数并保持 token 原值")
    check(LinkTools.compactShareURL(shortURL) == shortURL, "未展开短链仍保留原链接")
    // 慢网络不能阻止先返回首页；完成通知必须同时等到网络和页面恢复。
    var deferredResolution: ((URL, Bool) -> Void)?
    var resolutionStarted = false
    var homeReturned = false
    var combinedResult: (URL, Bool, Bool)?
    let combinedDone = DispatchSemaphore(value: 0)
    ShareURLResolver.resolveWhileReturningHome(
        from: shortURL,
        resolve: { _, callback in resolutionStarted = true; deferredResolution = callback },
        returnHome: { homeReturned = resolutionStarted; return true },
        completion: { url, expanded, restored in
            combinedResult = (url, expanded, restored)
            combinedDone.signal()
        }
    )
    check(homeReturned, "网络未完成时也应立即返回首页")
    check(combinedDone.wait(timeout: .now()) == .timedOut, "网络未完成时不能提前报告结果")
    deferredResolution?(compactURL, true)
    check(combinedDone.wait(timeout: .now() + 2) == .success, "网络完成后必须通知批次")
    check(combinedResult?.0 == compactURL && combinedResult?.1 == true && combinedResult?.2 == true,
          "并行展开保留结果和首页恢复状态")

    var failedHomeCallbacks = 0
    ShareURLResolver.resolveWhileReturningHome(
        from: shortURL,
        resolve: { _, callback in deferredResolution = callback },
        returnHome: { false },
        completion: { _, _, restored in failedHomeCallbacks += 1; check(!restored, "恢复失败不能报告成功") }
    )
    check(failedHomeCallbacks == 1, "恢复失败不必继续等待网络")
    deferredResolution?(compactURL, true)
    check(failedHomeCallbacks == 1, "晚到的网络结果不能重复完成失败条目")

    let immediateDone = DispatchSemaphore(value: 0)
    var immediateHome = false
    var immediateResult = false
    ShareURLResolver.resolveWhileReturningHome(
        from: compactURL,
        resolve: { url, callback in callback(url, true) },
        returnHome: { immediateHome = true; return true },
        completion: { _, _, restored in immediateResult = immediateHome && restored; immediateDone.signal() }
    )
    check(immediateDone.wait(timeout: .now() + 2) == .success && immediateResult,
          "同步链接结果也必须等待返回首页")
    check(ShareURLResolver.remainingInterval(since: 10, now: 10.5, minimum: 2) == 1.5,
          "只等待剩余间隔")
    check(ShareURLResolver.remainingInterval(since: 10, now: 12.5, minimum: 2) == 0,
          "返回和展开已超过间隔时不能再追加等待")
    if failures.isEmpty {
        print("AUTOMATION SAFETY TESTS PASSED: recovery scenarios, page classification, \(urlCases.count) URL cases")
        return true
    }
    for failure in failures { fputs("AUTOMATION SAFETY TEST FAILED: \(failure)\n", stderr) }
    return false
}
