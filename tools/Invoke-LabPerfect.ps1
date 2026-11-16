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
    [switch]$RandomTime,       # 从 RealTimeMin..RealTimeMax 随机选择秒数
    [switch]$WaitRandomTime,   # 按抓包开始时间等待后重放，不保证改变服务端用时
    [int]$RealTimeMin = 1800,
    [int]$RealTimeMax = 3000,
    [switch]$KeepRealTime,     # 保留原始用时，优先于其他用时选项
    [string]$OnlyLab = '',     # 仅处理指定 LabID；筛选后再应用 -Last
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
if (-not (Test-Path $dec)) {
    # 仓库只带 .cs 源码：exe 缺席时自动编一次
    $build = Join-Path $here 'build.ps1'
    if (-not (Test-Path $build)) { throw "缺 LabDecrypt.exe，也找不到 build.ps1 —— 仓库不完整，请重新获取" }
    Write-Host "未找到 LabDecrypt.exe，正在自动编译（首次约 3 秒）…" -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File $build
    if (-not (Test-Path $dec)) { throw "自动编译失败，没生成 LabDecrypt.exe。请手动在 tools\ 下运行 build.ps1 查看报错" }
}
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
            $cells = ([string]$parts[$i2]).Trim('(', ')').Split(',')
            for ($column = 1; $column -lt $cells.Count; $column++) {
                if (-not (Test-Placeholder $cells[$column])) { $n++ }
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

# 随机秒数取闭区间；保留旧参数对上下限交换和不足一分钟的兼容处理。
function Get-RandomRealTime([int]$MinSeconds = 1800, [int]$MaxSeconds = 3000) {
    if ($MinSeconds -gt $MaxSeconds) { $swap = $MinSeconds; $MinSeconds = $MaxSeconds; $MaxSeconds = $swap }
    $MinSeconds = [Math]::Max(60, $MinSeconds)
    $MaxSeconds = [Math]::Max($MinSeconds, $MaxSeconds)
    return [int](Get-Random -Minimum $MinSeconds -Maximum ([long]$MaxSeconds + 1))
}

function Get-ChunkTime([string]$chunk) {
    if ($chunk -match '(?m)^#?\d+\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    }
    return $null
}

function Get-LabSessionKey([string]$hostUrl, [string]$userId, [string]$labId) {
    $userId = [uri]::UnescapeDataString($userId.Replace('+', ' '))
    $labId = [uri]::UnescapeDataString($labId.Replace('+', ' '))
    return "$($hostUrl.TrimEnd('/').ToLowerInvariant())|$userId|$labId"
}

function Get-LabStartMap($chunkList) {
    $map = @{}
    foreach ($chunk in $chunkList) {
        if ($chunk -notmatch '(?m)^POST (https?://[^/\s]+)/ServiceAPI/SetLabTimeRecordStart(?:\s|$|\?)') { continue }
        $origin = $Matches[1]
        $time = Get-ChunkTime $chunk
        if (-not $time -or $chunk -notmatch '(?s)---- body \(\d+ bytes\) ----\r?\n(.*)$') { continue }
        $fields = @{}
        foreach ($pair in $Matches[1].Trim().Split('&')) {
            $equals = $pair.IndexOf('=')
            if ($equals -gt 0) { $fields[$pair.Substring(0, $equals)] = $pair.Substring($equals + 1) }
        }
        if (-not $fields.ContainsKey('UserID') -or -not $fields.ContainsKey('LabID')) { continue }
        $key = Get-LabSessionKey $origin $fields['UserID'] $fields['LabID']
        if (-not $map.ContainsKey($key)) { $map[$key] = New-Object 'System.Collections.Generic.List[datetime]' }
        $map[$key].Add($time)
    }
    return $map
}

function Resolve-LabStart($fields, $startMap) {
    if (-not $fields['__Time']) { return $null }
    $key = Get-LabSessionKey $fields['__host'] $fields['UserID'] $fields['LabID']
    if (-not $startMap.ContainsKey($key)) { return $null }
    $best = $null
    foreach ($time in $startMap[$key]) {
        if ($time -le $fields['__Time'] -and (-not $best -or $time -gt $best)) { $best = $time }
    }
    return $best
}

function Assert-WaitWindow([datetime]$startAt, [datetime]$now, [int]$maxSeconds) {
    $elapsed = ($now - $startAt).TotalSeconds
    if ($elapsed -lt 0 -or $elapsed -gt $maxSeconds) {
        throw "延时模式中止：本地经过时间 $elapsed 秒不在 0..RealTimeMax=$maxSeconds 秒内；未发送本条记录。请检查抓包会话和本机时间。"
    }
}

$tmp = $null
try {
# ---------- 1. 从日志切出提交 ----------
$raw = Get-Content $LogPath -Raw -Encoding UTF8
$allChunks = [regex]::Split($raw, '(?m)^================ #')
$chunks = $allChunks | Where-Object { $_ -match '(?m)^POST https?://[^/\s]+/ServiceAPI/UpdateRecord(?:\s|$|\?)' }
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
            $f['__Time'] = Get-ChunkTime $c
            $subs += , $f
        }
    }
}
if (-not $subs) { throw "没能从日志里解析出提交体" }
if ($OnlyLab) {
    $subs = @($subs | Where-Object { [string]$_['LabID'] -eq $OnlyLab })
    if (-not $subs) { throw "日志里没有 LabID=$OnlyLab 的提交" }
}
$rawCount = $subs.Count
# 去重：同一 RecordID + FileName 只保留一条（客户端一次提交会连发 3 遍）
# 有的实验分两次下发：先空卷、后带标准答案卷。判据不是"谁更长"，而是
# 解密后谁的"真标准值格子"多；打平才回退 Content 长度（2026-11-13 修）。
# 位置按最后一次出现记，避免 [ordered]@{}.Values 保留首次位置、让 -Last 选错。
$groups = [ordered]@{}
$idx = 0
$dupeGroups = 0
foreach ($s1 in $subs) {
    $k = "$(Get-LabSessionKey $s1['__host'] $s1['UserID'] $s1['LabID'])|$($s1['RecordID'])|$($s1['FileName'])"
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
    $picked += @{ idx = $cands[$cands.Count - 1].idx; item = $best.item }
}
$subs = @($picked | Sort-Object { $_.idx } | ForEach-Object { $_.item })
if (-not $All) {
    if ($Last -lt 1) { $Last = 1 }
    if ($Last -lt $subs.Count) { $subs = @($subs[($subs.Count - $Last)..($subs.Count - 1)]) }
}
Log2 ("找到 {0} 条提交（{1} 组重复已合并，本次处理 {2} 条）" -f $rawCount, $dupeGroups, $subs.Count)

# 在等待和发送前检查整批记录，缺少开始时间或会话过期时不发送任何记录。
if ($WaitRandomTime -and -not $Report) {
    if ($RealTimeMin -lt 60 -or $RealTimeMax -lt $RealTimeMin) {
        throw '延时模式要求 60 <= RealTimeMin <= RealTimeMax；未发送任何记录。'
    }
    $startMap = Get-LabStartMap $allChunks
    $preflightNow = Get-Date
    foreach ($f in $subs) {
        $startAt = Resolve-LabStart $f $startMap
        if (-not $startAt) {
            throw "延时模式中止：LabID=$($f['LabID']) / RecordID=$($f['RecordID']) 缺少不晚于提交时间的开始记录（SetLabTimeRecordStart）或提交时间戳；未发送任何记录。请补全抓包日志。"
        }
        Assert-WaitWindow $startAt $preflightNow $RealTimeMax
        $f['__StartAt'] = $startAt
    }
    Log2 '  延时模式只控制本地重放时刻；服务端是否更新结束时间未经验证，网页用时可能保持不变。'
}

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
    # 按真实经过的本地时间等待；DryRun 只预览，不等待和发送。
    $waitRt = $null
    if ($WaitRandomTime) {
        $startAt = $f['__StartAt']
        if (-not $startAt) { throw '延时模式中止：缺少已校验的开始时间，未发送本条记录。' }
        Assert-WaitWindow $startAt (Get-Date) $RealTimeMax
        $want = Get-RandomRealTime -MinSeconds $RealTimeMin -MaxSeconds $RealTimeMax
        $targetAt = $startAt.AddSeconds($want)
        Log2 ("  进实验时间 {0}，目标用时 {1} 分 {2:00} 秒 → 计划 {3} 提交" -f $startAt.ToString('HH:mm:ss'), [int][Math]::Floor($want / 60), ($want % 60), $targetAt.ToString('HH:mm:ss'))
        if ($Apply) {
            while ((Get-Date) -lt $targetAt) {
                $remaining = [int][Math]::Floor(($targetAt - (Get-Date)).TotalSeconds)
                Log2 ("    等待中… 还剩 {0} 分 {1:00} 秒" -f [int][Math]::Floor($remaining / 60), ($remaining % 60))
                Start-Sleep -Seconds ([Math]::Min(60, [Math]::Max(1, $remaining)))
            }
            $afterWait = Get-Date
            Assert-WaitWindow $startAt $afterWait $RealTimeMax
            $waitRt = [int][Math]::Max(1, [Math]::Floor(($afterWait - $startAt).TotalSeconds))
            Log2 ("  本地经过 {0} 秒（不代表服务端用时）" -f $waitRt)
        } else {
            $waitRt = $want
            Log2 '  [DryRun] 未等待，未发送。'
        }
    }
    # 优先级：保留原值 > 延时模式经过时间 > 随机秒数 > 固定秒数。
    $rtNow = $null
    if ($waitRt) { $rtNow = $waitRt }
    elseif ($RandomTime) { $rtNow = Get-RandomRealTime -MinSeconds $RealTimeMin -MaxSeconds $RealTimeMax }
    elseif ($RealTime -gt 0) { $rtNow = $RealTime }
    if ($rtNow -and -not $KeepRealTime) {
        $userNode = $doc.SelectSingleNode('//Title/User')
        if ($userNode) {
            $timeNode = $userNode.SelectSingleNode('Time')
            if (-not $timeNode) { $timeNode = $doc.CreateElement('Time'); $userNode.AppendChild($timeNode) | Out-Null }
            $rtNode = $timeNode.SelectSingleNode('RealTime')
            if (-not $rtNode) { $rtNode = $doc.CreateElement('RealTime'); $timeNode.AppendChild($rtNode) | Out-Null }
            $rtNode.InnerText = "$rtNow"
            Log2 ("  用时 RealTime -> {0} 秒" -f $rtNow)
        } else { Write-Warning "找不到 Title/User 节点，用时未修改（$tag）" }
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

    if ($WaitRandomTime) { Assert-WaitWindow $f['__StartAt'] (Get-Date) $RealTimeMax }
    # 重放目标：-Server > 抓包日志请求行里的真实地址 > body 里的 ServerIP 字段。
    # 旧版这里写死过一个内网地址，换机房/换学校就发错地方（2026-11-13 修）。
    $targetServer = ''
    if ($Server) { $targetServer = $Server.TrimEnd('/') }
    elseif ($f.ContainsKey('__host') -and $f['__host']) { $targetServer = $f['__host'] }
    elseif ($f.ContainsKey('ServerIP') -and $f['ServerIP']) { $targetServer = $f['ServerIP'] }
    if (-not $targetServer) {
        Write-Warning "  日志里没有请求行，分不清服务端地址，跳过 $tag（可用 -Server http://ip:port 指定）"
        continue
    }
    # 兼容 PowerShell 5.1 / 7：5.1 没有 -SkipHttpErrorCheck，用 try/catch 取响应体
    $savedProxy = [System.Net.WebRequest]::DefaultWebProxy
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $null   # 直连，别把重放也塞进抓包日志
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $r = Invoke-WebRequest "$targetServer/ServiceAPI/UpdateRecord" -Method POST `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/x-www-form-urlencoded' `
                    -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
            $code = [string]$r.Content; $status = [int]$r.StatusCode
        } else {
            $r = Invoke-WebRequest "$targetServer/ServiceAPI/UpdateRecord" -Method POST `
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

} finally {
if ($KeepTemp -and $tmp) {
    Log2 ("  临时文件保留在：{0}" -f $tmp)
} elseif ($tmp) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:scoreTmp) { Remove-Item $script:scoreTmp -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:decFlaky -gt 0) {
    Log2 ("  （组件调用失败后重试过 {0} 次）" -f $script:decFlaky)
}
}
Log2 ""
if ($Apply) { Log2 ("完成：{0}/{1} 条成功" -f $okCount, $subs.Count) }
else { Log2 "以上为预览。加 -Apply 才会真正提交。" }
