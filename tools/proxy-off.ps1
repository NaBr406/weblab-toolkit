# proxy-off.ps1 —— 关闭抓包代理，并把系统代理还原成开启前的样子
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$stateFile = Join-Path $here 'proxy-state.json'

Get-Process HttpSpy -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $stateFile) {
    $s = Get-Content $stateFile -Raw | ConvertFrom-Json
    Set-ItemProperty -Path $key -Name ProxyServer   -Value $s.ProxyServer
    Set-ItemProperty -Path $key -Name ProxyOverride -Value $s.ProxyOverride
    Set-ItemProperty -Path $key -Name ProxyEnable   -Value ([int]$s.ProxyEnable)
    Remove-Item $stateFile -Force
    $now = Get-ItemProperty -Path $key
    Write-Host "已还原系统代理: ProxyEnable=$($now.ProxyEnable)  ProxyServer=$($now.ProxyServer)" -ForegroundColor Green
} else {
    Write-Host "没有 proxy-state.json，未改动系统代理（只停了 HttpSpy）。" -ForegroundColor Yellow
    (Get-ItemProperty -Path $key) | Select-Object ProxyEnable, ProxyServer | Format-List
}

$cap = Join-Path $here 'capture'
if (Test-Path "$cap\requests.log") {
    $n = (Select-String -Path "$cap\requests.log" -Pattern '^================ #' -AllMatches).Count
    Write-Host "抓到的请求条数: $n"
    Write-Host "日志目录: $cap"
}
