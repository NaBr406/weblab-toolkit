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
# /optimize 的取值和仓库里已提交的 exe 对齐，方便比对重新构建是否成功：
#   HttpSpy.exe    = 不优化（10240 字节）
#   LabDecrypt.exe = 优化（9216 字节）
Write-Host "[1/2] HttpSpy.exe"
& $csc /nologo /platform:anycpu /codepage:65001 /target:exe /out:"$here\HttpSpy.exe" "$here\HttpSpy.cs"
if ($LASTEXITCODE -ne 0) { throw "HttpSpy 编译失败" }

Write-Host "[2/2] LabDecrypt.exe"
$dll = Join-Path $here 'USTCORi.SimExp.Instruments.Component.dll'
if (Test-Path $dll) {
    & $csc /nologo /platform:anycpu /codepage:65001 /optimize+ /target:exe /out:"$here\LabDecrypt.exe" /r:"$dll" "$here\LabDecrypt.cs"
} else {
    # 没带 dll 也能编译（运行时再找）
    Write-Host "  未找到 Component.dll，按无引用方式编译（运行时去 exe 同目录 / %TEMP%\lab\ 找）"
    & $csc /nologo /platform:anycpu /codepage:65001 /optimize+ /target:exe /out:"$here\LabDecrypt.exe" "$here\LabDecrypt.cs"
}
if ($LASTEXITCODE -ne 0) { throw "LabDecrypt 编译失败" }

Write-Host "完成。两个 exe 已更新（与原产物仅 PE 时间戳 / MVID 不同，功能等价）。" -ForegroundColor Green
