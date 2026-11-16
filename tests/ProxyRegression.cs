using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

class ProxyRegression
{
    static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    static string ReadHead(NetworkStream stream)
    {
        using (var head = new MemoryStream())
        {
            while (head.Length < 65536)
            {
                int b = stream.ReadByte();
                if (b < 0) throw new EndOfStreamException("Response header incomplete");
                head.WriteByte((byte)b);
                int n = (int)head.Length;
                byte[] data = head.GetBuffer();
                if (n >= 4 && data[n-4] == 13 && data[n-3] == 10 && data[n-2] == 13 && data[n-1] == 10)
                    return Encoding.ASCII.GetString(head.ToArray());
            }
            throw new Exception("Header too long");
        }
    }

    static byte[] ReadExactly(NetworkStream stream, int count)
    {
        byte[] data = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = stream.Read(data, offset, count - offset);
            if (n == 0) throw new EndOfStreamException("Request or response incomplete");
            offset += n;
        }
        return data;
    }

    static void EqualBytes(byte[] actual, byte[] expected, string message)
    {
        if (actual.Length != expected.Length) throw new Exception(message + " length");
        for (int i = 0; i < actual.Length; i++)
            if (actual[i] != expected[i]) throw new Exception(message + " at byte " + i);
    }

    static void Main(string[] args)
    {
        try
        {
            int port = FreePort();
            var start = new ProcessStartInfo(args[0], port + " \"" + args[1] + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (var process = Process.Start(start))
            {
                try
                {
                    bool ready = false;
                    for (int i = 0; i < 100; i++)
                    {
                        if (process.HasExited) throw new Exception("Proxy exited at startup");
                        try { using (var c = new TcpClient("127.0.0.1", port)) { } ready = true; break; }
                        catch (SocketException) { Thread.Sleep(30); }
                    }
                    if (!ready) throw new Exception("Proxy readiness timeout");
                    byte[] simple = Encoding.ASCII.GetBytes("test");
                    Probe(port, args[1], 1, "Content-Length", simple, simple, false, false, false);
                    byte[] text = Encoding.ASCII.GetBytes("Wikipedia");
                    byte[] chunks = Encoding.ASCII.GetBytes("4;kind=text\r\nWiki\r\n5\r\npedia\r\n0;done=yes\r\nX-Checksum: ok\r\n\r\n");
                    Probe(port, args[1], 2, "chunk extensions and trailers", text, chunks, true, false, true);
                    Probe(port, args[1], 3, "empty chunked", new byte[0], Encoding.ASCII.GetBytes("0\r\n\r\n"), true, false, false);
                    Probe(port, args[1], 4, "Expect 100-continue", simple, Encoding.ASCII.GetBytes("4\r\ntest\r\n0\r\n\r\n"), true, true, false);
                    byte[] binary = new byte[] { 0, 255, 13, 10 };
                    byte[] binaryChunks = new byte[] { 52, 13, 10, 0, 255, 13, 10, 13, 10, 48, 13, 10, 13, 10 };
                    Probe(port, args[1], 5, "binary chunked", binary, binaryChunks, true, false, false);
                    Reject(port, "invalid chunk size", "Transfer-Encoding: chunked", "Z\r\n");
                    Reject(port, "invalid chunk terminator", "Transfer-Encoding: chunked", "1\r\naXX");
                    Reject(port, "truncated body", "Content-Length: 4", "te");
                    Console.WriteLine("PASS E5: fixed-length, chunked, trailers, binary capture and malformed requests");
                }
                finally
                {
                    if (!process.HasExited) process.Kill();
                    process.WaitForExit();
                }
            }
        }
        catch (Exception error)
        {
            Console.WriteLine(error);
            Environment.Exit(1);
        }
    }

    static void Probe(int proxyPort, string logDirectory, int id, string name, byte[] body, byte[] wireBody, bool chunked, bool expect, bool conflictingLength)
    {
        var origin = new TcpListener(IPAddress.Loopback, 0);
        origin.Start();
        int port = ((IPEndPoint)origin.LocalEndpoint).Port;
        try
        {
            using (var client = new TcpClient("127.0.0.1", proxyPort))
            {
                var cs = client.GetStream();
                cs.ReadTimeout = 3000;
                string header = "POST http://127.0.0.1:" + port + "/probe HTTP/1.1\r\nHost: 127.0.0.1:" + port + "\r\n";
                header += chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: " + body.Length + "\r\n";
                if (conflictingLength) header += "Content-Length: 999\r\n";
                if (expect) header += "Expect: 100-continue\r\n";
                header += "Connection: close\r\n\r\n";
                byte[] requestHead = Encoding.ASCII.GetBytes(header);
                cs.Write(requestHead, 0, requestHead.Length);
                if (expect)
                {
                    if (!ReadHead(cs).StartsWith("HTTP/1.1 100 ")) throw new Exception("Missing interim response");
                }
                // One-byte writes exercise split chunk boundaries.
                foreach (byte b in wireBody) cs.WriteByte(b);
                DateTime deadline = DateTime.UtcNow.AddSeconds(3);
                while (!origin.Pending() && DateTime.UtcNow < deadline) Thread.Sleep(10);
                if (!origin.Pending()) throw new Exception(name + ": upstream connection missing");
                using (var upstream = origin.AcceptTcpClient())
                {
                    var us = upstream.GetStream();
                    us.ReadTimeout = 3000;
                    string forwardedHead = ReadHead(us);
                    if (!forwardedHead.StartsWith("POST /probe HTTP/1.1\r\n")) throw new Exception("Wrong request target");
                    if (chunked && !forwardedHead.Contains("Transfer-Encoding: chunked\r\n")) throw new Exception("Missing transfer encoding");
                    if (chunked && forwardedHead.Contains("Content-Length:")) throw new Exception("Ambiguous body framing");
                    if (expect && forwardedHead.Contains("Expect:")) throw new Exception("Handled expectation forwarded");
                    EqualBytes(ReadExactly(us, wireBody.Length), wireBody, name + ": wire body");
                    byte[] response = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK");
                    us.Write(response, 0, response.Length);
                }
                if (!ReadHead(cs).StartsWith("HTTP/1.1 200 ")) throw new Exception(name + ": final response missing");
                EqualBytes(ReadExactly(cs, 2), Encoding.ASCII.GetBytes("OK"), name + ": response body");
                if (body.Length > 0)
                    EqualBytes(File.ReadAllBytes(Path.Combine(logDirectory, "#" + id + "_body.bin")), body, name + ": captured decoded body");
                Console.WriteLine("PASS HTTP: " + name + ", forwarded=" + wireBody.Length + ", decoded=" + body.Length);
            }
        }
        finally { origin.Stop(); }
    }

    static void Reject(int proxyPort, string name, string framing, string body)
    {
        var origin = new TcpListener(IPAddress.Loopback, 0);
        origin.Start();
        int port = ((IPEndPoint)origin.LocalEndpoint).Port;
        try
        {
            using (var client = new TcpClient("127.0.0.1", proxyPort))
            {
                var stream = client.GetStream();
                stream.ReadTimeout = 3000;
                byte[] request = Encoding.ASCII.GetBytes("POST http://127.0.0.1:" + port + "/probe HTTP/1.1\r\nHost: 127.0.0.1:" + port + "\r\n" + framing + "\r\n\r\n" + body);
                stream.Write(request, 0, request.Length);
                client.Client.Shutdown(SocketShutdown.Send);
                try
                {
                    if (stream.ReadByte() >= 0) throw new Exception(name + ": malformed request unexpectedly accepted");
                }
                catch (IOException error)
                {
                    var socketError = error.InnerException as SocketException;
                    if (socketError != null && socketError.SocketErrorCode == SocketError.TimedOut) throw;
                }
                if (origin.Pending()) throw new Exception(name + ": malformed request forwarded");
                Console.WriteLine("PASS HTTP rejection: " + name);
            }
        }
        finally { origin.Stop(); }
    }
}
