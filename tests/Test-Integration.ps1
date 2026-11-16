# Interaction tests for features merged from the legacy edition. No platform connections.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('weblab-integration-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$scriptFile = Join-Path $fixture 'Invoke-LabPerfect.ps1'
Copy-Item -LiteralPath (Join-Path $repo 'tools\Invoke-LabPerfect.ps1') -Destination $scriptFile
$global:WeblabMergeRequests = @()
$global:WeblabMergeClock = [datetime]'2026-01-01T00:00:05'
$global:WeblabMergeCount = 0
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Get-Date { return $global:WeblabMergeClock }
function Start-Sleep { param($Seconds) $global:WeblabMergeClock = $global:WeblabMergeClock.AddSeconds($Seconds) }
function Invoke-WebRequest {
    param($Uri, $Method, $Body, $ContentType, $TimeoutSec, $ErrorAction, [switch]$SkipHttpErrorCheck, [switch]$UseBasicParsing)
    $global:WeblabMergeRequests += @{Uri=[string]$Uri; Body=[Text.Encoding]::UTF8.GetString($Body)}
    return [pscustomobject]@{Content='1'; StatusCode=200}
}
function New-Entry([string]$xml, [string]$lab='163', [string]$record='1', [string]$origin='http://example.invalid',
    [switch]$Encoded, [string]$ContentOverride='') {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
    if ($Encoded) { $payload = [uri]::EscapeDataString($payload) }
    if ($ContentOverride) { $payload = $ContentOverride }
    return (@(
        '================ #2 2026-01-01 00:00:05.000 ================'
        "POST $origin/ServiceAPI/UpdateRecord"
        '---- body (1 bytes) ----'
        "UserID=test-user&LabID=$lab&LabName=test&RecordID=$record&FileName=$record.xml&Content=$payload&Key=test"
        ''
    ) -join [Environment]::NewLine)
}
function Invoke-Case([string]$name, [string]$log, [hashtable]$options, [scriptblock]$verify, [switch]$ExpectFailure, [string]$ExpectedError='') {
    $global:WeblabMergeClock = [datetime]'2026-01-01T00:00:05'
    $global:WeblabMergeRequests = @()
    $logPath = Join-Path $fixture 'requests.log'
    [IO.File]::WriteAllText($logPath, $log)
    $arguments = @{LogPath=$logPath; Apply=$true; Quiet=$true}
    foreach ($key in $options.Keys) { $arguments[$key]=$options[$key] }
    $failure=$null
    try { & $scriptFile @arguments } catch { $failure=$_ }
    if ($ExpectFailure) {
        Assert ($null -ne $failure) "$name expected a failure"
        if ($ExpectedError) { Assert ($failure.Exception.Message -match $ExpectedError) "$name wrong error: $failure" }
    } else { Assert ($null -eq $failure) "$name unexpected failure: $failure" }
    & $verify
    $leftover = @(Get-ChildItem -LiteralPath (Join-Path $fixture '.tmp') -Directory -ErrorAction SilentlyContinue)
    Assert ($leftover.Count -eq 0) "$name leaked scratch directories"
    $global:WeblabMergeCount++
    Write-Output "PASS $name"
}
function Sent-Xml([int]$index=0) {
    $payload=[regex]::Match($global:WeblabMergeRequests[$index].Body,'&Content=([^&]+)').Groups[1].Value
    return [xml][Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
}
try {
    $codec=Join-Path $fixture 'CodecStub.cs'
    [IO.File]::WriteAllText($codec,'using System.IO; class CodecStub { static void Main(string[] a) { File.Copy(a[1], a[2], true); } }')
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe ("/out:" + (Join-Path $fixture 'LabDecrypt.exe')) $codec
    if ($LASTEXITCODE -ne 0) { throw 'Codec compilation failed' }
    $xml='<ExamPaper><Title><User><Time><RealTime>7</RealTime></Time></User></Title><Para><Name>x</Name><StdResult>2.5</StdResult><RealResult /></Para></ExamPaper>'
    $table='<ExamPaper><Title><User /></Title><Para><Name>table</Name><StdResult>i,v;1,2.5;2,3.5</StdResult><RealResult>i,v;1,;2,</RealResult></Para></ExamPaper>'
    $rows = (1..25 | ForEach-Object {"$_,"}) -join ';'
    $emptyTable="<ExamPaper><Title><User /></Title><Para><Name>table</Name><StdResult>i,v;$rows</StdResult><RealResult>i,v;$rows</RealResult></Para></ExamPaper>"
    Invoke-Case 'empty table indexes cannot outweigh real standards' ((New-Entry $emptyTable) + (New-Entry $table)) @{} {
        $doc=Sent-Xml
        Assert ($doc.ExamPaper.Para.RealResult -eq 'i,v;1,2.5;2,3.5') 'Wrong table selected or row parentheses changed'
    }
    Invoke-Case 'filter lab before selecting latest record' ((New-Entry $xml '163') + (New-Entry $xml '166' '2')) @{OnlyLab='163'} {
        Assert ($global:WeblabMergeRequests.Count -eq 1) 'Wrong filtered count'
        Assert ($global:WeblabMergeRequests[0].Body -match '&LabID=163&') 'Wrong filtered lab'
    }
    Invoke-Case 'missing filtered lab sends nothing' (New-Entry $xml) @{OnlyLab='999'} {
        Assert ($global:WeblabMergeRequests.Count -eq 0) 'Unexpected send'
    } -ExpectFailure -ExpectedError 'LabID=999'
    Invoke-Case 'same record on different servers stays separate' ((New-Entry $xml) + (New-Entry $xml '163' '1' 'http://other.invalid')) @{All=$true} {
        Assert ($global:WeblabMergeRequests.Count -eq 2) 'Cross-server deduplication'
        Assert ($global:WeblabMergeRequests[1].Uri -eq 'http://other.invalid/ServiceAPI/UpdateRecord') 'Wrong second host'
    }
    Invoke-Case 'URL-encoded payload still decodes' (New-Entry $xml -Encoded) @{} {
        $doc=Sent-Xml
        Assert ($doc.ExamPaper.Para.RealResult -eq '2.5') 'URL decoding regressed'
    }
    Invoke-Case 'fixed XML duration' (New-Entry $xml) @{RealTime=123} {
        Assert ((Sent-Xml).ExamPaper.Title.User.Time.RealTime -eq '123') 'Fixed time not applied'
    }
    Invoke-Case 'random duration inside explicit interval' (New-Entry $xml) @{RandomTime=$true; RealTimeMin=61; RealTimeMax=62} {
        $value=[int](Sent-Xml).ExamPaper.Title.User.Time.RealTime
        Assert ($value -ge 61 -and $value -le 62) 'Random duration outside range'
    }
    $noTime='<ExamPaper><Title><User /></Title></ExamPaper>'
    Invoke-Case 'missing time nodes created for fixed duration' (New-Entry $noTime) @{RealTime=90} {
        Assert ((Sent-Xml).ExamPaper.Title.User.Time.RealTime -eq '90') 'Missing time node'
    }
    $blank='<ExamPaper><Title><User /></Title><Para><Name>blank</Name><StdResult /><RealResult /><JudgeRule><Rule><Score>1</Score></Rule></JudgeRule></Para></ExamPaper>'
    Invoke-Case 'manual fill combines with lab selection' (New-Entry $blank) @{OnlyLab='163'; Fill=@{blank='12.82'}} {
        Assert ((Sent-Xml).ExamPaper.Para.RealResult -eq '12.82') 'Manual fill lost'
    }
    Invoke-Case 'no synthesis still preserves blanks' (New-Entry $blank) @{NoSynthesize=$true; KeepRealTime=$true; RandomTime=$true} {
        Assert ((Sent-Xml).SelectSingleNode('//Para/RealResult').InnerText -eq '') 'Blank was synthesized'
    }
    $start = (@(
        '================ #1 2026-01-01 00:00:00.000 ================'
        'POST http://example.invalid/ServiceAPI/SetLabTimeRecordStart'
        '---- body (1 bytes) ----'
        'LABID=163&extra=1&USERID=test-user'
        ''
    ) -join [Environment]::NewLine)
    Invoke-Case 'unordered start fields resolve correctly' ($start + (New-Entry $xml)) @{WaitRandomTime=$true; RealTimeMin=60; RealTimeMax=60} {
        Assert ((Sent-Xml).ExamPaper.Title.User.Time.RealTime -eq '60') 'Start fields not parsed'
    }
    Invoke-Case 'start from another server cannot satisfy timing' ($start.Replace('example.invalid','other.invalid') + (New-Entry $xml)) @{WaitRandomTime=$true; RealTimeMin=60; RealTimeMax=60} {
        Assert ($global:WeblabMergeRequests.Count -eq 0) 'Cross-server start accepted'
    } -ExpectFailure -ExpectedError 'SetLabTimeRecordStart'
    Invoke-Case 'preflight failure cleans score scratch directory' ((New-Entry $xml) + (New-Entry $blank)) @{WaitRandomTime=$true; RealTimeMin=60; RealTimeMax=60} {
        Assert ($global:WeblabMergeRequests.Count -eq 0) 'Sent during failed preflight'
    } -ExpectFailure -ExpectedError 'SetLabTimeRecordStart'
    Invoke-Case 'decoding failure cleans processing scratch directory' ((New-Entry $xml) + (New-Entry $xml '166' '2' -ContentOverride 'invalid-base64')) @{All=$true; Apply=$false} {
        Assert ($global:WeblabMergeRequests.Count -eq 0) 'DryRun unexpectedly sent data'
    } -ExpectFailure
    Write-Output ("All {0} merge interaction cases passed on PowerShell {1}." -f $global:WeblabMergeCount,$PSVersionTable.PSVersion)
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
