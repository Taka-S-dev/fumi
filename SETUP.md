# セットアップ手順（AI 向け）

この文書は、GitHub Copilot CLI（またはほかのコーディング AI）が読んで、Windows の PC に Fumi（仕事の秘書）の記憶の機能を入れるための手順書。人が読んでも分かるように書いてある。

本人は、このフォルダで `copilot` を立ち上げて、次のように頼めばよい。

> SETUP.md に従って、Fumi をセットアップして

---

## 0. 先に守ること

セットアップの間、次を必ず守る。手順と食い違ったら、こちらを優先する。

1. **書いてよい場所は、下の「入れるもの」の表にある場所だけ。** それ以外のファイル（ほかのスキル、ほかのフック、`settings.json`、`config.json`、`mcp-config.json` など）には触らない。
2. **上書きする前に退避する。** 置き先に同じ名前のファイルがあり、中身が違うときは、`<名前>.bak-YYYYMMDD-HHmmss` として同じフォルダに残してから置く。中身が同じなら何もしない。
3. **PowerShell のスクリプト（`.ps1`）は、コピーで置く。** 開いて保存し直さない。日本語を含み、UTF-8（BOM 付き）で保存してあるので、保存し直して BOM が消えると Windows PowerShell 5.1 で文字化けして動かなくなる。
4. **本人に聞くのは、記憶のフォルダの場所だけ。** ほかは手順の通りに決める。迷ったら、変更をせずに止めて、何に迷ったかを伝える。
5. **何度やっても同じ結果になるようにする。** 2回目以降は、すでに正しく入っているものは飛ばす。
6. **最後に報告する。** 何を置いたか、何を退避したか、確かめた結果を、下の「9. 報告」の形で伝える。

---

## 1. 入れるもの

`<パッケージ>` はこの SETUP.md があるフォルダ。`<COPILOT_HOME>` は環境変数 `COPILOT_HOME`、無ければ `%USERPROFILE%\.copilot`。

| パッケージの中 | 置き先 | 扱い |
|---|---|---|
| `copilot\copilot-instructions.md` | `<COPILOT_HOME>\copilot-instructions.md` | 無ければコピー。あれば「4.」の通りに足す・差し替える |
| `copilot\skills\session-search\`（`SKILL.md`、`search.ps1`） | `<COPILOT_HOME>\skills\session-search\` | コピー（同じ名前で中身が違えば退避してから） |
| `copilot\hooks\fumi-hooks.json`、`copilot\hooks\fumi-hook.ps1` | `<COPILOT_HOME>\hooks\` | コピー（同じ名前で中身が違えば退避してから）。同じフォルダのほかのフックには触らない |
| （作る） | `<COPILOT_HOME>\fumi.json` | `memory_dir` を書く。ほかの項目があれば残す |
| （作る） | 記憶のフォルダ（本人に聞く） | `USER.md`、`MEMORY.md`、`TOOLS.md`、`memory\` を、無いものだけ作る |

スクリプトが自分で作るもの（セットアップでは作らなくてよい）:

- `%LOCALAPPDATA%\Fumi\session-index\`: 過去の会話を探すための写し（`search.ps1` が作る）
- `<COPILOT_HOME>\fumi-pending.json`: 書き忘れた会話の一覧（`fumi-hook.ps1` が作る）

`later\` フォルダの中身は、今は入れない。

---

## 2. 前提を確かめる

PowerShell で次を実行し、結果を控える。

```powershell
copilot --version
$PSVersionTable.PSVersion.ToString()
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
$copilotHome; Test-Path $copilotHome
Get-ExecutionPolicy -List | Format-Table -AutoSize
$env:LOCALAPPDATA
```

| 確かめること | よいとき | だめなとき |
|---|---|---|
| `copilot --version` | 版が出る | Copilot CLI が入っていない。止めて本人に伝える |
| PowerShell の版 | 5.1 以上 | 止めて本人に伝える |
| `<COPILOT_HOME>` | 存在する | 一度 `copilot` を立ち上げて閉じてもらってから、やり直す |
| 実行ポリシー | `MachinePolicy` と `UserPolicy` が `Undefined`、または `RemoteSigned`・`Unrestricted`・`Bypass` | どちらかが `AllSigned` か `Restricted` なら、組織の設定でスクリプトが止められている。`-ExecutionPolicy Bypass` でも動かない。セットアップは続けてよいが、スキルの検索とフックは動かないと報告する（記憶の読み書き自体は、指示の文書だけで動く） |

---

## 3. 記憶のフォルダを決める

本人に1回だけ聞く。

> 記憶（USER.md、MEMORY.md、TOOLS.md と、日々のログ）を置くフォルダはどこにしますか？ Obsidian で見たいなら、vault の中のフォルダ（例: `<vault>\秘書`）がおすすめです。

- Obsidian の vault の候補は `%APPDATA%\obsidian\obsidian.json` の `vaults` の `path` にある。聞くときに候補として見せてよい。
- 答えのフォルダが無ければ作ってよいか聞き、よければ作る。
- すでに `fumi.json` に `memory_dir` があり、そのフォルダが存在するなら、聞かずにそれを使ってよい（2回目のセットアップ）。

---

## 4. ファイルを置く

### 4-1. スキルとフック

置き先に同名のファイルがあれば、中身を比べ（`Get-FileHash`）、違うときだけ退避してから置く。

```powershell
$pkg = '<パッケージの絶対パス>'
$copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Install-File($from, $toDir) {
    New-Item -ItemType Directory -Force -Path $toDir | Out-Null
    $to = Join-Path $toDir (Split-Path -Leaf $from)
    if (Test-Path -LiteralPath $to) {
        if ((Get-FileHash -LiteralPath $to).Hash -eq (Get-FileHash -LiteralPath $from).Hash) { return "同じなので飛ばした: $to" }
        Copy-Item -LiteralPath $to -Destination "$to.bak-$stamp"
        Copy-Item -LiteralPath $from -Destination $to -Force
        return "退避して置いた: $to（退避先 $to.bak-$stamp）"
    }
    Copy-Item -LiteralPath $from -Destination $to
    return "置いた: $to"
}

Install-File "$pkg\copilot\skills\session-search\SKILL.md"  "$copilotHome\skills\session-search"
Install-File "$pkg\copilot\skills\session-search\search.ps1" "$copilotHome\skills\session-search"
Install-File "$pkg\copilot\hooks\fumi-hooks.json"                "$copilotHome\hooks"
Install-File "$pkg\copilot\hooks\fumi-hook.ps1"            "$copilotHome\hooks"
```

置いたあと、スクリプトの先頭が BOM（`EF BB BF`）のままか確かめる。

```powershell
foreach ($f in "$copilotHome\skills\session-search\search.ps1", "$copilotHome\hooks\fumi-hook.ps1") {
    $b = [IO.File]::ReadAllBytes($f)
    $one = $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    $two = $one -and $b[3] -eq 0xEF -and $b[4] -eq 0xBB -and $b[5] -eq 0xBF
    '{0}: {1}' -f $f, $(if ($two) { 'だめ（BOM が二重）' } elseif ($one) { 'よい' } else { 'だめ（BOM が無い）' })
}
```

どちらも `よい` であること。`だめ` なら、パッケージからコピーし直す（開いて保存し直さない）。

### 4-2. fumi.json

`memory_dir` だけを書く。ファイルがすでにあれば、ほかの項目は残す。パスの `\` は JSON の中で `\\` になるが、`ConvertTo-Json` に任せればよい。

```powershell
$memoryDir = '<3. で決めたフォルダの絶対パス>'
$path = Join-Path $copilotHome 'fumi.json'
$config = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
if ($config.PSObject.Properties['memory_dir']) { $config.memory_dir = $memoryDir } else { $config | Add-Member -NotePropertyName memory_dir -NotePropertyValue $memoryDir }
[IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
Get-Content -LiteralPath $path -Raw -Encoding UTF8
```

### 4-3. copilot-instructions.md

パッケージの `copilot\copilot-instructions.md` は、先頭の `<!-- fumi: begin v1 ... -->` から末尾の `<!-- fumi: end -->` までが一つのまとまり。

| 置き先の状態 | すること |
|---|---|
| ファイルが無い | パッケージのファイルをそのままコピーする |
| ファイルがあり、`fumi: begin` が無い | 退避してから、今の中身の末尾に空行を1つ入れて、パッケージのファイルの中身を全部足す。今の中身は1文字も変えない |
| ファイルがあり、`fumi: begin` から `end` がある | 退避してから、その範囲だけをパッケージのファイルの中身に差し替える。範囲の外は1文字も変えない |
| `begin` があるのに `end` が無い、または2組以上ある | 何もしないで止め、本人に伝える |

自分で編集せず、次をそのまま実行する（本人の今の指示を壊さないため）。

```powershell
$src = Join-Path $pkg 'copilot\copilot-instructions.md'
$dst = Join-Path $copilotHome 'copilot-instructions.md'
$block = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8).Trim()
$utf8 = New-Object Text.UTF8Encoding $false
if (-not (Test-Path -LiteralPath $dst)) {
    [IO.File]::WriteAllText($dst, "$block`n", $utf8); "置いた: $dst"
} else {
    $cur = [IO.File]::ReadAllText($dst, [Text.Encoding]::UTF8)
    $begins = [regex]::Matches($cur, '<!-- fumi: begin').Count
    $ends = [regex]::Matches($cur, '<!-- fumi: end -->').Count
    if ($begins -eq 0 -and $ends -eq 0) {
        $next = $cur.TrimEnd() + "`n`n" + $block + "`n"
    } elseif ($begins -eq 1 -and $ends -eq 1) {
        $b = $cur.IndexOf('<!-- fumi: begin'); $e = $cur.IndexOf('<!-- fumi: end -->')
        if ($e -lt $b) { throw "目印の順番がおかしいので止めた: $dst" }
        $e += '<!-- fumi: end -->'.Length
        $next = $cur.Substring(0, $b) + $block + $cur.Substring($e)
    } else {
        throw "目印が $begins 個（begin）と $ends 個（end）あるので止めた。本人に伝える: $dst"
    }
    if ($next -eq $cur) { "同じなので飛ばした: $dst" }
    else {
        Copy-Item -LiteralPath $dst -Destination "$dst.bak-$stamp"
        [IO.File]::WriteAllText($dst, $next, $utf8)
        "退避して書き換えた: $dst（退避先 $dst.bak-$stamp）"
    }
}
```

`止めた` と出たら、何も書き換わっていない。本人に伝えて、そこで 4-3 だけ止める（ほかの手順は続けてよい）。

### 4-4. 記憶のフォルダの中身

記憶のフォルダに、無いものだけを作る。すでにあるファイルは開かない・変えない（本人の記憶が入っている）。

1. `memory\` フォルダ。
2. `USER.md` と `MEMORY.md`: `copilot-instructions.md` の末尾の「形」の通りに作る。
3. `TOOLS.md`: 同じく「形」の通りに作り、「スキル・MCP」の節に、この PC に入っているものを並べる（ひな形のコメントの例は消す）。
   - スキル: `<COPILOT_HOME>\skills\` と `%USERPROFILE%\.agents\skills\` の各フォルダの `SKILL.md` を開き、`description` から「名前: 使う場面」を1行にする（`session-search` は書かなくてよい。指示の文書が使い方を持っている）。
   - MCP サーバー: `<COPILOT_HOME>\mcp-config.json` のサーバーごとに、名前と、何に使うものかを1行にする。分からなければ名前だけでよい。
   - ファイルや外のものを書き換えるものには「（確認してから）」と付ける。

---

## 5. 確かめる

順に実行し、結果を控える。だめなものがあっても、あとの確認は続ける。

### 5-1. 指示の文書が読まれるか

```powershell
copilot instruction list
```

一覧に `<COPILOT_HOME>\copilot-instructions.md` が出ること。

### 5-2. ログの検索（-Memory）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$copilotHome\skills\session-search\search.ps1" setup-check -Memory; "exit=$LASTEXITCODE"
```

`ログがまだありません` か `ログに見つかりませんでした` と出て、`exit=0` であること。`記憶のフォルダが分かりません` と出たら、4-2 をやり直す。

### 5-3. 過去の会話の検索

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$copilotHome\skills\session-search\search.ps1" copilot -Days 30 -Max 3; "exit=$LASTEXITCODE"
```

`# 「copilot」 …件` か `見つかりませんでした` と出て、`exit=0` であること。初回は写しを作るので数秒かかることがある。`%LOCALAPPDATA%\Fumi\session-index\` に `.tsv` ができていること（会話が1件以上あれば）。

### 5-4. フック

本物の会話を使わずに、空振りで呼んで、エラーにならないことを確かめる。

```powershell
$before = if (Test-Path "$env:TEMP\fumi-hook.log") { (Get-Item "$env:TEMP\fumi-hook.log").Length } else { 0 }
'{"sessionId":"setup-check-0000","cwd":"C:\\"}' | powershell -NoProfile -ExecutionPolicy Bypass -File "$copilotHome\hooks\fumi-hook.ps1" agentStop; "exit=$LASTEXITCODE"
$after = if (Test-Path "$env:TEMP\fumi-hook.log") { (Get-Item "$env:TEMP\fumi-hook.log").Length } else { 0 }
"log grew: $($after -gt $before)"
Get-Content "$copilotHome\hooks\fumi-hooks.json" -Raw | ConvertFrom-Json | Out-Null; "fumi-hooks.json is valid JSON"
```

何も出力されず `exit=0`、`log grew: False`、`fumi-hooks.json is valid JSON` であること。ログが増えていたら、その中身を報告する。

---

## 6. 本人と一緒に確かめる（セットアップのあと）

ここからは本物の会話が要るので、本人に頼む。手順を見せて、やってもらう。

1. `copilot` を立ち上げ直し、`/env` でフック（fumi）とスキル（session-search）が読み込まれているか見る。
2. 「私の呼び方は〇〇。覚えておいて」と言う。`USER.md` に書かれるか見る。
3. 何か作業の話をして「〇〇に決めた」と言う。記憶のフォルダの `memory\今日の日付.md` に書かれるか見る。
4. Copilot を閉じて立ち上げ直し、「前に何を決めたっけ？」と聞く。日付付きで答えるか見る。
5. 「この会話はログに書かないで」と頼んで、作業の話を3往復する。`<COPILOT_HOME>\fumi-pending.json` にその会話が入るか見る。閉じて立ち上げ直し、「前の会話を1件、ログに起こしました」と言われるか見る。
6. 「それは忘れて」と言って、ログと要約から消えるか見る。

記憶のフォルダが立ち上げた場所の外にあると、読み書きのたびに許可を求められる。毎回なら、許可のときに「このフォルダを覚える」を選ぶか、`copilot --add-dir <記憶のフォルダ>` で立ち上げるよう伝える。

---

## 7. 更新するとき

新しいパッケージで、この SETUP.md をもう一度実行する。

- スキルとフックは、中身が違うものだけ退避して置き換わる。
- `copilot-instructions.md` は、`fumi: begin` から `end` の範囲だけが差し替わる。
- `fumi.json` と記憶のフォルダの中身は変わらない（本人の記憶はそのまま）。

---

## 8. 取り外すとき

本人に確かめてから、次を消す。記憶のフォルダ（本人の記憶）は、本人が消すと言わない限り残す。

```powershell
Remove-Item "$copilotHome\skills\session-search" -Recurse
Remove-Item "$copilotHome\hooks\fumi-hooks.json", "$copilotHome\hooks\fumi-hook.ps1"
Remove-Item "$copilotHome\fumi-pending.json" -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Fumi\session-index" -Recurse -ErrorAction SilentlyContinue
```

`copilot-instructions.md` は、`fumi: begin` から `end` までの範囲だけを消す（範囲の外は残す）。範囲しかなかったなら、ファイルごと消してよい。`fumi.json` は `memory_dir` の項目だけを消す（ほかの項目が無ければファイルごと）。

---

## 9. 報告

最後に、次の形で本人に伝える。

```
## セットアップの結果

置いたもの:
- （パス）: 置いた / 同じなので飛ばした / 退避して置いた（退避先）

記憶のフォルダ: （パス）。作ったもの: （USER.md など）。すでにあったので触らなかったもの: （…）

確かめた結果:
- 5-1 指示の文書: よい / だめ（理由）
- 5-2 ログの検索: よい / だめ（出力）
- 5-3 過去の会話の検索: よい / だめ（出力）
- 5-4 フック: よい / だめ（出力）
- 実行ポリシー: （結果。止められていれば、何が動かないか）

次にやってほしいこと: 6. の確認（立ち上げ直して試す）
```

---

## 付録: 困ったとき

| 起きたこと | 原因と直し方 |
|---|---|
| スクリプトが文字化けしたエラーで止まる（`InvalidLeftHandSide` など） | BOM が消えたか、二重になった。パッケージからコピーし直す |
| `このシステムではスクリプトの実行が無効になっている` | 実行ポリシー。2. の表の「だめなとき」 |
| `記憶のフォルダが分かりません` | `fumi.json` に `memory_dir` が無い、またはフォルダが無い。4-2 と 3. |
| フックが動いていないようだ | `/env` で fumi のフックが出るか。`%TEMP%\fumi-hook.log` にエラーが残っていないか。組織の設定でフックが止められていないか（`settings.json` の `disableAllHooks`） |
| 過去の会話の検索で何も当たらない | Copilot CLI の更新で会話の記録の形が変わった可能性がある。`<COPILOT_HOME>\session-state\` に `events.jsonl` があるか確かめ、本人に伝える。記憶（ログ）の検索はそのまま使える |
| 写しがおかしい | `%LOCALAPPDATA%\Fumi\session-index\` を消す。次に探したときに作り直される |
