# 書き忘れの見張り。Copilot CLI のフック（agentStop: 返事を終えるたび、sessionEnd: 会話を閉じるとき）から呼ばれる。
# その会話の記録を読み、記憶のフォルダに一度も書いていないまま2往復以上話していれば「未記録」の一覧に入れる。
# 書いたら一覧から外す。次の会話の最初に、秘書がこの一覧を見て、その会話をログに起こす。
#
# AI は使わない。会話の記録は読むだけ。書くのは一覧（$COPILOT_HOME\fumi-pending.json）だけ。
# 何が起きても Copilot の邪魔をしないよう、何も出力せず、終了コードは常に 0。エラーは %TEMP%\fumi-hook.log に残す。
param([string]$HookEvent = 'agentStop')

$MinTurns = 2
$WriteTools = 'edit', 'create', 'write', 'str_replace_editor', 'apply_patch'
$ShellTools = 'powershell', 'bash', 'shell'
$WriteCommand = [regex]'(?i)(Add-Content|Set-Content|Out-File|New-Item|Copy-Item|Move-Item|Remove-Item|WriteAllText|AppendAllText|WriteAllLines|AppendAllLines|>>?|\btee\b|\bsed\s+-i)'
$UserMessage = [regex]'"type"\s*:\s*"user\.message"'
$ToolStart = [regex]'"type"\s*:\s*"tool\.execution_start"'
# JSON として読む前に、書き込みに使うツールの行だけに絞る（相対パスで書いた場合も拾えるよう、場所では絞らない）
$CandidateTool = [regex]('"toolName"\s*:\s*"(' + (($WriteTools + $ShellTools) -join '|') + ')"')

$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
$logPath = Join-Path $env:TEMP 'fumi-hook.log'

function Write-HookLog([string]$message) {
    try { Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) [$HookEvent] $message" -Encoding UTF8 } catch { }
}

# 区切りを / にそろえ、小文字にし、末尾の / を落とす
function ConvertTo-NormalPath([string]$path) {
    ($path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-Field($object, [string[]]$names) {
    foreach ($n in $names) { if ($null -ne $object -and $object.PSObject.Properties[$n] -and $object.$n) { return [string]$object.$n } }
    return ''
}

try {
    # ---- 設定と、フックに渡された内容 ----
    $configPath = Join-Path $copilotHome 'fumi.json'
    if (-not (Test-Path -LiteralPath $configPath)) { exit 0 }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $memoryDir = [string]$config.memory_dir
    if (-not $memoryDir -or -not (Test-Path -LiteralPath $memoryDir)) { exit 0 }
    $memoryNorm = ConvertTo-NormalPath ([IO.Path]::GetFullPath($memoryDir))

    $payload = $null
    try {
        $raw = [Console]::In.ReadToEnd()
        if ($raw.Trim()) { $payload = $raw | ConvertFrom-Json }
    } catch { $payload = $null }
    $sessionId = Get-Field $payload 'sessionId', 'session_id'
    $transcript = Get-Field $payload 'transcriptPath', 'transcript_path'
    $cwd = Get-Field $payload 'cwd'

    $stateDir = Join-Path $copilotHome 'session-state'
    if (-not $transcript -and $sessionId) { $transcript = Join-Path (Join-Path $stateDir $sessionId) 'events.jsonl' }
    if (-not $transcript) {
        # 渡された内容が読めなかったときは、一番新しく書かれている会話を今の会話とみなす
        $latest = Get-ChildItem -LiteralPath $stateDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'events.jsonl') } |
            Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'events.jsonl')).LastWriteTime } -Descending |
            Select-Object -First 1
        if (-not $latest) { exit 0 }
        $transcript = Join-Path $latest.FullName 'events.jsonl'
        $sessionId = $latest.Name
    }
    if (-not (Test-Path -LiteralPath $transcript)) { exit 0 }
    if (-not $sessionId) { $sessionId = Split-Path -Leaf (Split-Path -Parent $transcript) }

    # ---- 会話の記録を読む ----
    $turns = 0
    $wrote = $false
    # Copilot が書き込み中でも開けるように、書き手と共有して開く
    $stream = New-Object IO.FileStream($transcript, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    $lines = New-Object System.Collections.Generic.List[string]
    try { while ($null -ne ($l = $reader.ReadLine())) { $lines.Add($l) } } finally { $reader.Dispose() }
    foreach ($line in $lines) {
        if ($UserMessage.IsMatch($line)) { $turns++; continue }
        if ($wrote -or -not $ToolStart.IsMatch($line)) { continue }
        if (-not $CandidateTool.IsMatch($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        $tool = [string]$e.data.toolName
        $arguments = $e.data.arguments
        if ($WriteTools -contains $tool) {
            $target = Get-Field $arguments 'path', 'file_path', 'filePath'
            if (-not $target) { continue }
            if (-not [IO.Path]::IsPathRooted($target) -and $cwd) { $target = Join-Path $cwd $target }
            $targetNorm = ConvertTo-NormalPath $target
            if ($targetNorm -eq $memoryNorm -or $targetNorm.StartsWith("$memoryNorm/")) { $wrote = $true }
        } elseif ($ShellTools -contains $tool) {
            $command = Get-Field $arguments 'command'
            if ((ConvertTo-NormalPath $command).Contains($memoryNorm) -and $WriteCommand.IsMatch($command)) { $wrote = $true }
        }
    }

    # ---- 未記録の一覧を直す ----
    $pendingPath = Join-Path $copilotHome 'fumi-pending.json'
    $pending = [ordered]@{}
    if (Test-Path -LiteralPath $pendingPath) {
        try {
            $saved = Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.sessions.PSObject.Properties) { $pending[$p.Name] = $p.Value }
        } catch { Write-HookLog "一覧が読めないので作り直す: $_" }
    }

    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $changed = $false
    if ($wrote) {
        if ($pending.Contains($sessionId)) { $pending.Remove($sessionId); $changed = $true }
    } elseif ($turns -ge $MinTurns) {
        $first = if ($pending.Contains($sessionId)) { $pending[$sessionId].first } else { $now }
        $pending[$sessionId] = [ordered]@{ cwd = $cwd; first = $first; last = $now; turns = $turns }
        $changed = $true
    }
    if (-not $changed) { exit 0 }

    $json = [ordered]@{ v = 1; sessions = $pending } | ConvertTo-Json -Depth 5
    $tmp = "$pendingPath.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $pendingPath -Force
} catch {
    Write-HookLog "$_"
}
exit 0
