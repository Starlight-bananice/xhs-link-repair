using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace XhsRepair {
    public sealed class MainForm : Form {
        [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
        readonly TextBox input = new TextBox { Multiline=true, ScrollBars=ScrollBars.Vertical, Dock=DockStyle.Fill, AcceptsReturn=true };
        readonly TextBox adb = new TextBox { Width=440 };
        readonly ComboBox devices = new ComboBox { Width=300, DropDownStyle=ComboBoxStyle.DropDownList };
        readonly Button detect = new Button { Text="检测模拟器", AutoSize=true };
        readonly Button browse = new Button { Text="选择 adb.exe…", AutoSize=true };
        readonly Button start = new Button { Text="开始修复", AutoSize=true };
        readonly Button stop = new Button { Text="停止", AutoSize=true, Enabled=false };
        readonly Button export = new Button { Text="导出 Excel…", AutoSize=true };
        readonly Button open = new Button { Text="打开结果文件夹", AutoSize=true };
        readonly Label status = new Label { AutoSize=true, Text="先打开 MuMu 中已登录的小红书，再检测模拟器。", Dock=DockStyle.Fill };
        readonly DataGridView grid = new DataGridView { Dock=DockStyle.Fill, ReadOnly=true, AllowUserToAddRows=false, AllowUserToDeleteRows=false, RowHeadersVisible=false, SelectionMode=DataGridViewSelectionMode.FullRowSelect, MultiSelect=true, BackgroundColor=Color.White, AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill };
        readonly string dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XHSLinkRepairWindows");
        readonly string outDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "小红书链接修复结果");
        List<Row> rows = new List<Row>(); CancellationTokenSource cancellation; bool busy;
        string outputPath = "", smokeInput, smokeOutput;
        public MainForm(string[] args) {
            Text="小红书链接修复 · Windows / MuMu 0.5.13"; Size=new Size(1120,780); MinimumSize=new Size(850,650);
            Font=new Font("Microsoft YaHei UI",10); StartPosition=FormStartPosition.CenterScreen;
            grid.ColumnHeadersHeightSizeMode=DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
            grid.ColumnHeadersHeight=34;grid.RowTemplate.Height=30;
            input.AccessibleName="粘贴笔记链接、分享文案或笔记 ID";
            var layout = new TableLayoutPanel { Dock=DockStyle.Fill, Padding=new Padding(18), ColumnCount=1, RowCount=7 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute,52)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,42));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute,42)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,145));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute,45)); layout.RowStyles.Add(new RowStyle(SizeType.Percent,100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,52));
            layout.Controls.Add(new Label { Text="批量重新分享，恢复可用链接", Font=new Font(Font.FontFamily,18,FontStyle.Bold), AutoSize=true },0,0);
            layout.Controls.Add(Flow(new Label { Text="MuMu ADB",AutoSize=true,Padding=new Padding(0,6,0,0) },adb,browse),0,1);
            layout.Controls.Add(Flow(devices,detect,new Label { Text="仅选择一个设备；请勿同时操作小红书或复制内容。",AutoSize=true,Padding=new Padding(0,6,0,0) }),0,2);
            layout.Controls.Add(input,0,3);
            var paste = new Button { Text="粘贴",AutoSize=true }; paste.Click+=(s,e)=> { try { input.AppendText(Clipboard.GetText()+Environment.NewLine); } catch(Exception ex) { Error(ex); } };
            var import = new Button { Text="导入 TXT…",AutoSize=true }; import.Click+=(s,e)=> { using(var d=new OpenFileDialog {Filter="文本文件|*.txt|所有文件|*.*"}) if(d.ShowDialog()==DialogResult.OK) try { input.AppendText(File.ReadAllText(d.FileName)+Environment.NewLine); } catch(Exception ex) { Error(ex); } };
            var copy = new Button { Text="复制选中结果",AutoSize=true }; copy.Click+=(s,e)=> { if(busy)return; var links=grid.SelectedRows.Cast<DataGridViewRow>().OrderBy(r=>r.Index).Select(r=>rows[r.Index].Link).Where(v=>v!=""); try { string text=String.Join(Environment.NewLine,links); if(text!="")Clipboard.SetText(text); }catch(Exception ex){Error(ex);} };
            layout.Controls.Add(Flow(start,stop,paste,import,export,copy,open),0,4);
            string[] names={"原始链接 / ID","状态","修复后的链接","说明"}; foreach(string n in names)grid.Columns.Add(n,n);
            grid.Columns[1].FillWeight=28; grid.Columns[3].FillWeight=85;
            layout.Controls.Add(grid,0,5); layout.Controls.Add(status,0,6); Controls.Add(layout);
            browse.Click+=(s,e)=> { using(var d=new OpenFileDialog {Filter="MuMu ADB|adb.exe",FileName="adb.exe"}) if(d.ShowDialog()==DialogResult.OK) { adb.Text=d.FileName; devices.Items.Clear(); SaveSettings(); } };
            adb.TextChanged+=(s,e)=> { if(!busy)devices.Items.Clear(); };
            detect.Click+=async(s,e)=>await Detect(); start.Click+=async(s,e)=>await StartBatch(); stop.Click+=(s,e)=> { if(cancellation!=null)cancellation.Cancel(); status.Text="正在停止并保存结果…"; };
            export.Click+=(s,e)=> { if(busy || rows.Count==0)return; using(var d=new SaveFileDialog {Filter="Excel 工作簿|*.xlsx",FileName="小红书修复结果.xlsx"}) if(d.ShowDialog()==DialogResult.OK)try{Excel.Save(d.FileName,rows);status.Text="已导出："+d.FileName;}catch(Exception ex){Error(ex);} };
            open.Click+=(s,e)=> { Directory.CreateDirectory(outDir); Process.Start("explorer.exe", Commands.Quote(outDir)); };
            FormClosing+=(s,e)=> { if(busy) { e.Cancel=true; if(cancellation!=null)cancellation.Cancel(); status.Text="正在停止并保存，完成后请再次关闭。"; } else { SaveSettings(); } };
            input.Text="";
            try { string cfg=Path.Combine(dataDir,"adb-path.txt"); adb.Text=File.Exists(cfg)?File.ReadAllText(cfg):Repairer.FindAdb(); } catch { adb.Text=Repairer.FindAdb(); }
            if(args.Length==4 && args[0]=="--smoke") { smokeInput=args[1]; smokeOutput=args[2]; adb.Text=args[3]; }
            Shown+=async(s,e)=> { await Detect(); if(smokeInput!=null) { if(devices.Items.Count!=1) { Environment.ExitCode=2; Close(); return; } input.Text=File.ReadAllText(smokeInput); await StartBatch(); Environment.ExitCode=rows.Count>0&&rows.All(r=>r.Status=="成功")?0:1; Close(); } };
        }
        FlowLayoutPanel Flow(params Control[] controls) { var f=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false};f.Controls.AddRange(controls);return f; }
        void SaveSettings() { try {Directory.CreateDirectory(dataDir);File.WriteAllText(Path.Combine(dataDir,"adb-path.txt"),adb.Text);}catch{} }
        void Error(Exception ex) { status.Text=ex.Message; if(smokeInput==null)MessageBox.Show(this,ex.Message,"小红书链接修复",MessageBoxButtons.OK,MessageBoxIcon.Warning); }
        void SetBusy(bool value) { busy=value;input.ReadOnly=value;start.Enabled=!value;stop.Enabled=value;detect.Enabled=!value;browse.Enabled=!value;adb.ReadOnly=value;devices.Enabled=!value;export.Enabled=!value; }
        async Task Detect() {
            if(busy)return; if(!File.Exists(adb.Text)) { status.Text="未找到 MuMu ADB，请打开 MuMu 或选择其目录中的 adb.exe。";return; }
            SetBusy(true);cancellation=new CancellationTokenSource();devices.Items.Clear();string path=adb.Text;
            try { var found=await Task.Run(()=>Repairer.Discover(path,cancellation.Token));foreach(var d in found)devices.Items.Add(d);if(found.Count==1)devices.SelectedIndex=0;status.Text=found.Count==0?"未找到已安装小红书的在线设备。请确认 MuMu 已启动。":found.Count==1?"设备就绪。粘贴笔记链接、分享文案或 24 位 ID 后开始。":"检测到多个设备，请选择目标设备。";SaveSettings(); }
            catch(Exception ex){Error(ex);}finally{SetBusy(false);cancellation.Dispose();cancellation=null;}
        }
        void RefreshRow(int i) { Row r=rows[i]; grid.Rows[i].SetValues(r.Original,r.Status,r.Link,r.Detail); }
        async Task StartBatch() {
            if(busy)return;var device=devices.SelectedItem as Device;if(device==null){status.Text="请先检测并选择 MuMu 设备。";return;}
            var parsed=Links.Parse(input.Text);if(parsed.Count==0){status.Text="没有有效输入。支持官方短链、explore/discovery 笔记链接和 24 位笔记 ID。";return;}
            rows=parsed;grid.Rows.Clear();foreach(var r in rows)grid.Rows.Add(r.Original,r.Status,r.Link,r.Detail);
            outputPath=smokeOutput??Path.Combine(outDir,"小红书修复_"+DateTime.Now.ToString("yyyyMMdd_HHmmss_fff")+".xlsx");
            try{Directory.CreateDirectory(outDir);Excel.Save(outputPath,rows);}catch(Exception ex){Error(ex);return;}
            SetBusy(true);cancellation=new CancellationTokenSource();var cancel=cancellation.Token;
            var worker=new Repairer(adb.Text,device.Serial) {
                ReadClipboard=()=> (string)Invoke(new Func<string>(()=> {try{return Clipboard.GetText();}catch{return "";}})),
                ClipboardSequence=()=>GetClipboardSequenceNumber(),
                Progress=message=>BeginInvoke(new Action(()=>status.Text=message))
            };
            bool halted=false;string finish="";
            try {
                await Task.Run(()=> {
                    var done=new HashSet<string>();
                    for(int i=0;i<rows.Count;i++) {
                        if(cancel.IsCancellationRequested)break;
                        Row row=rows[i];int index=i;row.Status="处理中";Invoke(new Action(()=>RefreshRow(index)));
                        try {
                            if(row.Id=="")row.Id=Links.Note(Links.Resolve(new Uri(row.Original),cancel));
                            if(row.Id=="")throw new Exception("输入短链未指向笔记。");
                            if(!done.Add(row.Id)){row.Status="重复";row.Detail="与本批次前面的笔记相同。";}
                            else worker.Repair(row,cancel);
                        } catch(OperationCanceledException){row.Status="已停止";row.Detail="用户停止；未完成核验。";halted=true;}
                        catch(NeedsAttention ex){row.Status="需处理";row.Detail=ex.Message;halted=true;finish=ex.Message;}
                        catch(Exception ex){row.Status="失败";row.Detail=ex.Message;}
                        row.Time=DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                        Invoke(new Action(()=>RefreshRow(index)));Excel.Save(outputPath,rows);
                        if(halted)break;
                        if(i<rows.Count-1) { try{Repairer.Pause(2000,cancel);}catch(OperationCanceledException){break;} }
                    }
                });
                status.Text=(cancel.IsCancellationRequested?"已停止。":halted?"批次暂停："+finish:"完成：成功 "+rows.Count(r=>r.Status=="成功")+" / "+rows.Count+"。")+"  已保存："+outputPath;
            } catch(Exception ex){Error(new Exception("处理或自动保存失败，请点击“导出 Excel”另存当前结果。"+ex.Message));}
            await Task.Run(()=>worker.Cleanup());SetBusy(false);cancellation.Dispose();cancellation=null;
        }
    }
    static class Program {
        [STAThread] static int Main(string[] args) {
            ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
            if(args.Length>0&&args[0]=="--self-test")return Tests.Run(args.Length>1?args[1]:null);
            bool created;using(var mutex=new Mutex(true,"Local\\XHSLinkRepairWindows",out created)) {
                if(!created){MessageBox.Show("程序已在运行，请使用已打开的窗口。");return 2;}
                Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new MainForm(args));return Environment.ExitCode;
            }
        }
    }
}
