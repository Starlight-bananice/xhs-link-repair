using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Xml.Linq;

namespace XhsRepair {
    public sealed class Row {
        public string Original = "", Id = "", Status = "未处理", Link = "", Detail = "", Time = "";
    }
    public static class Links {
        static readonly Regex Tokens = new Regex(@"https?://[^\s<>""'，。；、（）()\[\]{}]+|xhsdiscover://item/[0-9a-f]{24}|(?<![0-9a-f])[0-9a-f]{24}(?![0-9a-f])", RegexOptions.IgnoreCase);
        public static bool Short(Uri u) { return new [] { "xhslink.cn", "xhslink.com", "www.xhslink.cn", "www.xhslink.com" }.Contains(u.Host.ToLowerInvariant()); }
        public static bool Official(Uri u) { return u.Host == "xiaohongshu.com" || u.Host.EndsWith(".xiaohongshu.com", StringComparison.OrdinalIgnoreCase); }
        public static string Note(Uri u) {
            if (!Official(u) || (u.Scheme != "https" && u.Scheme != "http")) return "";
            var m = Regex.Match(u.AbsolutePath, @"^/(?:explore|discovery/item)/(?:discovery\.)?([0-9a-f]{24})/?$", RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value.ToLowerInvariant() : "";
        }
        public static string Token(Uri u) {
            foreach (string part in u.Query.TrimStart('?').Split('&')) {
                var kv = part.Split(new [] {'='}, 2);
                if (kv.Length == 2 && kv[0] == "xsec_token") return Uri.UnescapeDataString(kv[1]);
            }
            return "";
        }
        public static string Compact(Uri u) {
            if (Note(u) == "" || Token(u) == "") throw new Exception("分享地址缺少笔记 ID 或 xsec_token。");
            return "https://www.xiaohongshu.com/explore/" + Note(u) + "?xsec_token=" + Uri.EscapeDataString(Token(u)) + "&xsec_source=app_share";
        }
        public static List<Row> Parse(string input) {
            var rows = new List<Row>(); var seen = new HashSet<string>();
            foreach (Match m in Tokens.Matches(WebUtility.HtmlDecode(input))) {
                string original = m.Value.TrimEnd('.', ';', '!', '?', '，', '。', '！', '？'); string id = ""; Uri u;
                if (original.StartsWith("http", StringComparison.OrdinalIgnoreCase)) {
                    if (!Uri.TryCreate(original, UriKind.Absolute, out u)) continue;
                    id = Note(u);
                    if (id == "" && !(Short(u) && u.AbsolutePath != "/")) continue;
                } else {
                    id = Regex.Match(original, "[0-9a-f]{24}", RegexOptions.IgnoreCase).Value.ToLowerInvariant();
                }
                if (seen.Add(id == "" ? original : id)) rows.Add(new Row { Original = original, Id = id });
            }
            return rows;
        }
        public static Uri Share(string text) {
            foreach (Match m in Tokens.Matches(text ?? "")) {
                Uri u;
                if (Uri.TryCreate(m.Value.TrimEnd('.', ';', '!', '。'), UriKind.Absolute, out u) &&
                    (u.Scheme == "http" || u.Scheme == "https") && (Short(u) || Note(u) != "")) return u;
            }
            return null;
        }
        // Stop at the note redirect: requesting the note itself can discard the signed URL.
        public static Uri Resolve(Uri source, CancellationToken cancel) {
            Uri current = source;
            for (int i = 0; i < 8; i++) {
                cancel.ThrowIfCancellationRequested();
                if (Note(current) != "" || Official(current)) return current;
                if (!Short(current)) throw new Exception("短链跳转到了非小红书地址，已停止。");
                var b = new UriBuilder(current) { Scheme = "https", Port = -1 };
                var req = (HttpWebRequest)WebRequest.Create(b.Uri);
                req.AllowAutoRedirect = false; req.Timeout = 12000; req.ReadWriteTimeout = 12000;
                req.UserAgent = "Mozilla/5.0 XHSLinkRepairWindows/0.1";
                using (cancel.Register(req.Abort)) {
                    try {
                        using (var response = (HttpWebResponse)req.GetResponse()) {
                            string location = response.Headers["Location"];
                            if (String.IsNullOrEmpty(location)) throw new Exception("短链没有返回笔记跳转地址。");
                            current = new Uri(current, location);
                        }
                    } catch (WebException) { cancel.ThrowIfCancellationRequested(); throw; }
                }
            }
            throw new Exception("短链跳转次数过多。");
        }
    }
    public static class Commands {
        public static string Quote(string arg) {
            return "\"" + Regex.Replace(arg, @"(\\*)""", "$1$1\\\"") .TrimEnd('\0') + new string('\\', arg.Reverse().TakeWhile(c => c == '\\').Count()) + "\"";
        }
        public static string Run(string exe, string[] args, CancellationToken cancel, int timeout = 20000) {
            var start = new ProcessStartInfo(exe, String.Join(" ", args.Select(Quote))) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            using (var p = Process.Start(start)) {
                var stdout = p.StandardOutput.ReadToEndAsync(); var stderr = p.StandardError.ReadToEndAsync();
                var watch = Stopwatch.StartNew();
                try {
                    while (!p.WaitForExit(100)) {
                        cancel.ThrowIfCancellationRequested();
                        if (watch.ElapsedMilliseconds > timeout) throw new TimeoutException("命令超时：" + Path.GetFileName(exe));
                    }
                    string output = stdout.GetAwaiter().GetResult(), error = stderr.GetAwaiter().GetResult();
                    if (p.ExitCode != 0) throw new Exception((error + " " + output).Trim());
                    return output;
                } finally { if (!p.HasExited) p.Kill(); }
            }
        }
    }
    public static class AndroidUI {
        public static IEnumerable<XElement> Nodes(XDocument doc) { return doc.Descendants("node").Where(n => (string)n.Attribute("package") == "com.xingin.xhs"); }
        public static string Attr(XElement n, string key) { return (string)n.Attribute(key) ?? ""; }
        public static int[] Center(XElement node) {
            if (node == null) throw new Exception("没有找到所需的小红书控件。");
            var m = Regex.Match(Attr(node, "bounds"), @"^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$");
            if (!m.Success) throw new Exception("控件没有有效位置。");
            int x1 = int.Parse(m.Groups[1].Value), y1 = int.Parse(m.Groups[2].Value), x2 = int.Parse(m.Groups[3].Value), y2 = int.Parse(m.Groups[4].Value);
            if (x2 <= x1 || y2 <= y1) throw new Exception("控件当前不可见。");
            return new [] { (x1 + x2) / 2, (y1 + y2) / 2 };
        }
        public static XElement Find(XDocument doc, bool copy) {
            return Nodes(doc).FirstOrDefault(n => Attr(n, "enabled") != "false" &&
                (copy ? (Attr(n, "content-desc") == "复制链接" || Attr(n, "text") == "复制链接") :
                (Attr(n, "resource-id").EndsWith("/moreOperateIV") || Attr(n, "content-desc") == "分享")) && Visible(n));
        }
        static bool Visible(XElement n) { try { Center(n); return true; } catch { return false; } }
        public static string Blocker(XDocument doc) {
            string text = String.Join(" ", Nodes(doc).Select(n => Attr(n, "text") + " " + Attr(n, "content-desc")));
            foreach (string s in new [] { "拖动滑块", "安全验证", "请完成验证", "验证码登录", "手机号登录", "登录后继续" })
                if (text.Contains(s)) return "需要在模拟器中完成登录或验证：" + s;
            return "";
        }
        public static string Unavailable(XDocument doc) {
            string text = String.Join(" ", Nodes(doc).Select(n => Attr(n, "text")));
            foreach (string s in new [] { "当前内容无法展示", "笔记已删除", "笔记不存在", "内容不存在", "当前笔记暂时无法浏览" })
                if (text.Contains(s)) return s;
            return "";
        }
    }
    public sealed class NeedsAttention : Exception { public NeedsAttention(string s) : base(s) {} }
    public sealed class Device {
        public string Serial, Name;
        public override string ToString() { return Name + "  (" + Serial + ")"; }
    }
    public sealed class Repairer {
        public readonly string Adb, Serial;
        public Func<string> ReadClipboard;
        public Func<uint> ClipboardSequence;
        public Action<string> Progress = delegate {};
        readonly string dumpPath = "/data/local/tmp/xhs-repair-" + Guid.NewGuid().ToString("N") + ".xml";
        public Repairer(string adb, string serial) { Adb = adb; Serial = serial; }
        public string Shell(CancellationToken cancel, params string[] args) { return Commands.Run(Adb, new [] { "-s", Serial, "shell" }.Concat(args).ToArray(), cancel); }
        public XDocument Dump(CancellationToken cancel) {
            Shell(cancel, "uiautomator", "dump", dumpPath);
            return XDocument.Parse(Shell(cancel, "cat", dumpPath));
        }
        void Tap(XElement node, CancellationToken cancel) {
            int[] xy = AndroidUI.Center(node);
            Shell(cancel, "input", "tap", xy[0].ToString(), xy[1].ToString());
        }
        XElement WaitControl(bool copy, CancellationToken cancel) {
            var watch = Stopwatch.StartNew();
            while (watch.Elapsed.TotalSeconds < 24) {
                cancel.ThrowIfCancellationRequested();
                var doc = Dump(cancel); string block = AndroidUI.Blocker(doc);
                if (block != "") throw new NeedsAttention(block);
                string unavailable = AndroidUI.Unavailable(doc);
                if (unavailable != "") throw new Exception("客户端提示：" + unavailable);
                var node = AndroidUI.Find(doc, copy);
                if (node != null) return node;
                Pause(500, cancel);
            }
            throw new Exception(copy ? "未找到“复制链接”。请检查分享面板或客户端版本。" : "未找到笔记分享按钮。请确认小红书已登录、笔记可访问，且没有弹窗遮挡。");
        }
        public static void Pause(int ms, CancellationToken cancel) { if (cancel.WaitHandle.WaitOne(ms)) cancel.ThrowIfCancellationRequested(); }
        public void Cleanup() { try { Shell(CancellationToken.None, "rm", "-f", dumpPath); } catch {} }
        public void Repair(Row row, CancellationToken cancel) {
            row.Link = ""; row.Detail = "";
            if (row.Id == "") {
                Progress("展开输入短链…"); row.Id = Links.Note(Links.Resolve(new Uri(row.Original), cancel));
                if (row.Id == "") throw new Exception("输入短链未指向笔记。");
            }
            Progress("打开笔记 " + row.Id + "…");
            string result = Shell(cancel, "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "xhsdiscover://item/" + row.Id, "-p", "com.xingin.xhs");
            if (result.Contains("Error") || result.Contains("Exception")) throw new Exception("小红书打开失败：" + result);
            Pause(1200, cancel);
            Tap(WaitControl(false, cancel), cancel);
            XElement copy = WaitControl(true, cancel);
            uint before = ClipboardSequence();
            Tap(copy, cancel);
            Progress("等待 MuMu 同步分享链接到剪贴板…");
            Uri share = null; var watch = Stopwatch.StartNew();
            while (watch.Elapsed.TotalSeconds < 10) {
                cancel.ThrowIfCancellationRequested();
                if (ClipboardSequence() != before) { share = Links.Share(ReadClipboard()); if (share != null) break; }
                Pause(200, cancel);
            }
            if (share == null) throw new NeedsAttention("未收到新复制的分享链接。请检查 MuMu 剪贴板同步，转换时不要复制其他内容。");
            row.Link = share.AbsoluteUri;
            Progress("核对分享地址…");
            Uri resolved;
            try { resolved = Links.Resolve(share, cancel); }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { row.Status = "待核验"; row.Detail = "已复制分享链接，但展开失败：" + ex.Message; return; }
            if (Links.Note(resolved) != row.Id) { row.Link = ""; throw new NeedsAttention("复制链接的笔记 ID 与目标不符。已丢弃链接并停止批次，请勿同时操作小红书。"); }
            if (Links.Token(resolved) == "") { row.Status = "待核验"; row.Detail = "分享地址缺少 xsec_token。"; return; }
            row.Link = Links.Compact(resolved); row.Status = "成功";
            row.Detail = "客户端重新分享；笔记 ID 和 xsec_token 已核验，未测试浏览器展示。";
        }
        public static string FindAdb() {
            foreach (var p in Process.GetProcesses().Where(p => p.ProcessName == "MuMuNxMain")) {
                try { string f = Path.Combine(Path.GetDirectoryName(p.MainModule.FileName), "adb.exe"); if (File.Exists(f)) return f; } catch {} finally { p.Dispose(); }
            }
            foreach (var drive in DriveInfo.GetDrives().Where(d => d.IsReady)) {
                foreach (string rel in new [] { @"MuMuPlayer\nx_main\adb.exe", @"Program Files\Netease\MuMuPlayer-12.0\shell\adb.exe" }) {
                    string f = Path.Combine(drive.RootDirectory.FullName, rel); if (File.Exists(f)) return f;
                }
            }
            return "";
        }
        public static List<Device> Discover(string adb, CancellationToken cancel) {
            var mumuSerials = new HashSet<string>();
            string manager = Path.Combine(Path.GetDirectoryName(adb), "MuMuManager.exe");
            if (File.Exists(manager)) {
                string info = Commands.Run(manager, new [] { "info", "-v", "all" }, cancel);
                foreach (Match m in Regex.Matches(info, "\"adb_port\"\\s*:\\s*(\\d+)")) {
                    int port = int.Parse(m.Groups[1].Value);
                    if (port > 0 && port < 65536) {
                        string target = "127.0.0.1:" + port;
                        mumuSerials.Add(target);
                        Commands.Run(adb, new [] { "connect", target }, cancel);
                    }
                }
            }
            var list = new List<Device>(); string devices = Commands.Run(adb, new [] { "devices" }, cancel);
            foreach (Match m in Regex.Matches(devices, @"(?m)^([^\s]+)\s+device\s*$")) {
                string serial = m.Groups[1].Value;
                // MuMu can expose the same instance both as emulator-5554 and a TCP device.
                if (mumuSerials.Count > 0 && !mumuSerials.Contains(serial)) continue;
                string packages = Commands.Run(adb, new [] { "-s", serial, "shell", "pm", "list", "packages", "com.xingin.xhs" }, cancel);
                if (packages.Split('\n').Any(s => s.Trim() == "package:com.xingin.xhs")) list.Add(new Device { Serial = serial, Name = "已安装小红书" });
            }
            return list;
        }
    }
    public static class Excel {
        static readonly XNamespace Ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
        public static void Save(string path, IList<Row> rows) {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                using (var zip = ZipFile.Open(temp, ZipArchiveMode.Create)) {
                    Add(zip, "[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>");
                    Add(zip, "_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
                    Add(zip, "xl/workbook.xml", "<workbook xmlns=\"" + Ns + "\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"修复结果\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>");
                    Add(zip, "xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>");
                    var data = new XElement(Ns + "sheetData");
                    var all = new List<string[]> { new [] { "序号", "原始链接", "笔记 ID", "状态", "新链接", "说明", "处理时间" } };
                    for (int i = 0; i < rows.Count; i++) { var r = rows[i]; all.Add(new [] { (i+1).ToString(), r.Original, r.Id, r.Status, r.Link, r.Detail, r.Time }); }
                    for (int i = 0; i < all.Count; i++) {
                        var line = new XElement(Ns + "row", new XAttribute("r", i+1));
                        for (int j = 0; j < all[i].Length; j++) line.Add(new XElement(Ns + "c", new XAttribute("r", ((char)('A'+j)).ToString()+(i+1)), new XAttribute("t", "inlineStr"), new XElement(Ns+"is", new XElement(Ns+"t", new XAttribute(XNamespace.Xml+"space", "preserve"), Clean(all[i][j])))));
                        data.Add(line);
                    }
                    var sheet = new XElement(Ns + "worksheet", new XElement(Ns+"sheetViews", new XElement(Ns+"sheetView", new XAttribute("workbookViewId", 0), new XElement(Ns+"pane", new XAttribute("ySplit", 1), new XAttribute("topLeftCell", "A2"), new XAttribute("state", "frozen")))), new XElement(Ns+"cols", Enumerable.Range(1,7).Select(i=> new XElement(Ns+"col",new XAttribute("min",i),new XAttribute("max",i),new XAttribute("width",i==1?8:(i==2||i==5||i==6?55:24)),new XAttribute("customWidth",1)))), data, new XElement(Ns+"autoFilter",new XAttribute("ref","A1:G"+all.Count)));
                    Add(zip, "xl/worksheets/sheet1.xml", sheet.ToString());
                }
                if (File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        static string Clean(string s) { return new string((s??"").Where(c=>System.Xml.XmlConvert.IsXmlChar(c)).Take(32767).ToArray()); }
        static void Add(ZipArchive zip, string name, string content) { using (var w = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false))) w.Write(content); }
    }
}
