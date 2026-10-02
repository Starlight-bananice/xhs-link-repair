using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Xml.Linq;
namespace XhsRepair {
    static class Tests {
        static void Check(bool value,string message) { if(!value)throw new Exception(message); }
        public static int Run(string report) {
            string tmp=Path.Combine(Path.GetTempPath(),"xhs-repair-test-"+Guid.NewGuid().ToString("N")+".xlsx");
            try {
                string id="0123456789abcdef01234567";
                var rows=Links.Parse("https://www.xiaohongshu.com/user/profile/"+id+" https://evil.example/explore/"+id+" https://www.xiaohongshu.com/explore/"+id+"?xsec_token=abc "+id+" http://xhslink.cn/o/demo");
                Check(rows.Count==2 && rows[0].Id==id && rows[1].Id=="","input filtering/dedup/order");
                Check(Links.Note(new Uri("https://xiaohongshu.com.evil.test/explore/"+id))=="","host validation");
                string compact=Links.Compact(new Uri("https://www.xiaohongshu.com/discovery/item/"+id+"?xsec_token=a%2Bb%2F%3D&tracking=1"));
                Check(compact.Contains("a%2Bb%2F%3D")&&!compact.Contains("tracking"),"token encoding");
                Check(Links.Token(new Uri("https://www.xiaohongshu.com/explore/"+id+"?xsec_token=a+b"))=="a+b","literal plus preserved");
                Check(Links.Share("https://evil.test/o/abc")==null,"clipboard host filtering");
                var ui=XDocument.Parse("<hierarchy><node package='other' content-desc='复制链接' bounds='[1,1][2,2]'/><node package='com.xingin.xhs' content-desc='复制链接' bounds='[100,200][200,300]' enabled='true'/></hierarchy>");
                Check(AndroidUI.Center(AndroidUI.Find(ui,true)).SequenceEqual(new[]{150,250}),"UI package and center");
                Check(AndroidUI.Find(XDocument.Parse("<hierarchy><node package='com.xingin.xhs' content-desc='复制链接' bounds='[0,0][0,0]'/></hierarchy>"),true)==null,"hidden controls rejected");
                Check(AndroidUI.Blocker(XDocument.Parse("<hierarchy><node package='com.xingin.xhs' text='请完成验证'/></hierarchy>"))!="","verification stop");
                rows[0].Detail="=HYPERLINK(\"bad\")";Excel.Save(tmp,rows);Excel.Save(tmp,rows);
                using(var zip=ZipFile.OpenRead(tmp)){using(var reader=new StreamReader(zip.GetEntry("xl/worksheets/sheet1.xml").Open())){var doc=XDocument.Parse(reader.ReadToEnd());Check(!doc.Descendants().Any(n=>n.Name.LocalName=="f"),"no spreadsheet formulas");Check(doc.Descendants().Count(n=>n.Name.LocalName=="row")==3,"all rows exported");}}
                if(report!=null)File.WriteAllText(report,"PASS: input, deduplication, host/clipboard validation, token preservation, Android controls, verification stop, XLSX export/replacement.\r\n");return 0;
            } catch(Exception ex){if(report!=null)File.WriteAllText(report,"FAIL: "+ex);return 1;}finally{if(File.Exists(tmp))File.Delete(tmp);}
        }
    }
}
