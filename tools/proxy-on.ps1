# proxy-on.ps1 —— 打开本地抓包代理（只影响走系统代理的程序）
#   1) 记录当前代理设置到 proxy-state.json（关闭时原样还原，别把 Clash 的代理搞丢）
#   2) 后台启动 HttpSpy（127.0.0.1:8888，抓包存 tools\capture\）
#   3) 把当前用户的 IE/WinINET 代理指向它
# 关闭：.\proxy-off.ps1
param([ValidateRange(1, 65535)][int]$Port = 8888)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spy  = Join-Path $here 'HttpSpy.exe'
if (-not (Test-Path $spy)) {
    # 仓库只带 .cs 源码：exe 缺席时自动编一次
    $build = Join-Path $here 'build.ps1'
    if (-not (Test-Path $build)) { throw "缺 HttpSpy.exe，也找不到 build.ps1 —— 仓库不完整，请重新获取" }
    Write-Host "未找到 HttpSpy.exe，正在自动编译（首次约 3 秒）…" -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File $build
    if (-not (Test-Path $spy)) { throw "自动编译失败，没生成 HttpSpy.exe。请手动在 tools\ 下运行 build.ps1 查看报错" }
}

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$cur = Get-ItemProperty -Path $key
$stateFile = Join-Path $here 'proxy-state.json'
# 同一会话始终保留首次备份，包括改用另一个监听端口的情况。
$hadState = Test-Path -LiteralPath $stateFile
if ($hadState) {
    $originalState = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "检测到抓包会话备份，保留原代理设置。" -ForegroundColor Yellow
} else {
    $originalState = [pscustomobject]@{
        ProxyEnable   = [int]$cur.ProxyEnable
        ProxyServer   = [string]$cur.ProxyServer
        ProxyOverride = [string]$cur.ProxyOverride
    }
    $originalState | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Write-Host "已备份原代理: ProxyEnable=$($cur.ProxyEnable)  ProxyServer=$($cur.ProxyServer)"
}

$cap = Join-Path $here 'capture'
$readyFile = Join-Path $cap ('.ready-' + [guid]::NewGuid().ToString('N') + '.txt')
$spyProcess = $null
$proxyChanged = $false
try {
    New-Item -ItemType Directory -Force -Path $cap | Out-Null
    Get-Process HttpSpy -ErrorAction SilentlyContinue | Stop-Process -Force
    # ArgumentList 会被拼成命令行，路径必须显式加引号。
    $arguments = '{0} "{1}" "{2}"' -f $Port, $cap, $readyFile
    $spyProcess = Start-Process -FilePath $spy -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $ready = $false
    do {
        $spyProcess.Refresh()
        if ($spyProcess.HasExited) { throw "HttpSpy 启动失败，退出码 $($spyProcess.ExitCode)（检查端口 $Port 是否被占用）" }
        if ((Test-Path -LiteralPath $readyFile) -and
            ((Get-Content -LiteralPath $readyFile -Raw).Trim() -eq [string]$spyProcess.Id)) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw "HttpSpy 未在 5 秒内完成监听，系统代理未切换" }

    $proxyChanged = $true
    Set-ItemProperty -Path $key -Name ProxyServer   -Value "127.0.0.1:$Port"
    Set-ItemProperty -Path $key -Name ProxyOverride -Value '<local>'
    Set-ItemProperty -Path $key -Name ProxyEnable   -Value 1
} catch {
    $failure = $_
    try {
        # 改过注册表或停掉了旧会话时，恢复最初的代理。
        if ($proxyChanged -or $hadState) {
            Set-ItemProperty -Path $key -Name ProxyServer   -Value ([string]$originalState.ProxyServer)
            Set-ItemProperty -Path $key -Name ProxyOverride -Value ([string]$originalState.ProxyOverride)
            Set-ItemProperty -Path $key -Name ProxyEnable   -Value ([int]$originalState.ProxyEnable)
        }
        Remove-Item -LiteralPath $stateFile -Force
    } catch {
        Write-Warning "还原代理失败，备份保留在 $stateFile；请运行 proxy-off.ps1 重试。错误：$($_.Exception.Message)"
    }
    if ($spyProcess -and -not $spyProcess.HasExited) { $spyProcess.Kill(); $spyProcess.WaitForExit() }
    throw $failure
} finally {
    Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
}

Write-Host "抓包代理已开启: 127.0.0.1:$Port" -ForegroundColor Green
Write-Host "日志: $cap\requests.log  响应: responses.log"
Write-Host "注意: 对已经跑起来的进程不一定立刻生效 —— 先关掉实验窗口，重新进入实验室，再正常结束提交，包才会被抓到。" -ForegroundColor Yellow
Write-Host "用完务必执行: .\proxy-off.ps1（会还原成原来的 $($originalState.ProxyServer)）" -ForegroundColor Yellow
