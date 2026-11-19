# Copilot CLI が手元に残している過去の会話を探す。会話の記録は読むだけで、書き換えない。
#
# 探す:      search.ps1 見積もり 佐藤            両方を含む発言を、新しい順に
#            search.ps1 見積もり -Days 30 -Max 10
# 前後を見る: search.ps1 -Session c359c385 -At 2026-11-17T13:19:09Z -Around 4
# 全部読む:   search.ps1 -Session c359c385 -All        未記録の会話をログに起こすときなど
# ログを探す: search.ps1 見積もり 佐藤 -Memory          記憶のフォルダの memory\*.md を、話題（## の見出し）ごとに
#
# 記録の場所: $env:COPILOT_HOME（無ければ ~/.copilot）の session-state\<id>\events.jsonl と workspace.yaml。
# 記録の大半はツールの出力などで、発言と返事は1%もない。そこで、発言と返事だけを抜き出した写し（索引）を
# %LOCALAPPDATA%\Fumi\session-index\<id>.tsv に持ち、それを探す。写しは記録より古ければ作り直し、
# 記録が消えた会話（/session delete など）の写しは消す。
# Copilot CLI の内部の形なので、変わったら読めなくなる。そのときはそう伝える。
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Query,
    [int]$Days = 180,
    [int]$Max = 20,
    [string]$Session,
    [string]$At,
    [int]$Around = 3,
    [switch]$All,
    [int]$Budget = 15000,
    [switch]$IncludeCurrent,
    [switch]$Memory,
    [string]$MemoryDir,
    [string]$Root,
    [string]$IndexDir
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SnippetChars = 160
$ShowChars = 800
# -All は、読む側（AI）のトークンを食いすぎないように、全体を -Budget 文字までにする。
# 要点を起こすには「何を頼まれ、最後にどうなったか」が分かれば足りるので、本人の発言を長めに、返事を短めに残す。
# それでも超えるときは、頭と終わりを残して真ん中を省く。
$AllUserChars = 300
$AllAssistantChars = 150
# 発言の行だけを先に見分ける（JSON の空白の有無に関わらず）
$MessageLine = [regex]'"type"\s*:\s*"(user|assistant)\.message"'
$Utf8 = New-Object System.Text.UTF8Encoding $false

$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }

# ---- ログを探す（-Memory）----
# ファイルを丸ごと読ませないために、当たった話題だけを、見出しと数行に切って返す。
if ($Memory) {
    $SectionLines = 8
    $SectionChars = 600
    $words = @($Query | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($words.Count -eq 0) { Write-Output '使い方: search.ps1 言葉 [言葉...] -Memory [-Max 10]'; exit 1 }
    if (-not $MemoryDir) {
        $configPath = Join-Path $copilotHome 'fumi.json'
        if (Test-Path -LiteralPath $configPath) { $MemoryDir = [string](Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).memory_dir }
    }
    if (-not $MemoryDir) { Write-Output "記憶のフォルダが分かりません（$copilotHome\fumi.json の memory_dir）"; exit 1 }
    $logDir = Join-Path $MemoryDir 'memory'
    if (-not (Test-Path -LiteralPath $logDir)) { Write-Output "ログがまだありません: $logDir"; exit 0 }
    if (-not $PSBoundParameters.ContainsKey('Max')) { $Max = 10 }

    $found = New-Object System.Collections.Generic.List[string]
    $more = $false
    $files = @(Get-ChildItem -LiteralPath $logDir -Filter '*.md' -File | Sort-Object Name -Descending)
    foreach ($file in $files) {
        # 新しい順に探しているので、そろったら古いログは開かない
        if ($found.Count -ge $Max) { $more = $true; break }
        # 一つ目の言葉を含まないファイルは開かない
        if (-not (Select-String -LiteralPath $file.FullName -Pattern $words[0] -SimpleMatch -Encoding UTF8 -Quiet)) { continue }
        $sections = New-Object System.Collections.Generic.List[object]
        $current = $null
        foreach ($line in [IO.File]::ReadAllLines($file.FullName, $Utf8)) {
            if ($line.StartsWith('## ')) { $current = New-Object System.Collections.Generic.List[string]; $sections.Add($current) }
            if ($null -ne $current) { $current.Add($line) }
        }
        # 新しい話題（ファイルの下の方）から
        for ($i = $sections.Count - 1; $i -ge 0; $i--) {
            $text = $sections[$i] -join "`n"
            $all = $true
            foreach ($w in $words) { if ($text.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $all = $false; break } }
            if (-not $all) { continue }
            if ($found.Count -ge $Max) { $more = $true; break }
            $body = @($sections[$i] | Select-Object -First $SectionLines) -join "`n"
            if ($body.Length -gt $SectionChars) { $body = $body.Substring(0, $SectionChars) + '…' }
            $found.Add("### $($file.BaseName)`n$body")
        }
    }
    if ($found.Count -eq 0) { Write-Output "ログに見つかりませんでした（$($files.Count) 日分）: $($words -join ' ')"; exit 0 }
    $note = if ($more) { "新しい順に $($found.Count) 話題。もっと古いものもある。言葉を足して絞るか、-Max で増やす" } else { "$($found.Count) 話題" }
    Write-Output "# ログの「$($words -join ' ')」（$note）"
    foreach ($f in $found) { Write-Output ''; Write-Output $f }
    exit 0
}

if (-not $Root) { $Root = Join-Path $copilotHome 'session-state' }
if (-not $IndexDir) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
    $IndexDir = Join-Path $base 'Fumi\session-index'
}
if (-not (Test-Path -LiteralPath $Root)) { Write-Output "会話の記録が見つかりません: $Root"; exit 1 }
if (-not (Test-Path -LiteralPath $IndexDir)) { New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null }

function Read-Workspace([string]$dir) {
    $info = @{ name = ''; cwd = '' }
    $path = Join-Path $dir 'workspace.yaml'
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ($line -match '^(name|cwd):\s*(.*)$') { $info[$Matches[1]] = $Matches[2].Trim().Trim('"', "'") }
        }
    }
    $info
}

function Get-LocalTime([string]$ts) {
    try { [DateTimeOffset]::Parse($ts).LocalDateTime } catch { $null }
}

function Format-Flat([string]$text) {
    ($text -replace '\s+', ' ').Trim()
}

# Copilot が書き込み中でも開けるように、書き手と共有して全行を読む
function Read-SharedLines([string]$path) {
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, $Utf8)
    $lines = New-Object System.Collections.Generic.List[string]
    try { while ($null -ne ($l = $reader.ReadLine())) { $lines.Add($l) } } finally { $reader.Dispose() }
    , $lines
}

# 写しの1行: 時刻(UTC の記録のまま) TAB 話し手(本人/秘書) TAB 本文を1行にしたもの
function Update-Index($s) {
    $events = Get-Item -LiteralPath $s.events
    if ((Test-Path -LiteralPath $s.index) -and (Get-Item -LiteralPath $s.index).LastWriteTimeUtc -ge $events.LastWriteTimeUtc) { return }
    $out = New-Object System.Text.StringBuilder
    foreach ($line in (Read-SharedLines $s.events)) {
        if (-not $MessageLine.IsMatch($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ($e.type -ne 'user.message' -and $e.type -ne 'assistant.message') { continue }
        $content = [string]$e.data.content
        if (-not $content) { continue }
        $speaker = if ($e.type -eq 'user.message') { '本人' } else { '秘書' }
        [void]$out.Append($e.timestamp).Append("`t").Append($speaker).Append("`t").Append((Format-Flat $content)).Append("`n")
    }
    $tmp = "$($s.index).$PID.tmp"
    [IO.File]::WriteAllText($tmp, $out.ToString(), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $s.index -Force
    # 次に比べるときのため、写しの時刻を記録の時刻にそろえる
    (Get-Item -LiteralPath $s.index).LastWriteTimeUtc = $events.LastWriteTimeUtc
}

function Read-Index($s) {
    foreach ($line in [IO.File]::ReadAllLines($s.index, $Utf8)) {
        $parts = $line.Split("`t", 3)
        if ($parts.Count -lt 3) { continue }
        [pscustomobject]@{ stamp = $parts[0]; time = Get-LocalTime $parts[0]; speaker = $parts[1]; text = $parts[2] }
    }
}

$sessions = @(Get-ChildItem -LiteralPath $Root -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'events.jsonl') } |
    ForEach-Object {
        $events = Join-Path $_.FullName 'events.jsonl'
        [pscustomobject]@{ id = $_.Name; dir = $_.FullName; events = $events; index = Join-Path $IndexDir "$($_.Name).tsv"; updated = (Get-Item -LiteralPath $events).LastWriteTime }
    } |
    Sort-Object updated -Descending)

# 記録が消えた会話の写しは消す（本人が消した会話を残さない）
$alive = @{}
foreach ($s in $sessions) { $alive["$($s.id).tsv"] = $true }
Get-ChildItem -LiteralPath $IndexDir -File -Filter '*.tsv' | Where-Object { -not $alive.ContainsKey($_.Name) } | Remove-Item -Force
Get-ChildItem -LiteralPath $IndexDir -File -Filter '*.tmp' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } | Remove-Item -Force

# ---- 前後を見る・全部読む ----
if ($Session) {
    $target = @($sessions | Where-Object { $_.id -like "$Session*" })
    if ($target.Count -ne 1) { Write-Output "会話が $($target.Count) 件当たりました。ID をもう少し長く指定してください: $Session"; exit 1 }
    $s = $target[0]
    Update-Index $s
    $ws = Read-Workspace $s.dir
    $messages = @(Read-Index $s)
    $center = 0
    if ($At) {
        $atTime = Get-LocalTime $At
        if (-not $atTime) { try { $atTime = [datetime]::Parse($At) } catch { Write-Output "時刻が読めません: $At"; exit 1 } }
        $best = [double]::MaxValue
        for ($i = 0; $i -lt $messages.Count; $i++) {
            $diff = [math]::Abs(($messages[$i].time - $atTime).TotalSeconds)
            if ($diff -lt $best) { $best = $diff; $center = $i }
        }
    }
    $format = {
        param($m, [int]$limit)
        $text = $m.text
        if ($text.Length -gt $limit) { $text = $text.Substring(0, $limit) + '…' }
        "- $($m.time.ToString('yyyy-MM-dd HH:mm')) $($m.speaker) [$($m.stamp)]: $text"
    }
    Write-Output "## $($s.id.Substring(0, [math]::Min(8, $s.id.Length))) 「$($ws.name)」 $($ws.cwd)（$($messages.Count) 件）"

    if (-not $All) {
        $from = [math]::Max(0, $center - $Around); $to = [math]::Min($messages.Count - 1, $center + $Around)
        for ($i = $from; $i -le $to; $i++) { Write-Output (& $format $messages[$i] $ShowChars) }
        exit 0
    }

    $lines = @(foreach ($m in $messages) { & $format $m $(if ($m.speaker -eq '本人') { $AllUserChars } else { $AllAssistantChars }) })
    $total = ($lines | Measure-Object -Property Length -Sum).Sum
    if ($total -le $Budget) { $lines; exit 0 }
    # 頭と終わりから、それぞれ予算の半分まで取り、真ん中を省く
    $half = [int]($Budget / 2)
    $head = 0; $used = 0
    while ($head -lt $lines.Count -and $used + $lines[$head].Length -le $half) { $used += $lines[$head].Length; $head++ }
    $tail = 0; $used = 0
    while ($tail -lt ($lines.Count - $head) -and $used + $lines[$lines.Count - 1 - $tail].Length -le $half) { $used += $lines[$lines.Count - 1 - $tail].Length; $tail++ }
    if ($head -gt 0) { $lines[0..($head - 1)] }
    Write-Output "（中略: $($lines.Count - $head - $tail) 件。見たいところは -At <時刻> で読む）"
    if ($tail -gt 0) { $lines[($lines.Count - $tail)..($lines.Count - 1)] }
    exit 0
}

# ---- 探す ----
$words = @($Query | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
if ($words.Count -eq 0) { Write-Output '使い方: search.ps1 言葉 [言葉...] [-Days 180] [-Max 20]  /  search.ps1 -Session <ID> -At <時刻> [-Around 3]  /  search.ps1 -Session <ID> -All'; exit 1 }

$since = (Get-Date).AddDays(-$Days)
$candidates = @($sessions | Where-Object { $_.updated -ge $since })
# 今の会話（一番新しく、今も書かれているもの）は、探している言葉そのものが当たるので外す
if (-not $IncludeCurrent -and $candidates.Count -gt 0 -and $candidates[0].updated -ge (Get-Date).AddMinutes(-10)) {
    $candidates = @($candidates | Select-Object -Skip 1)
}

$hits = New-Object System.Collections.Generic.List[object]
foreach ($s in $candidates) {
    Update-Index $s
    # 一つ目の言葉で写しをざっと絞り、残りの言葉は本文で確かめる
    $lines = Select-String -LiteralPath $s.index -Pattern $words[0] -SimpleMatch -Encoding UTF8 | ForEach-Object { $_.Line }
    foreach ($line in $lines) {
        $parts = $line.Split("`t", 3)
        if ($parts.Count -lt 3) { continue }
        $text = $parts[2]
        $all = $true
        foreach ($w in $words) { if ($text.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $all = $false; break } }
        if (-not $all) { continue }
        $pos = $text.IndexOf($words[0], [StringComparison]::OrdinalIgnoreCase)
        $start = [math]::Max(0, $pos - [int]($SnippetChars / 2))
        $len = [math]::Min($SnippetChars, $text.Length - $start)
        $snippet = $text.Substring($start, $len)
        if ($start -gt 0) { $snippet = '…' + $snippet }
        if ($start + $len -lt $text.Length) { $snippet = $snippet + '…' }
        $hits.Add([pscustomobject]@{ session = $s; time = Get-LocalTime $parts[0]; stamp = $parts[0]; speaker = $parts[1]; snippet = $snippet })
    }
}

if ($hits.Count -eq 0) { Write-Output "見つかりませんでした（$($candidates.Count) 件の会話、$Days 日分）: $($words -join ' ')"; exit 0 }

$shown = @($hits | Sort-Object time -Descending | Select-Object -First $Max)
Write-Output "# 「$($words -join ' ')」 $($hits.Count) 件（新しい順に $($shown.Count) 件）"
foreach ($group in ($shown | Group-Object { $_.session.id })) {
    $s = $group.Group[0].session
    $ws = Read-Workspace $s.dir
    Write-Output ''
    Write-Output "## $($s.id.Substring(0, [math]::Min(8, $s.id.Length))) 「$($ws.name)」 $($ws.cwd)"
    foreach ($h in $group.Group) {
        Write-Output "- $($h.time.ToString('yyyy-MM-dd HH:mm')) $($h.speaker) [$($h.stamp)]: $($h.snippet)"
    }
}
Write-Output ''
Write-Output '前後を見る: search.ps1 -Session <上の8文字> -At <[ ] の中の時刻>'
