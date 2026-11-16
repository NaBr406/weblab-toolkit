# build.ps1 —— 用系统自带的 .NET Framework 编译器重新构建两个工具
# 需要：Windows 10/11 自带的 csc.exe（无需安装 SDK）
#
# 注意：本文件必须存成 UTF-8 带 BOM。Windows PowerShell 5.1 会把无 BOM 的
# .ps1 当 ANSI(GBK) 读，中文注释会被拆成非法字节，直接报
#   "Unexpected token '浣跨敤缂栬瘧鍣?'" / "Missing closing '}'"
# 仓库里的其它 .ps1 都是带 BOM 的，编辑时别把 BOM 弄丢。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$csc = $null
foreach ($root in 'Framework64', 'Framework') {
    foreach ($v in 'v4.0.30319', 'v3.5', 'v2.0.50727') {
        $p = Join-Path $env:WINDIR "Microsoft.NET\$root\$v\csc.exe"
        if (Test-Path $p) { $csc = $p; break }
    }
    if ($csc) { break }
}
if (-not $csc) { throw "找不到 csc.exe（需要 .NET Framework 4.x，Win10/11 自带）" }

Write-Host "使用编译器: $csc"

# 两个 exe 都按 anycpu 编：.NET 4 CLR 在 64 位系统上会跑成 64 位进程，
# 这是 Component.dll 唯一稳定的宿主（32 位宿主加载它会 AccessViolation）。
# /optimize 的取值保持一致；产物大小随源码变化：
#   HttpSpy.exe    = 不优化
#   LabDecrypt.exe = 优化（含内存加载 / 低完整性适配）
Write-Host "[1/2] HttpSpy.exe"
& $csc /nologo /platform:anycpu /codepage:65001 /target:exe /out:"$here\HttpSpy.exe" "$here\HttpSpy.cs"
if ($LASTEXITCODE -ne 0) { throw "HttpSpy 编译失败" }

Write-Host "[2/2] LabDecrypt.exe"
# 编译期不需要引用 Component.dll：LabDecrypt.cs 全部通过反射调用它，
# dll 只在运行时查找（exe 同目录 / 当前工作目录 / %TEMP%\lab\<编号>\）。
& $csc /nologo /platform:anycpu /codepage:65001 /optimize+ /target:exe /out:"$here\LabDecrypt.exe" "$here\LabDecrypt.cs"
if ($LASTEXITCODE -ne 0) { throw "LabDecrypt 编译失败" }

Write-Host "完成。两个 exe 已按当前源码重新生成。" -ForegroundColor Green
