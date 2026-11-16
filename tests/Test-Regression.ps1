param([string]$SourceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('weblab regression ' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot 'tools'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$global:WeblabTestProcesses = New-Object System.Collections.ArrayList
$global:WeblabTestRequests = New-Object System.Collections.ArrayList
$global:WeblabTestRegistry = [pscustomobject]@{
    ProxyEnable = 1; ProxyServer = '127.0.0.1:7890'; ProxyOverride = 'original'
}
$global:WeblabTestFailOverride = $false
$global:WeblabTestWrites = 0

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message expected=[$Expected] actual=[$Actual]" }
}
function Get-FreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([Parameter(Position=0)]$Uri, $Method, $Body, $ContentType, $TimeoutSec,
        [switch]$UseBasicParsing, [switch]$SkipHttpErrorCheck)
    [void]$global:WeblabTestRequests.Add(@{ Uri = [string]$Uri; Body = [Text.Encoding]::UTF8.GetString($Body) })
    return [pscustomobject]@{ Content = '1'; StatusCode = 200 }
}
function Get-ItemProperty { param($Path) return $global:WeblabTestRegistry }
function Set-ItemProperty {
    [CmdletBinding()]
    param($Path, $Name, $Value)
    $global:WeblabTestWrites++
    if ($global:WeblabTestFailOverride -and $Name -eq 'ProxyOverride') { throw 'Injected registry write failure' }
    $global:WeblabTestRegistry.$Name = $Value
}
function Get-Process {
    [CmdletBinding()]
    param($Name)
    foreach ($process in $global:WeblabTestProcesses) {
        if (-not $process.HasExited) { $process }
    }
}
function Stop-Process {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$InputObject, [switch]$Force)
    process {
        if ($InputObject -and -not $InputObject.HasExited) { $InputObject.Kill(); $InputObject.WaitForExit() }
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
    $processLog = Join-Path (Split-Path -Parent $FilePath) ([guid]::NewGuid().ToString('N'))
    $process = Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle $WindowStyle -PassThru -RedirectStandardOutput ($processLog + '.out') -RedirectStandardError ($processLog + '.err')
    [void]$global:WeblabTestProcesses.Add($process)
    if ($PassThru) { return $process }
}
function New-Entry([int]$Number, [string]$Record, [string]$Standard, [string]$HostUrl) {
    $xml = "<ExamPaper><Para><Name>x</Name><StdResult>$Standard</StdResult><RealResult /></Para></ExamPaper>"
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
    $body = "UserID=test&LabID=1&LabName=test&RecordID=$Record&FileName=$Record.xml&Content=$payload&Key=test"
    return (@(
        "================ #$Number test ================"
        "POST $HostUrl/ServiceAPI/UpdateRecord"
        "---- body ($($body.Length) bytes) ----"
        $body
    ) -join [Environment]::NewLine) + [Environment]::NewLine
}

try {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'tools') -File | Where-Object { $_.Extension -in '.ps1', '.cs' }) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert-Equal ([BitConverter]::ToString($bytes, 0, 3)) 'EF-BB-BF' "$($file.Name) BOM"
        if ($file.Extension -eq '.ps1') {
            $parseErrors = $null; $tokens = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert-Equal $parseErrors.Count 0 "$($file.Name) syntax"
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $fixture $file.Name)
        }
    }
    $stubSource = Join-Path $testRoot 'CryptoStub.cs'
    [IO.File]::WriteAllText($stubSource, 'using System.IO; class CryptoStub { static void Main(string[] a) { File.Copy(a[1], a[2], true); } }')
    & $compiler /nologo /target:exe "/out:$fixture\LabDecrypt.exe" $stubSource
    if ($LASTEXITCODE -ne 0) { throw 'Crypto test fixture compilation failed' }
    & $compiler /nologo /platform:anycpu /codepage:65001 /target:exe "/out:$fixture\HttpSpy.exe" (Join-Path $SourceRoot 'tools\HttpSpy.cs')
    if ($LASTEXITCODE -ne 0) { throw 'HttpSpy compilation failed' }

    $logPath = Join-Path $testRoot 'requests.log'
    $logText = (New-Entry 1 'A' '7' 'http://127.0.0.1:18081') +
               (New-Entry 2 'B' '9' 'http://127.0.0.1:18083')
    [IO.File]::WriteAllText($logPath, $logText)
    & (Join-Path $fixture 'Invoke-LabPerfect.ps1') -LogPath $logPath -Apply -All -Server 'http://127.0.0.1:18082/' 6>$null
    Assert-Equal $global:WeblabTestRequests.Count 2 'Override request count'
    foreach ($request in $global:WeblabTestRequests) { Assert-Equal $request.Uri 'http://127.0.0.1:18082/ServiceAPI/UpdateRecord' 'Explicit server' }
    $global:WeblabTestRequests.Clear()
    & (Join-Path $fixture 'Invoke-LabPerfect.ps1') -LogPath $logPath -Apply -All 6>$null
    Assert-Equal $global:WeblabTestRequests[0].Uri 'http://127.0.0.1:18081/ServiceAPI/UpdateRecord' 'Captured server A'
    Assert-Equal $global:WeblabTestRequests[1].Uri 'http://127.0.0.1:18083/ServiceAPI/UpdateRecord' 'Captured server B'
    Write-Output 'PASS E1: explicit server persists across records; captured hosts remain per-record defaults'

    foreach ($lastStandard in @('7', '')) {
        $global:WeblabTestRequests.Clear()
        [IO.File]::WriteAllText($logPath, $logText + (New-Entry 3 'A' $lastStandard 'http://127.0.0.1:18081'))
        & (Join-Path $fixture 'Invoke-LabPerfect.ps1') -LogPath $logPath -Apply 6>$null
        Assert-Equal $global:WeblabTestRequests.Count 1 'Latest request count'
        $sentBody = $global:WeblabTestRequests[0].Body
        Assert-Equal ($sentBody -match '&RecordID=A&') $true 'Latest deduplicated record'
        $payload = [regex]::Match($sentBody, '&Content=([^&]+)').Groups[1].Value
        [xml]$sentXml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        Assert-Equal $sentXml.ExamPaper.Para.RealResult '7' 'Best payload retained'
    }
    Write-Output 'PASS E2: A,B,A selects latest group A, retaining its best payload'

    $stateFile = Join-Path $fixture 'proxy-state.json'
    $firstPort = Get-FreePort
    & (Join-Path $fixture 'proxy-on.ps1') -Port $firstPort 6>$null
    Assert-Equal $global:WeblabTestRegistry.ProxyServer "127.0.0.1:$firstPort" 'Ready proxy enabled'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $fixture 'capture\spy.log')) $true 'Log path with spaces'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture 'capture') -Filter '.ready-*').Count 0 'Readiness files cleaned'
    $secondPort = Get-FreePort
    & (Join-Path $fixture 'proxy-on.ps1') -Port $secondPort 6>$null
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Assert-Equal $state.ProxyServer '127.0.0.1:7890' 'Original backup preserved'
    Assert-Equal $global:WeblabTestRegistry.ProxyServer "127.0.0.1:$secondPort" 'Changed port enabled'
    & (Join-Path $fixture 'proxy-off.ps1') 6>$null
    Assert-Equal $global:WeblabTestRegistry.ProxyServer '127.0.0.1:7890' 'Original proxy restored'
    Assert-Equal $global:WeblabTestRegistry.ProxyOverride 'original' 'Original bypass restored'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Backup consumed after restore'
    Write-Output 'PASS E4/E6: real listener starts in path with spaces; port change retains original backup; shutdown restores it'

    $occupied = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $occupied.Start()
    try {
        $global:WeblabTestWrites = 0
        $failed = $false
        try { & (Join-Path $fixture 'proxy-on.ps1') -Port $occupied.LocalEndpoint.Port 6>$null } catch { $failed = $true }
        Assert-Equal $failed $true 'Occupied port rejected'
        Assert-Equal $global:WeblabTestWrites 0 'Fresh failed start must not write registry'
        Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Fresh failed start removes unused backup'
        Write-Output 'PASS E3: occupied port fails before any registry write'

        & (Join-Path $fixture 'proxy-on.ps1') -Port (Get-FreePort) 6>$null
        $failed = $false
        try { & (Join-Path $fixture 'proxy-on.ps1') -Port $occupied.LocalEndpoint.Port 6>$null } catch { $failed = $true }
        Assert-Equal $failed $true 'Failed restart rejected'
        Assert-Equal $global:WeblabTestRegistry.ProxyServer '127.0.0.1:7890' 'Failed restart restores original proxy'
        Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Failed restart completes rollback'
        Write-Output 'PASS E3: failed restart restores original proxy after stopping previous listener'
    } finally { $occupied.Stop() }

    $global:WeblabTestFailOverride = $true
    $failed = $false
    try { & (Join-Path $fixture 'proxy-on.ps1') -Port (Get-FreePort) 6>$null 3>$null } catch { $failed = $true }
    Assert-Equal $failed $true 'Injected write failure rejected'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $true 'Rollback failure retains backup'
    $failed = $false
    try { & (Join-Path $fixture 'proxy-off.ps1') 6>$null } catch { $failed = $true }
    Assert-Equal $failed $true 'Failed restore surfaces error'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $true 'Failed restore does not delete backup'
    $global:WeblabTestFailOverride = $false
    & (Join-Path $fixture 'proxy-off.ps1') 6>$null
    Assert-Equal $global:WeblabTestRegistry.ProxyServer '127.0.0.1:7890' 'Retry restores original proxy'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Successful retry removes backup'
    Assert-Equal @(Get-Process HttpSpy).Count 0 'Test proxy processes stopped'
    Write-Output 'PASS: registry failure retains backup and supports successful restore retry'

    $probeExe = Join-Path $testRoot 'ProxyRegression.exe'
    & $compiler /nologo /platform:anycpu /target:exe "/out:$probeExe" (Join-Path $PSScriptRoot 'ProxyRegression.cs')
    if ($LASTEXITCODE -ne 0) { throw 'HTTP regression harness compilation failed' }
    & $probeExe (Join-Path $fixture 'HttpSpy.exe') (Join-Path $testRoot 'http capture')
    if ($LASTEXITCODE -ne 0) { throw 'HTTP regression tests failed' }
    Write-Output ("PASS: all regressions on PowerShell {0}; mocked registry and replay transport; HTTP only on loopback" -f $PSVersionTable.PSVersion)
} finally {
    foreach ($process in $global:WeblabTestProcesses) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    # testRoot is created here from a GUID directly under the system temporary directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('weblab regression ')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
