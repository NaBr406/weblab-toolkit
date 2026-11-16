using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// 极简 HTTP 抓包代理：把应用发往实验服务端（conf 或默认地址）的请求原样记录下来
// 用法: HttpSpy.exe <listenPort> <logDir> [readyFile]
//   支持明文 HTTP 转发 + CONNECT 隧道（HTTPS 也能通，只记录 CONNECT 目标）
class HttpSpy
{
    static string logDir;
    static int seq = 0;

    static void Main(string[] args)
    {
        int port = args.Length > 0 ? int.Parse(args[0]) : 8888;
        logDir = args.Length > 1 ? args[1] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "capture");
        Directory.CreateDirectory(logDir);
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Log("LISTEN on 127.0.0.1:" + port + "  log=" + logDir);
        if (args.Length > 2)
        {
            string pending = args[2] + ".tmp";
            File.WriteAllText(pending, System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            File.Move(pending, args[2]);
        }
        while (true)
        {
            TcpClient c = listener.AcceptTcpClient();
            var t = new Thread(() => Handle(c));
            t.IsBackground = true;
            t.Start();
        }
    }

    static void Log(string s)
    {
        Console.WriteLine(s);
        try { File.AppendAllText(Path.Combine(logDir, "spy.log"), DateTime.Now.ToString("HH:mm:ss.fff ") + s + Environment.NewLine, Encoding.UTF8); } catch { }
    }

    static void Handle(TcpClient client)
    {
        try
        {
            using (client)
            using (NetworkStream cs = client.GetStream())
            {
                byte[] head = ReadHeader(cs);
                if (head == null) return;
                string headText = Encoding.UTF8.GetString(head);
                string[] lines = headText.Split(new[] { "\r\n" }, StringSplitOptions.None);
                string[] reqLine = lines[0].Split(' ');
                if (reqLine.Length < 3) return;
                string method = reqLine[0], target = reqLine[1], ver = reqLine[2];

                // CONNECT：直接隧道，仅记录目标
                if (method.Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
                {
                    Log("[CONNECT] " + target);
                    string[] hp = target.Split(':');
                    using (var up = new TcpClient(hp[0], int.Parse(hp[1])))
                    {
                        byte[] est = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
                        cs.Write(est, 0, est.Length);
                        cs.Flush();
                        var t2 = new Thread(() => Pump(up.GetStream(), cs));
                        t2.IsBackground = true; t2.Start();
                        Pump(cs, up.GetStream());
                    }
                    return;
                }

                // 明文请求：target 可能是绝对 URL（代理模式）或相对路径（直连模式）
                Uri u;
                if (target.StartsWith("http", StringComparison.OrdinalIgnoreCase)) u = new Uri(target);
                else
                {
                    string host = null;
                    foreach (string l in lines) if (l.ToLower().StartsWith("host:")) host = l.Substring(5).Trim();
                    if (host == null) { Log("[ERR] no host " + headText); return; }
                    u = new Uri("http://" + host + target);
                }

                int cl = 0;
                string transferEncoding = "";
                bool expectContinue = false;
                foreach (string l in lines)
                {
                    if (l.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!int.TryParse(l.Substring(15).Trim(), out cl) || cl < 0)
                            throw new InvalidDataException("Invalid Content-Length");
                    }
                    if (l.StartsWith("transfer-encoding:", StringComparison.OrdinalIgnoreCase))
                        transferEncoding += l.Substring(18).Trim() + ",";
                    if (l.StartsWith("expect:", StringComparison.OrdinalIgnoreCase) &&
                        l.Substring(7).Trim().Equals("100-continue", StringComparison.OrdinalIgnoreCase)) expectContinue = true;
                }
                string[] codings = transferEncoding.TrimEnd(',').Split(',');
                bool chunked = codings[codings.Length - 1].Trim().Equals("chunked", StringComparison.OrdinalIgnoreCase);
                if (transferEncoding.Length > 0 && !chunked)
                    throw new InvalidDataException("Request Transfer-Encoding must end with chunked");
                if (expectContinue && (chunked || cl > 0))
                {
                    byte[] interim = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                    cs.Write(interim, 0, interim.Length);
                    cs.Flush();
                }
                byte[] body;
                byte[] wireBody;
                if (chunked) wireBody = ReadChunkedBody(cs, out body);
                else { body = cl > 0 ? ReadExactly(cs, cl) : new byte[0]; wireBody = body; }

                int id = Interlocked.Increment(ref seq);
                var sb = new StringBuilder();
                sb.AppendLine("================ #" + id + " " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " ================");
                sb.AppendLine(method + " " + u.ToString());
                foreach (string l in lines) if (l.Length > 0) sb.AppendLine("  " + l);
                if (body.Length > 0)
                {
                    string txt;
                    try { txt = Encoding.UTF8.GetString(body); } catch { txt = ""; }
                    bool printable = txt.Length > 0;
                    foreach (char ch in txt) if (ch < 9 || (ch > 13 && ch < 32)) { printable = false; break; }
                    sb.AppendLine("---- body (" + body.Length + " bytes) ----");
                    sb.AppendLine(printable ? txt : Convert.ToBase64String(body));
                }
                lock (typeof(HttpSpy))
                {
                    File.AppendAllText(Path.Combine(logDir, "requests.log"), sb.ToString(), Encoding.UTF8);
                    if (body.Length > 0) File.WriteAllBytes(Path.Combine(logDir, "#" + id + "_body.bin"), body);
                }
                Log("[REQ #" + id + "] " + method + " " + u + "  body=" + body.Length);

                // 转发
                using (var up = new TcpClient(u.Host, u.Port))
                {
                    NetworkStream us = up.GetStream();
                    var req = new StringBuilder();
                    req.Append(method + " " + u.PathAndQuery + " " + ver + "\r\n");
                    for (int li = 1; li < lines.Length; li++)
                    {
                        string l = lines[li];
                        if (l.Length == 0) continue;
                        string low = l.ToLower();
                        if (low.StartsWith("proxy-connection:")) continue;
                        if (low.StartsWith("connection:")) continue;
                        if (chunked && low.StartsWith("content-length:")) continue;
                        if (expectContinue && low.StartsWith("expect:")) continue;
                        req.Append(l + "\r\n");
                    }
                    req.Append("Connection: close\r\n\r\n");
                    byte[] rb = Encoding.UTF8.GetBytes(req.ToString());
                    us.Write(rb, 0, rb.Length);
                    if (wireBody.Length > 0) us.Write(wireBody, 0, wireBody.Length);

                    byte[] respHead = ReadHeader(us);
                    if (respHead != null)
                    {
                        string rh = Encoding.UTF8.GetString(respHead);
                        string[] rl = rh.Split(new[] { "\r\n" }, StringSplitOptions.None);
                        Log("[RESP #" + id + "] " + (rl.Length > 0 ? rl[0] : "?"));
                        lock (typeof(HttpSpy))
                            File.AppendAllText(Path.Combine(logDir, "responses.log"),
                                "#" + id + " " + (rl.Length > 0 ? rl[0] : "?") + Environment.NewLine, Encoding.UTF8);
                        cs.Write(respHead, 0, respHead.Length);
                        Pump(us, cs);
                    }
                }
            }
        }
        catch (Exception ex) { Log("[ERR] " + ex.Message); }
    }

    static void Pump(Stream from, Stream to)
    {
        try
        {
            byte[] buf = new byte[8192];
            int n;
            while ((n = from.Read(buf, 0, buf.Length)) > 0) { to.Write(buf, 0, n); to.Flush(); }
        }
        catch { }
        finally { try { to.Close(); } catch { } }
    }

    static byte[] ReadHeader(Stream s)
    {
        var ms = new MemoryStream();
        int state = 0;
        while (true)
        {
            int b = s.ReadByte();
            if (b < 0) return ms.Length > 0 ? ms.ToArray() : null;
            ms.WriteByte((byte)b);
            if (state == 0 && b == 13) state = 1;
            else if (state == 1 && b == 10) state = 2;
            else if (state == 2 && b == 13) state = 3;
            else if (state == 3 && b == 10) return ms.ToArray();
            else state = 0;
            if (ms.Length > 1024 * 256) return ms.ToArray();
        }
    }

    static byte[] ReadExactly(Stream s, int n)
    {
        byte[] b = new byte[n];
        int off = 0;
        while (off < n)
        {
            int r = s.Read(b, off, n - off);
            if (r <= 0) throw new EndOfStreamException("Incomplete request body");
            off += r;
        }
        return b;
    }

    // 保留原始分块（包括扩展和尾部字段）用于转发，日志只记录解块后的正文。
    static byte[] ReadChunkedBody(Stream s, out byte[] body)
    {
        using (var wire = new MemoryStream())
        using (var decoded = new MemoryStream())
        {
            while (true)
            {
                string line = ReadCrlfLine(s);
                byte[] sizeLine = Encoding.ASCII.GetBytes(line + "\r\n");
                wire.Write(sizeLine, 0, sizeLine.Length);
                int size;
                string hex = line.Split(';')[0].Trim();
                if (!int.TryParse(hex, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out size) || size < 0)
                    throw new InvalidDataException("Invalid chunk size");
                if (size == 0)
                {
                    do
                    {
                        line = ReadCrlfLine(s);
                        byte[] trailer = Encoding.ASCII.GetBytes(line + "\r\n");
                        wire.Write(trailer, 0, trailer.Length);
                    } while (line.Length > 0);
                    body = decoded.ToArray();
                    return wire.ToArray();
                }
                byte[] chunk = ReadExactly(s, size);
                wire.Write(chunk, 0, chunk.Length);
                decoded.Write(chunk, 0, chunk.Length);
                byte[] ending = ReadExactly(s, 2);
                if (ending[0] != 13 || ending[1] != 10) throw new InvalidDataException("Invalid chunk terminator");
                wire.Write(ending, 0, ending.Length);
            }
        }
    }

    static string ReadCrlfLine(Stream s)
    {
        using (var line = new MemoryStream())
        {
            while (line.Length <= 8192)
            {
                int b = s.ReadByte();
                if (b < 0) throw new EndOfStreamException("Incomplete chunk header");
                if (b == 13)
                {
                    if (s.ReadByte() != 10) throw new InvalidDataException("Invalid chunk header ending");
                    return Encoding.ASCII.GetString(line.ToArray());
                }
                if (b == 10) throw new InvalidDataException("Invalid chunk header ending");
                line.WriteByte((byte)b);
            }
            throw new InvalidDataException("Chunk header too long");
        }
    }
}
