using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

// WebLab / USTCORi.SimExp 实验数据包工具
//   LabDecrypt dec   <ExamConfig.bin> [out.xml]     解密试卷 / 提交包
//   LabDecrypt enc   <ExamConfig.xml> [out.bin]     加密
//   LabDecrypt key   <serialnumber>                 生成服务端签名 Sec.GenerateKey
//   LabDecrypt cmd   "<Main.exe 命令行参数>"          还原实验启动参数（10 段）
class LabDecrypt
{
    const string Token = "haohaoxuexi,tiantianxiangshang.";
    const string DllName = "USTCORi.SimExp.Instruments.Component.dll";

    static string FindComponent()
    {
        var cands = new System.Collections.Generic.List<string>();
        string here = AppDomain.CurrentDomain.BaseDirectory;
        cands.Add(Path.Combine(here, DllName));
        cands.Add(Path.Combine(Directory.GetCurrentDirectory(), DllName));

        // 没随包携带时，从实验客户端的解包目录里找（%TEMP%\lab\<编号>\ 或 %TEMP%\lab\）
        string tmp = Environment.GetEnvironmentVariable("TEMP");
        if (tmp != null)
        {
            try
            {
                var dirs = Directory.GetDirectories(Path.Combine(tmp, "lab"))
                                    .Select(d => new DirectoryInfo(d))
                                    .OrderByDescending(d => d.LastWriteTime);
                foreach (var d in dirs) cands.Add(Path.Combine(d.FullName, DllName));
            }
            catch { }
            cands.Add(Path.Combine(tmp, "lab", DllName));
        }

        foreach (string c in cands)
            if (File.Exists(c)) return c;

        Console.WriteLine("找不到 " + DllName);
        Console.WriteLine("任选一种方式解决：");
        Console.WriteLine("  1) 把客户端里的该文件复制到本目录；");
        Console.WriteLine("  2) 先启动一次任意实验（客户端会解包到 %TEMP%\\lab\\），再运行本工具。");
        return null;
    }

    static bool IsAscii(string s)
    {
        foreach (char c in s) if (c > 127) return false;
        return true;
    }

    // 把 dll 读成字节写到纯 ASCII 的本地临时目录，再从副本加载。
    //
    // 为什么要绕这一圈（2026-11-13 实测）：
    //   Assembly.LoadFrom 走的是内存映射（memory-mapped image）。若 dll 所在的
    //   分区上装了文件透明加密 / 文档防泄漏驱动（本机 D: 就是这种情况），
    //   映射路径拿到的是密文或读不完整，表现为
    //     FileLoadException: 不支持操作 (HRESULT: 0x80131515)
    //   或更隐蔽的 InvalidProgramException（JIT 时才发现 IL 是坏的，进程直接退出，
    //   控制台只留一句"由于 Exception.ToString() 失败，因此无法打印异常字符串"）。
    //   而普通 ReadFile 路径是能拿到明文的，所以"读字节 + 写副本 + 从副本 LoadFrom"可解。
    //   同一份 dll 从 C:\ 加载一直正常、从 D:\ 加载必崩，就是这一条。
    static string ShadowCopy(string src)
    {
        string err = "";
        try
        {
            string name = "comp_" + new FileInfo(src).Length + "_" +
                          new FileInfo(src).LastWriteTimeUtc.Ticks + ".dll";
            var roots = new string[] {
                Path.Combine(Path.GetTempPath(), "labdec_comp"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "labdec_comp"),
                @"C:\Windows\Temp\labdec_comp"
            };
            foreach (string root in roots)
            {
                if (!IsAscii(root)) { err += "[非ASCII跳过:" + root + "]"; continue; }   // 用户名是中文时 TEMP 就不是 ASCII 了
                try
                {
                    Directory.CreateDirectory(root);
                    string dst = Path.Combine(root, name);
                    if (!File.Exists(dst) || new FileInfo(dst).Length != new FileInfo(src).Length)
                        File.WriteAllBytes(dst, File.ReadAllBytes(src));
                    return dst;
                }
                catch (Exception e2) { err += "[" + root + " => " + e2.GetType().Name + ": " + e2.Message + "]"; }
            }
        }
        catch (Exception e) { err += "[outer " + e.GetType().Name + ": " + e.Message + "]"; }
        if (err.Length > 0) Console.WriteLine("SHADOWCOPY-FAIL " + err);
        return src;   // 全都失败就退回原路径，行为与旧版一致
    }

    static Assembly Comp()
    {
        string p = FindComponent();
        if (p == null) Environment.Exit(2);
        string firstErr = null;

        // 首选：读字节后直接 Assembly.Load(byte[])，全程不落盘、不走 memory-map。
        // 这条路绕开了两类环境问题：
        //   1) 分区上有文件透明加密 / DLP 过滤驱动时，LoadFrom 的内存映射会拿到坏数据，
        //      报 FileLoadException 0x80131515 或 JIT 阶段的 InvalidProgramException；
        //   2) 程序本身放在"不受信任位置"（如某些 D 盘 / 非系统卷）时，
        //      .NET 会把它降权，连往 %TEMP% 建目录都会 UnauthorizedAccessException。
        try
        {
            return Assembly.Load(File.ReadAllBytes(p));
        }
        catch (Exception e0) { firstErr = e0.GetType().Name + " - " + e0.Message; }

        // 退路：影子复制到可写的纯 ASCII 目录再 LoadFrom（老系统上 byte[] 加载可能不可用）
        string p2 = ShadowCopy(p);
        try
        {
            return Assembly.LoadFrom(p2);
        }
        catch (Exception e)
        {
            Console.WriteLine("加载 " + DllName + " 失败：" + e.GetType().Name + " - " + e.Message);
            if (firstErr != null) Console.WriteLine("  内存加载同样失败：" + firstErr);
            Console.WriteLine("  源文件  : " + p);
            Console.WriteLine("  副本路径: " + p2);
            Console.WriteLine("若提示 HRESULT 0x80131515，说明该路径被判定为不受信任，");
            Console.WriteLine("把 dll 和本程序一起挪到 C:\\ 下的纯英文目录再试。");
            Environment.Exit(3);
            return null;
        }
    }

    static object InvokeStatic(Assembly asm, string typeName, string method, Type argType, object arg)
    {
        Type t = null;
        foreach (Type x in asm.GetTypes())
            if (x.FullName == typeName || x.Name == typeName) { t = x; break; }
        if (t == null) throw new Exception("type not found: " + typeName);
        foreach (MethodInfo mi in t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static))
        {
            ParameterInfo[] ps = mi.GetParameters();
            if (mi.Name == method && ps.Length == 1 && ps[0].ParameterType == argType)
                return mi.Invoke(null, new object[] { arg });
        }
        throw new Exception("method not found: " + method + "(" + argType.Name + ")");
    }

    static byte[] InvokeJson(Assembly asm, string method, byte[] bytes)
    {
        Type t = null;
        foreach (Type x in asm.GetTypes())
            if (x.Name == (method == "Read" ? "JsonReader" : "JsonWriter")) { t = x; break; }
        if (t == null) throw new Exception("type not found: " + method);
        foreach (MethodInfo mi in t.GetMethods(BindingFlags.Public | BindingFlags.Static))
        {
            ParameterInfo[] ps = mi.GetParameters();
            if (mi.Name == method && ps.Length == 2 && ps[0].ParameterType == typeof(byte[]))
                return (byte[])mi.Invoke(null, new object[] { bytes, Token });
        }
        throw new Exception("method not found: " + method);
    }

    static void Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.WriteLine("usage:");
            Console.WriteLine("  LabDecrypt dec <ExamConfig.bin> [out.xml]");
            Console.WriteLine("  LabDecrypt enc <ExamConfig.xml> [out.bin]");
            Console.WriteLine("  LabDecrypt key <serialnumber>");
            Console.WriteLine("  LabDecrypt cmd \"<Main.exe 命令行参数>\"");
            return;
        }
        try
        {
            Run(args);
        }
        catch (Exception e)
        {
            // 混淆过的 Component.dll 抛 TargetInvocationException 时，默认的未处理异常
            // 输出会退化成一堆乱码（连异常类型都打不出来），这里手动拆包打印。
            Exception ie = e;
            int depth = 0;
            while (ie != null && depth < 5)
            {
                Console.WriteLine("ERROR: " + ie.GetType().FullName + " - " + ie.Message);
                ie = ie.InnerException;
                depth++;
            }
            Environment.Exit(4);
        }
    }

    static void Run(string[] args)
    {
        string mode = args[0];
        Assembly asm = Comp();

        if (mode == "key")
        {
            Console.WriteLine(InvokeStatic(asm, "Sec", "GenerateKey", typeof(string), args[1]));
            return;
        }

        if (mode == "cmd")
        {
            string raw = (string)InvokeStatic(asm, "XlsxFileReader", "Read", typeof(string), args[1]);
            if (raw == null) { Console.WriteLine("解密失败（参数不是 XlsxFileWriter.Write 的产物）"); return; }
            string[] f = raw.Split('|');
            string[] names = { "hWnd", "tag", "paper", "userid", "LabID", "LabName", "RecordID", "md5Key", "time", "ServerIP", "Language" };
            for (int i = 0; i < f.Length; i++)
            {
                string val;
                try { val = Encoding.UTF8.GetString(Convert.FromBase64String(f[i])); }
                catch { val = "<非base64>" + f[i]; }
                Console.WriteLine(string.Format("{0,-9} = {1}", i < names.Length ? names[i] : ("#" + i), val));
            }
            return;
        }

        string path = args[1];
        byte[] bytes = File.ReadAllBytes(path);
        if (mode == "dec")
        {
            byte[] outb = InvokeJson(asm, "Read", bytes);
            string dest = args.Length > 2 ? args[2] : path + ".xml";
            File.WriteAllText(dest, Encoding.UTF8.GetString(outb), new UTF8Encoding(false));
            Console.WriteLine("decrypted " + outb.Length + " bytes -> " + dest);
        }
        else
        {
            byte[] outb = InvokeJson(asm, "Write", bytes);
            string dest = args.Length > 2 ? args[2] : path + ".bin";
            File.WriteAllBytes(dest, outb);
            Console.WriteLine("encrypted " + outb.Length + " bytes -> " + dest);
        }
    }
}
