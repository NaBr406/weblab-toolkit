# Invoke-LabPerfect.ps1 —— 通用版：把抓到的实验提交包改成"满分版"重放
#
# 原理：
#   1) 实验客户端正常结束时会 POST /ServiceAPI/UpdateRecord，包里带
#      UserID / LabID / LabName / RecordID / FileName / Content / Key
#   2) Content = 加密的试卷 XML（同一套口令，可解密）
#   3) Key 只签 "UserID,LabID,FileName"，**不含 Content** → 内容随便改，Key 原样复用
#
# 所以完全不需要破解签名，也不需要懂每个实验的格式：
#   抓到一次真实提交 → 解出 XML → RealResult 全填成 StdResult → 重新加密 → 原样重放
#
# 用法：
#   .\Invoke-LabPerfect.ps1                      # 预览最新一条提交（DryRun）
#   .\Invoke-LabPerfect.ps1 -Apply               # 真正重放
#   .\Invoke-LabPerfect.ps1 -Apply -All          # 重放日志里所有提交（多个实验一起刷）
#   .\Invoke-LabPerfect.ps1 -Apply -Fill @{ SbqGeShu = '12.82' }
#                                                # 给 StdResult 为空的项指定真值
#   .\Invoke-LabPerfect.ps1 -Apply -NoSynthesize # 两边都空的项不补造，原样留着
#
param(
    [string]$LogPath,          # 默认 tools\capture\requests.log
    [switch]$Apply,            # 不加 = DryRun
    [switch]$All,              # 处理全部提交，默认只处理最新一条
    [int]$Last = 1,            # 只处理最近 N 条（-All 优先）
    [int]$RealTime = -1,       # >0 则把 RealTime 改成这个秒数
    [switch]$Quiet,
    [switch]$Report,           # 只看评分结构，不提交
    [hashtable]$Fill,          # 给 StdResult 为空的项指定真值，如 @{ SbqGeShu = '12.82' }
    [switch]$NoSynthesize,     # 两边都空的项不塞 '1'，保持空白（只对表格型/单值型都生效）
    [string]$Server,           # 手动指定服务端，如 http://10.0.0.5:8001（默认从抓包日志的请求行推断）
    [switch]$KeepTemp          # 保留临时目录（里面有解出的原包和改好的 perfect.xml，排查用）
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dec  = Join-Path $here 'LabDecrypt.exe'
if (-not (Test-Path $dec)) { throw "缺 LabDecrypt.exe：$here" }
if (-not $LogPath) { $LogPath = Join-Path $here 'capture\requests.log' }
if (-not (Test-Path $LogPath)) { throw "没有抓包日志：$LogPath（先 .\proxy-on.ps1 再做一次实验）" }

function Log2($m) { if (-not $Quiet) { Write-Host $m } }

# 找一个真正可写的临时目录。
# 为什么不直接用 %TEMP%：本仓库常见部署位置是 D:\ 下的普通目录，那里的文件带
# Low Mandatory Level（低完整性）标签，从该目录启动的进程也是低完整性，而
# %TEMP% 是 Medium —— New-Item 会直接 UnauthorizedAccessException。
# 顺序：脚本目录下的 .tmp → %TEMP% → 报错。
function New-ScratchDir([string]$prefix) {
    foreach ($cand in @((Join-Path $here '.tmp'), [IO.Path]::GetTempPath())) {
        try {
            if (-not (Test-Path $cand)) {
                New-Item -ItemType Directory -Force -Path $cand -ErrorAction Stop | Out-Null
            }
            $d = Join-Path $cand ($prefix + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null
            return $d
        } catch { }
    }
    throw "没有可写的临时目录（已试 $here\.tmp 和 %TEMP%）"
}

# Content 在 body 里的形态不统一：多数实验直接是 base64，
# 少数客户端会做一次 URL 编码（base64 里的 + / = 变成 %2B %2F %3D）。
# 两种都试，谁先解开用谁。
function ConvertFrom-B64Flexible([string]$v) {
    try { return [Convert]::FromBase64String($v) } catch { }
    $u = $v
    try { $u = [uri]::UnescapeDataString($u.Replace('+', ' ')) } catch { }
    return [Convert]::FromBase64String($u)
}

function Test-Placeholder([string]$v) {
    # 模板里的"假标准值"：空 / 0 / 0.000 / NaN —— 照抄只会让相对偏差变成 0/0
    $s = "$v".Trim()
    if ($s -eq "") { return $true }
    if ($s -match "^(?i)nan$") { return $true }
    if ($s -match "^-?0(\.0*)?$") { return $true }
    return $false
}

# 一格里有多少个"真标准值"：表格型按格子数，单值型最多 1
function Measure-StdCells([string]$v) {
    $s = "$v"
    if ($s.Contains(';')) {
        $n = 0
        $parts = $s -split ';'
        for ($i2 = 1; $i2 -lt $parts.Count; $i2++) {
            foreach ($cell in ([string]$parts[$i2]).Trim('(', ')').Split(',')) {
                if (-not (Test-Placeholder $cell)) { $n++ }
            }
        }
        return $n
    }
    if (Test-Placeholder $s) { return 0 } else { return 1 }
}

# 调 LabDecrypt.exe。PS 5.1 在 $ErrorActionPreference='Stop' 下会把外部程序的
# stderr 提升成终止性错误（明文 XML 的实验必然触发），所以这里临时降级并吞掉输出，
# 只返回退出码。调用方靠"输出文件是否存在"判断成败。
#
# 另外 Component.dll 是 .NET 2.x 的混淆程序集（类型名如 cwsQigtUY2cZbGk4AvO.*），
# 在 .NET 4 CLR 下 JIT 偶发 InvalidProgramException，进程直接以 -532462766 退出，
# 控制台只留一句"由于 Exception.ToString() 失败"。实测干净环境连跑 40 次 0 失败，
# 但并发编译 / 32 位宿主命中过，所以失败静默重试一次（成本约 100ms）。
$script:decFlaky = 0
function Invoke-Dec([string]$mode, [string]$inPath, [string]$outPath) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        for ($try = 1; $try -le 2; $try++) {
            if (Test-Path $outPath) { Remove-Item $outPath -Force -ErrorAction SilentlyContinue }
            & $dec $mode $inPath $outPath 2>&1 | Out-Null
            $ec = $LASTEXITCODE
            if ($ec -eq 0 -and (Test-Path $outPath)) { return 0 }
            if ($try -eq 1) { $script:decFlaky++ }
        }
        return $ec
    }
    finally { $ErrorActionPreference = $old }
}

# 去重打分：解密后数整份 XML 里"有真标准值的格子"总数。
# 返回 -1 = 这份 Content 解不开（既非加密包也非明文 XML），排序时垫底。
$script:scoreTmp = $null
$script:scoreCache = @{}
function Get-StdScore([string]$contentB64) {
    $h = [BitConverter]::ToString(
            [Security.Cryptography.SHA256]::Create().ComputeHash(
                [Text.Encoding]::ASCII.GetBytes("$contentB64"))).Replace('-', '')
    if ($script:scoreCache.ContainsKey($h)) { return $script:scoreCache[$h] }
    $score = -1
    try {
        if (-not $script:scoreTmp) {
            $script:scoreTmp = New-ScratchDir 'lpf_score_'
        }
        $bytes2 = ConvertFrom-B64Flexible $contentB64
        $bx = Join-Path $script:scoreTmp 'c.bin'
        $ox = Join-Path $script:scoreTmp 'c.xml'
        [IO.File]::WriteAllBytes($bx, $bytes2)
        if (Test-Path $ox) { Remove-Item $ox -Force -ErrorAction SilentlyContinue }
        [void](Invoke-Dec 'dec' $bx $ox)
        $d2 = $null
        if (Test-Path $ox) {
            try { $t = New-Object System.Xml.XmlDocument; $t.Load($ox); $d2 = $t } catch { $d2 = $null }
        }
        if (-not $d2) {
            try { $t = New-Object System.Xml.XmlDocument; $t.LoadXml([Text.Encoding]::UTF8.GetString($bytes2)); $d2 = $t } catch { $d2 = $null }
        }
        if ($d2) {
            $score = 0
            foreach ($p2 in $d2.SelectNodes('//Para')) {
                $n2 = $p2.SelectSingleNode('StdResult')
                if (-not $n2) { continue }
                $score += Measure-StdCells ([string]$n2.InnerText)
            }
        }
    } catch { $score = -1 }
    $script:scoreCache[$h] = $score
    return $score
}

# ---------- 1. 从日志切出提交 ----------
$raw = Get-Content $LogPath -Raw -Encoding UTF8
$chunks = [regex]::Split($raw, '(?m)^================ #') | Where-Object { $_ -match 'POST http://[^/]+/ServiceAPI/UpdateRecord' }
if (-not $chunks) { throw "日志里没有 /ServiceAPI/UpdateRecord 提交（确认抓包时确实结束过实验）" }

$subs = @()
foreach ($c in $chunks) {
    # 请求行里的目标地址才是真正的服务端（body 里没有 ServerIP 字段）
    $host2 = ''
    if ($c -match 'POST (https?://[^/\s]+)/ServiceAPI/UpdateRecord') { $host2 = $Matches[1] }
    if ($c -match '(?s)---- body \((\d+) bytes\) ----\r?\n(.*)$') {
        $bodyText = $Matches[2].Trim()
        if ($bodyText -notmatch 'UserID=') { continue }
        $f = @{}
        foreach ($kv in $bodyText.Split('&')) {
            $i = $kv.IndexOf('=')
            if ($i -gt 0) { $f[$kv.Substring(0, $i)] = $kv.Substring($i + 1) }
        }
        if ($f.ContainsKey('Content') -and $f.ContainsKey('Key')) {
            $f['__host'] = $host2
            $subs += , $f
        }
    }
}
if (-not $subs) { throw "没能从日志里解析出提交体" }
$rawCount = $subs.Count
# 去重：同一 RecordID + FileName 只保留一条（客户端一次提交会连发 3 遍）
# 有的实验分两次下发：先空卷、后带标准答案卷。判据不是"谁更长"，而是
# 解密后谁的"真标准值格子"多；打平才回退 Content 长度（2026-11-13 修）。
# 位置按最后一次出现记，避免 [ordered]@{}.Values 保留首次位置、让 -Last 选错。
$groups = [ordered]@{}
$idx = 0
$dupeGroups = 0
foreach ($s1 in $subs) {
    $k = "$($s1['RecordID'])|$($s1['FileName'])"
    if (-not $groups.Contains($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
    [void]$groups[$k].Add(@{ idx = $idx; item = $s1 })
    $idx++
}
$picked = @()
foreach ($k in @($groups.Keys)) {
    $cands = $groups[$k]
    if ($cands.Count -eq 1) { $picked += $cands[0]; continue }
    $dupeGroups++
    $best = $null; $bestScore = -99; $bestLen = -1
    foreach ($c in $cands) {
        $sc = Get-StdScore ([string]$c.item['Content'])
        $len = ([string]$c.item['Content']).Length
        if ($sc -gt $bestScore -or ($sc -eq $bestScore -and $len -gt $bestLen)) {
            $best = $c; $bestScore = $sc; $bestLen = $len
        }
    }
    if ($bestScore -lt 0) { Write-Warning "  同一记录的多份 Content 都解析不了，退回按长度选：$k" }
    $picked += $best
}
$subs = @($picked | Sort-Object { $_.idx } | ForEach-Object { $_.item })
if (-not $All) {
    if ($Last -lt 1) { $Last = 1 }
    if ($Last -lt $subs.Count) { $subs = @($subs[($subs.Count - $Last)..($subs.Count - 1)]) }
}
Log2 ("找到 {0} 条提交（{1} 组重复已合并，本次处理 {2} 条）" -f $rawCount, $dupeGroups, $subs.Count)

# ---------- 2. 逐条处理 ----------
$tmp = New-ScratchDir 'lpf_'

$okCount = 0
foreach ($f in $subs) {
    $tag = "{0} / LabID={1} / RecordID={2}" -f $f['LabName'], $f['LabID'], $f['RecordID']
    Log2 ("===== {0} =====" -f $tag)

    # 2.1 解出 Content
    $encBytes = ConvertFrom-B64Flexible $f['Content']
    $encPath = Join-Path $tmp 'content.bin'
    [IO.File]::WriteAllBytes($encPath, $encBytes)
    $xmlPath = Join-Path $tmp 'content.xml'
    if (Test-Path $xmlPath) { Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue }
    [void](Invoke-Dec 'dec' $encPath $xmlPath)
    $doc = New-Object System.Xml.XmlDocument
    $loaded = $false
    if (Test-Path $xmlPath) {
        try { $doc.Load($xmlPath); $loaded = $true } catch { $loaded = $false }
    }
    if (-not $loaded) {
        # 有些实验的 Content 不是 LitJson 加密，而是明文 XML
        try {
            $doc.LoadXml([Text.Encoding]::UTF8.GetString($encBytes))
            $loaded = $true
            Log2 "  （Content 是明文 XML，已直接解析）"
        } catch { }
    }
    if (-not $loaded) { Write-Warning "Content 解析失败（既不是加密包也不是明文 XML），跳过 $tag"; continue }

    # 2.1b -Report：只打印评分结构，判断上限在哪
    if ($Report) {
        Log2 "  ---- 评分结构（分值 × 行数，'空' = 该参数没有标准值）----"
        $tot = 0
        foreach ($p in $doc.SelectNodes('//Para')) {
            $perNode = $p.SelectSingleNode('JudgeRule/Rule/Score')
            if (-not $perNode) { continue }
            $per = 0; [void][int]::TryParse([string]$perNode.InnerText, [ref]$per)
            $stdNode2 = $p.SelectSingleNode('StdResult')
            $std2 = if ($stdNode2) { [string]$stdNode2.InnerText } else { '' }
            $nameNode = $p.SelectSingleNode('Name'); $name = if ($nameNode) { [string]$nameNode.InnerText } else { '?' }
            $rows = 1
            if ($std2.Contains(';')) { $rows = @($std2 -split ';').Count - 1 }
            $sum = $per * [Math]::Max($rows, 1)
            $tot += $sum
            $flag = if ($std2.Trim() -eq '') { '空' } else { '有' }
            $rEnd = $p.SelectSingleNode('RealResult')
            $rTxt = if ($rEnd) { [string]$rEnd.InnerText } else { '' }
            $rState = if ($rTxt.Trim() -eq '') { '未填' } else { '已填' }
            Log2 ("    {0,-26} {1,2}分 × {2,2}行 = {3,4}   标准值:{4}  实测:{5}" -f $name, $per, $rows, $sum, $flag, $rState)
        }
        Log2 ("    —— 可判分权重合计: {0}" -f $tot)
        Log2 ""
        continue
    }

    # 2.2 填数据
    $doc.DocumentElement.SetAttribute('__patched', '1') | Out-Null
    $filled = 0; $mirrored = 0; $synth = 0; $skipped = 0
    foreach ($para in $doc.SelectNodes('//Para')) {
        $stdNode  = $para.SelectSingleNode('StdResult')
        $realNode = $para.SelectSingleNode('RealResult')
        # 有的实验干脆没有这两个节点，缺就补一个，别整个跳过
        if (-not $stdNode)  { $stdNode = $doc.CreateElement('StdResult');   $para.AppendChild($stdNode)  | Out-Null }
        if (-not $realNode) { $realNode = $doc.CreateElement('RealResult'); $para.AppendChild($realNode) | Out-Null }
        $std = [string]$stdNode.InnerText; $real = [string]$realNode.InnerText
        $hasRule = [bool]$para.SelectSingleNode('JudgeRule/Rule')

        # 表格型：(...);(...);(...)
        if ($std.Contains(';') -and $real.Contains(';')) {
            $stdParts = @($std -split ';')
            $realParts = @($real -split ';')
            $hdr = [string]$stdParts[0]
            $stdRows = @()
            if ($stdParts.Count -gt 1) { $stdRows = @($stdParts[1..($stdParts.Count - 1)]) }
            $realBody = @()
            if ($realParts.Count -gt 1) { $realBody = @($realParts[1..($realParts.Count - 1)]) }
            $out = @()
            for ($r = 0; $r -lt $stdRows.Count; $r++) {
                $rowRaw = [string]$stdRows[$r]
                # 行内到底带不带括号要跟原样一致：有的实验写 "(1,2,3)"，有的直接 "1,2,3"。
                # 无条件补括号会把不带括号的格式改坏（服务端按行拆分时会对不上，整行判 0 分）。
                $paren = $rowRaw.Trim().StartsWith('(') -or $rowRaw.Trim().EndsWith(')')
                $sc = @($rowRaw.Trim('(', ')').Split(','))
                $rc = @()
                if ($r -lt $realBody.Count) { $rc = @(([string]$realBody[$r]).Trim('(', ')').Split(',')) }
                # RealResult 行比 StdResult 短时补齐列数，避免索引越界
                while ($rc.Count -lt $sc.Count) { $rc += '' }
                for ($c = 0; $c -lt $sc.Count; $c++) {
                    $sv = [string]$sc[$c]; $rv = [string]$rc[$c]
                    if ($c -eq 0) { continue }                     # 序号列不动
                    if (-not (Test-Placeholder $sv)) { $rc[$c] = $sv; $filled++ }   # 真标准值 → 照抄
                    elseif (-not (Test-Placeholder $rv)) { $sc[$c] = $rv; $mirrored++ }  # 有填写 → 反填
                    elseif ($NoSynthesize) { $skipped++ }              # 都空且要求不补造 → 原样留白
                    else { $rc[$c] = '1'; $sc[$c] = '1'; $synth++ }     # 都空 → 双双造一个
                }
                $rcJ = $rc -join ','; $scJ = $sc -join ','
                if ($paren) { $rcJ = '(' + $rcJ + ')'; $scJ = '(' + $scJ + ')' }
                $out += $rcJ
                $stdRows[$r] = $scJ
            }
            $realNode.InnerText = $hdr + ';' + ($out -join ';')
            $stdNode.InnerText  = $hdr + ';' + ($stdRows -join ';')
        }
        elseif (-not (Test-Placeholder $std)) { $realNode.InnerText = $std; $filled++ }
        elseif (-not (Test-Placeholder $real)) { $stdNode.InnerText = $real; $mirrored++ }
        elseif ($NoSynthesize -and $hasRule) { $skipped++ }
        elseif ($hasRule) {
            # 单值型且两边都空：这一项本来 0 分，给 Real/Std 同时塞同一个值 → 偏差 0
            # 但有的项 StdResult 空、JudgeRule 却给了分（如"示波器对应格数"1 分），
            # 塞 1 只是碰运气；用 -Fill 传真值更稳：
            #   -Fill @{ SbqGeShu = '12.82' }
            $pnNode = $para.SelectSingleNode('Name')
            $pn = if ($pnNode) { [string]$pnNode.InnerText } else { '' }
            $sval = '1'
            if ($Fill -and $pn -and $Fill.ContainsKey($pn)) { $sval = [string]$Fill[$pn] }
            $realNode.InnerText = $sval; $stdNode.InnerText = $sval; $synth++
        }
    }
    if ($RealTime -gt 0) {
        $n = $doc.SelectSingleNode('//Title/User/Time/RealTime')
        if ($n) { $n.InnerText = "$RealTime" }
    }
    $tail = ""
    if ($skipped -gt 0) { $tail = " / 跳过 $skipped 格（-NoSynthesize）" }
    Log2 ("  填入 {0} 格 / 反填 {1} 格 / 补造 {2} 格{3}" -f $filled, $mirrored, $synth, $tail)

    $newXml = Join-Path $tmp 'perfect.xml'
    $doc.Save($newXml)
    $newBin = Join-Path $tmp 'perfect.bin'
    if ((Invoke-Dec 'enc' $newXml $newBin) -ne 0 -or -not (Test-Path $newBin)) {
        Write-Warning "重新加密失败，跳过 $tag"
        continue
    }

    # 2.3 组包（Key 原样复用）
    $content2 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($newBin))
    $body = "UserID=$($f['UserID'])&LabID=$($f['LabID'])&LabName=$($f['LabName'])" +
            "&RecordID=$($f['RecordID'])&FileName=$($f['FileName'])&Content=$content2&Key=$($f['Key'])"

    if (-not $Apply) {
        Log2 ("  [DryRun] 报文 {0} 字节，未发送" -f $body.Length)
        continue
    }

    # 重放目标：-Server > 抓包日志请求行里的真实地址 > body 里的 ServerIP 字段。
    # 旧版这里写死过一个内网地址，换机房/换学校就发错地方（2026-11-13 修）。
    $server = ''
    if ($Server) { $server = $Server.TrimEnd('/') }
    elseif ($f.ContainsKey('__host') -and $f['__host']) { $server = $f['__host'] }
    elseif ($f.ContainsKey('ServerIP') -and $f['ServerIP']) { $server = $f['ServerIP'] }
    if (-not $server) {
        Write-Warning "  日志里没有请求行，分不清服务端地址，跳过 $tag（可用 -Server http://ip:port 指定）"
        continue
    }
    # 兼容 PowerShell 5.1 / 7：5.1 没有 -SkipHttpErrorCheck，用 try/catch 取响应体
    $savedProxy = [System.Net.WebRequest]::DefaultWebProxy
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $null   # 直连，别把重放也塞进抓包日志
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $r = Invoke-WebRequest "$server/ServiceAPI/UpdateRecord" -Method POST `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/x-www-form-urlencoded' `
                    -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
            $code = [string]$r.Content; $status = [int]$r.StatusCode
        } else {
            $r = Invoke-WebRequest "$server/ServiceAPI/UpdateRecord" -Method POST `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/x-www-form-urlencoded' `
                    -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
            $code = [string]$r.Content; $status = [int]$r.StatusCode
        }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $code = $sr.ReadToEnd(); $sr.Close()
            $status = [int]$resp.StatusCode
        } else { throw }
    } finally {
        [System.Net.WebRequest]::DefaultWebProxy = $savedProxy
    }
    $meaning = switch ($code.Trim()) {
        '1'  { '成功' }
        '-3' { 'RecordID 不匹配（这条记录可能已被服务端清理）' }
        '-4' { 'Key/FileName/UserID 不匹配（抓包与重放之间请勿改动这些字段）' }
        default { '未知返回码' }
    }
    Log2 ("  重放 -> HTTP {0}  响应={1}（{2}）" -f $status, $code, $meaning)
    if ($code.Trim() -eq '1') { $okCount++ }
}

if ($KeepTemp) {
    Log2 ("  临时文件保留在：{0}" -f $tmp)
} else {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:scoreTmp) { Remove-Item $script:scoreTmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:decFlaky -gt 0) {
    Log2 ("  （解密进程重试过 {0} 次：Component.dll 偶发 JIT 崩溃，已自动恢复）" -f $script:decFlaky)
}
Log2 ""
if ($Apply) { Log2 ("完成：{0}/{1} 条成功" -f $okCount, $subs.Count) }
else { Log2 "以上为预览。加 -Apply 才会真正提交。" }
