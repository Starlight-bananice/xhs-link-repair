import Foundation

func runShortLinkInputTests() -> Bool {
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    let firstID = "f00000000000000000000001"
    let secondID = "f00000000000000000000002"
    let short = URL(string: "http://xhslink.com/o/TestInputOne")!
    let otherShort = URL(string: "https://www.xhslink.cn/a/TestInputTwo")!
    let full = "https://www.xiaohongshu.com/explore/\(secondID)?xsec_token=TEST%2B%2F%3D&xsec_source=app_share"
    let text = """
    分享文案 \(short.absoluteString)，复制后打开
    \(firstID)\t[笔记](\(full))
    [\(otherShort.absoluteString)](\(otherShort.absoluteString))&#x20;
    \(short.absoluteString) \(firstID.uppercased())
    """
    let expected: [BatchInput] = [
        .shortLink(short), .note(NoteReference(id: firstID, original: firstID)),
        .note(NoteReference(id: secondID, original: full)), .shortLink(otherShort)
    ]
    check(LinkTools.extractBatchInputs(from: text) == expected, "分享文案、表格、Markdown 混合顺序与去重")
    check(LinkTools.extractBatchInputs(from: full.replacingOccurrences(of: "&", with: "&amp;")) == [.note(NoteReference(id: secondID, original: full))], "HTML 转义保留签名参数")
    check(LinkTools.extractBatchInputs(from: "xhsdiscover://item/\(firstID)") == [.note(NoteReference(id: firstID, original: "xhsdiscover://item/\(firstID)"))], "原有客户端链接输入")
    check(LinkTools.extractBatchInputs(from: "https://www.xiaohongshu.com/user/profile/\(firstID)?note_id=\(secondID) https://example.invalid/explore/\(secondID)").isEmpty, "不把主页或其他网站 URL 中的 ID 当作笔记")
    check(LinkTools.extractBatchInputs(from: "https://xhslink.com/ http://xhslink.cn").isEmpty, "短链域名首页不是可转换输入")
    let hexShort = URL(string: "https://xhslink.com/o/\(firstID)")!
    check(LinkTools.extractBatchInputs(from: hexShort.absoluteString) == [.shortLink(hexShort)], "短码即使类似 ID 也必须先展开")
    for host in ["xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn"] {
        let url = URL(string: "https://\(host)/o/TestHost")!
        check(LinkTools.extractBatchInputs(from: url.absoluteString) == [.shortLink(url)], "官方短链域名 \(host)")
    }

    var pending: ((URL, Bool) -> Void)?
    var result: Result<NoteReference, ShortLinkInputError>?
    ShareURLResolver.noteReference(from: short, expand: { url, completion in
        check(url == short, "展开实际输入的短链")
        pending = completion
    }, completion: { result = $0 })
    check(result == nil, "网络未返回时不能假定展开成功")
    pending?(URL(string: full)!, true)
    if case .success(let note) = result {
        check(note == NoteReference(id: secondID, original: short.absoluteString), "展开只获取笔记 ID，并保留原始短链")
    } else { failures.append("异步展开成功回调") }

    let invalidTargets = [
        "https://www.xiaohongshu.com/user/profile/\(firstID)",
        "https://www.xiaohongshu.com/explore?target_note_id=\(firstID)",
        "https://example.invalid/explore/\(firstID)?xsec_token=TEST"
    ]
    for target in invalidTargets {
        result = nil
        ShareURLResolver.noteReference(from: short, expand: { _, completion in
            completion(URL(string: target)!, false)
        }, completion: { result = $0 })
        if case .failure(.notNote) = result {} else { failures.append("拒绝非笔记目标 \(target)") }
    }
    ShareURLResolver.noteReference(from: short, expand: { url, completion in
        completion(url, false)
    }, completion: { result = $0 })
    if case .failure(.expansionFailed) = result {} else { failures.append("展开失败不能将原短链标记成功或已删除") }

    if failures.isEmpty {
        print("SHORT LINK INPUT TESTS PASSED")
        return true
    }
    failures.forEach { fputs("SHORT LINK INPUT TEST FAILED: \($0)\n", stderr) }
    return false
}
