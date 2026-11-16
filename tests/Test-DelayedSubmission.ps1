# Offline regression suite: real script + synthetic logs + mocked clock/HTTP.
# Run with powershell.exe or pwsh.exe -NoProfile -File tests/Test-DelayedSubmission.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('weblab-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$scriptPath = Join-Path $fixtureRoot 'Invoke-LabPerfect.ps1'
Copy-Item -LiteralPath (Join-Path $repo 'tools/Invoke-LabPerfect.ps1') -Destination $scriptPath
$global:WebLabTimingTestclock = [datetime]'2026-01-01T00:00:05'
$global:WebLabTimingTestrequests = @()
$global:WebLabTimingTestsleeps = 0
$global:WebLabTimingTestpassed = 0
$global:WebLabTimingTestovershoot = 0
$global:WebLabTimingTestrequestDelay = 0

function Assert($condition, $message) {
    if (-not $condition) { throw $message }
}
function Get-Date { return $global:WebLabTimingTestclock }
function Start-Sleep {
    param([int]$Seconds)
    $global:WebLabTimingTestsleeps++
    $global:WebLabTimingTestclock = $global:WebLabTimingTestclock.AddSeconds($Seconds + $global:WebLabTimingTestovershoot)
}
function Invoke-WebRequest {
    param($Uri, $Method, $Body, $ContentType, $TimeoutSec,
        [switch]$SkipHttpErrorCheck, [switch]$UseBasicParsing, $ErrorAction)
    $global:WebLabTimingTestrequests += [Text.Encoding]::UTF8.GetString($Body)
    $global:WebLabTimingTestclock = $global:WebLabTimingTestclock.AddSeconds($global:WebLabTimingTestrequestDelay)
    return [pscustomobject]@{ Content = '1'; StatusCode = 200 }
}
function New-Start([string]$time, [string]$user = 'test-user', [string]$lab = '163') {
    return "================ #1 $time =================`nPOST http://example.invalid/ServiceAPI/SetLabTimeRecordStart`n---- body (1 bytes) ----`nUSERID=$user&LABID=$lab`n"
}
function New-Submission([string]$time = '2026-01-01 00:00:05.000',
        [string]$record = '1', [switch]$NoTimeNode, [switch]$NoRealTimeNode) {
    $timeXml = '<Time><RealTime>7</RealTime></Time>'
    if ($NoTimeNode) { $timeXml = '' }
    elseif ($NoRealTimeNode) { $timeXml = '<Time />' }
    $xml = '<ExamPaper><Title><User>' + $timeXml + '</User></Title></ExamPaper>'
    $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
    return "================ #2 $time =================`nPOST http://example.invalid/ServiceAPI/UpdateRecord`n---- body (1 bytes) ----`nUserID=test-user&LabID=163&LabName=test&RecordID=$record&FileName=$record.xml&Content=$content&Key=test-key`n"
}
function Invoke-Case([string]$name, [string]$log, [hashtable]$options,
        [switch]$ExpectFailure, [int]$ExpectedRequests = 1,
        [int]$ExpectedSleep = -1, [string]$ExpectedRealTime = '60',
        [switch]$ExpectNoTimeNode, [switch]$ExpectNoRealTimeNode,
        [switch]$ExpectUnchangedClock,
        [string]$ExpectedError = 'SetLabTimeRecordStart',
        [datetime]$Clock = [datetime]'2026-01-01T00:00:05',
        [int]$SleepOvershoot = 0, [int]$RequestDelay = 0) {
    $global:WebLabTimingTestclock = $Clock
    $global:WebLabTimingTestovershoot = $SleepOvershoot
    $global:WebLabTimingTestrequestDelay = $RequestDelay
    $global:WebLabTimingTestrequests = @()
    $global:WebLabTimingTestsleeps = 0
    $logPath = Join-Path $fixtureRoot 'requests.log'
    [IO.File]::WriteAllText($logPath, $log)
    $failure = $null
    try {
        $invokeOptions = @{LogPath=$logPath; RealTimeMin=60; RealTimeMax=60; Quiet=$true}
        foreach ($key in $options.Keys) { $invokeOptions[$key] = $options[$key] }
        & $scriptPath @invokeOptions
    } catch { $failure = $_ }
    if ($ExpectFailure) {
        Assert ($null -ne $failure) "${name}: expected failure"
        Assert ($failure.Exception.Message -match $ExpectedError) "${name}: unexpected failure: $failure"
    } else {
        Assert ($null -eq $failure) "${name}: unexpected failure: $failure"
    }
    Assert ($global:WebLabTimingTestrequests.Count -eq $ExpectedRequests) "${name}: wrong request count"
    if ($ExpectedSleep -ge 0) {
        Assert ($global:WebLabTimingTestsleeps -eq $ExpectedSleep) "${name}: wrong sleep count"
    }
    if ($ExpectUnchangedClock) {
        Assert ($global:WebLabTimingTestclock -eq $Clock) "${name}: clock advanced"
    }
    foreach ($request in $global:WebLabTimingTestrequests) {
        Assert ($request -match '&Content=([^&]+)') "${name}: missing content"
        [xml]$document = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
        if ($ExpectNoTimeNode) {
            Assert ($null -eq $document.SelectSingleNode('//Title/User/Time')) "${name}: Time created"
        } elseif ($ExpectNoRealTimeNode) {
            Assert ($null -eq $document.SelectSingleNode('//Title/User/Time/RealTime')) "${name}: RealTime created"
        } else {
            Assert ($document.SelectSingleNode('//Title/User/Time/RealTime').InnerText -eq $ExpectedRealTime) "${name}: wrong XML RealTime"
        }
    }
    $global:WebLabTimingTestpassed++
    Write-Host "PASS $name"
}
try {
    # Stub only the external codec; no production crypto or platform connections.
    $codecSource = Join-Path $fixtureRoot 'CodecStub.cs'
    [IO.File]::WriteAllText($codecSource, 'using System.IO; class CodecStub { static void Main(string[] a) { File.Copy(a[1], a[2], true); } }')
    $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    & $csc /nologo /target:exe ("/out:" + (Join-Path $fixtureRoot 'LabDecrypt.exe')) $codecSource
    if ($LASTEXITCODE -ne 0) { throw 'Codec fixture compilation failed' }
    $start = New-Start '2026-01-01 00:00:00.000'
    $submission = New-Submission
    Invoke-Case 'wait until target' ($start + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectedSleep 1
    Invoke-Case 'exclude next session within one minute' ($start + $submission + (New-Start '2026-01-01 00:00:35.000')) @{Apply=$true; WaitRandomTime=$true} -ExpectedSleep 1
    Invoke-Case 'choose latest eligible start in unsorted log' ((New-Start '2025-12-31 23:59:00.000') + $start + (New-Start '2025-12-31 23:59:30.000') + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectedSleep 1
    Invoke-Case 'equal timestamp is eligible' ((New-Start '2026-01-01 00:00:05.000') + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectedSleep 1
    Invoke-Case 'missing start blocks apply' $submission @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'future start alone blocks apply' ($submission + (New-Start '2026-01-01 00:00:35.000')) @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'other user cannot provide start' ((New-Start '2026-01-01 00:00:00.000' 'other-user') + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0
    Invoke-Case 'other lab cannot provide start' ((New-Start '2026-01-01 00:00:00.000' 'test-user' '166') + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0
    Invoke-Case 'missing timestamp blocks apply' ($start + (New-Submission '')) @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0
    Invoke-Case 'batch preflight prevents partial send' ($start + $submission + ((New-Submission '2026-01-01 00:00:06.000' '2').Replace('LabID=163', 'LabID=166'))) @{Apply=$true; WaitRandomTime=$true; All=$true} -ExpectFailure -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'keep original with wait and other time options' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; KeepRealTime=$true; RandomTime=$true; RealTime=99} -ExpectedSleep 1 -ExpectedRealTime '7'
    Invoke-Case 'keep absent Time node' ($start + (New-Submission -NoTimeNode)) @{Apply=$true; WaitRandomTime=$true; KeepRealTime=$true} -ExpectedSleep 1 -ExpectNoTimeNode
    Invoke-Case 'keep absent RealTime node' ($start + (New-Submission -NoRealTimeNode)) @{Apply=$true; WaitRandomTime=$true; KeepRealTime=$true} -ExpectedSleep 1 -ExpectNoRealTimeNode
    Invoke-Case 'keep original without wait' $submission @{Apply=$true; KeepRealTime=$true; RandomTime=$true; RealTime=99} -ExpectedSleep 0 -ExpectedRealTime '7'
    Invoke-Case 'dry run does not sleep or send' ($start + $submission) @{WaitRandomTime=$true} -ExpectedRequests 0 -ExpectedSleep 0 -ExpectUnchangedClock
    Invoke-Case 'dry run rejects missing start' $submission @{WaitRandomTime=$true} -ExpectFailure -ExpectedRequests 0
    Invoke-Case 'report does not require timing' $submission @{Report=$true; WaitRandomTime=$true; Apply=$true} -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'ordinary apply requires no start' $submission @{Apply=$true} -ExpectedSleep 0 -ExpectedRealTime '7'
    Invoke-Case 'expired window rejects small overflow' ((New-Start '2025-12-31 23:58:00.000') + $submission) @{Apply=$true; WaitRandomTime=$true} -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'five hour old session rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; RealTimeMax=3000} -Clock '2026-01-01T05:00:00' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'previous day session rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; RealTimeMax=3000} -Clock '2026-01-02T00:00:05' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'keep does not bypass stale window' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; KeepRealTime=$true} -Clock '2026-01-02T00:00:05' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0
    Invoke-Case 'dry run rejects stale window' ($start + $submission) @{WaitRandomTime=$true} -Clock '2026-01-02T00:00:05' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'exact upper bound allowed' ($start + $submission) @{Apply=$true; WaitRandomTime=$true} -Clock '2026-01-01T00:01:00' -ExpectedSleep 0
    Invoke-Case 'fraction above upper bound rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true} -Clock '2026-01-01T00:01:00.001' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0
    Invoke-Case 'passed target within upper bound allowed' ((New-Start '2025-12-31 23:58:00.000') + $submission) @{Apply=$true; WaitRandomTime=$true; RealTimeMax=125} -ExpectedSleep 0 -ExpectedRealTime '125'
    Invoke-Case 'suspend during sleep rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true} -SleepOvershoot 18000 -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 1
    Invoke-Case 'keep does not bypass wake check' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; KeepRealTime=$true} -SleepOvershoot 18000 -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0
    Invoke-Case 'batch stale record blocks all requests' ($start + $submission + (New-Start '2025-12-31 19:00:00.000' 'test-user' '166') + ((New-Submission '2026-01-01 00:00:05.000' '2').Replace('LabID=163', 'LabID=166'))) @{Apply=$true; WaitRandomTime=$true; All=$true} -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0 -ExpectedSleep 0
    Invoke-Case 'later batch item expires after first request' ($start + $submission + (New-Submission '2026-01-01 00:00:05.000' '2')) @{Apply=$true; WaitRandomTime=$true; All=$true} -RequestDelay 18000 -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 1 -ExpectedSleep 1
    Invoke-Case 'future local clock rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true} -Clock '2025-12-31T23:59:59' -ExpectFailure -ExpectedError 'RealTimeMax' -ExpectedRequests 0
    Invoke-Case 'invalid wait interval rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; RealTimeMin=120; RealTimeMax=60} -ExpectFailure -ExpectedError 'RealTimeMin' -ExpectedRequests 0
    Invoke-Case 'subminute wait interval rejected' ($start + $submission) @{Apply=$true; WaitRandomTime=$true; RealTimeMin=10} -ExpectFailure -ExpectedError 'RealTimeMin' -ExpectedRequests 0
    Invoke-Case 'ordinary apply accepts old log unchanged' ($start + $submission) @{Apply=$true} -Clock '2026-01-02T00:00:05' -ExpectedSleep 0 -ExpectedRealTime '7'
    Invoke-Case 'report ignores stale window' ($start + $submission) @{Report=$true; WaitRandomTime=$true} -Clock '2026-01-02T00:00:05' -ExpectedRequests 0 -ExpectedSleep 0
    $batchText = [IO.File]::ReadAllText((Join-Path $repo '2-一键刷分.bat'))
    Assert ($batchText -match '(?m)^powershell[^\r\n]*Invoke-LabPerfect\.ps1" -Apply\s*$') 'one-click entry must use only -Apply'
    $global:WebLabTimingTestpassed++
    Write-Host 'PASS one-click entry preserves default time behavior'
    Write-Host "All $global:WebLabTimingTestpassed offline regression cases passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    # Remove only the unique fixture directory created by this test.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
