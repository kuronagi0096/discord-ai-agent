# Discord から話せる Claude Code / Codex

Discord のチャンネルから、自分の PC で動いている Claude Code または Codex に話しかけて作業してもらうための仕組みです（Windows 用）。
プロジェクトごとに使うエージェントを選べます。

Codex は公式 `@openai/codex-sdk` で動きます。会話 ID は自動保存されるため、ボットを再起動しても会話を続けられます。
Codex は `workspace-write` サンドボックスかつ承認要求なしで動かし、登録した作業フォルダ内だけを書き換えます。

Claude Code を選んだプロジェクトでは、従来どおり公式プラグイン `discord@claude-plugins-official` を使います。
**1 プロジェクト = 1 ボット = 1 チャンネル = 1 つの AI セッション** で動かします。

話しかけられるのは、登録した自分の Discord アカウントだけです（そのチャンネルと DM）。

## できること

- **チャンネルで話しかける** … Claude または Codex が作業して、返事をチャンネルに書きます。画像やファイルの受け渡しもできます。
- **ステータス表示** … ボットの吹き出しとオンラインの丸で、今の様子が分かります。

  | いつ | 丸 | 吹き出し |
  |---|---|---|
  | 作業中 | 赤 | ⏳ 📝 編集：server.ts｜指示の頭 |
  | 許可や答えを待っている | 黄 | ❓ 確認待ち：… |
  | 待機中 | 緑 | なし |

- **許可の確認をボタンで（Claude Code）** … Claude がコマンドの実行などの許可を求めると、チャンネルに中身と［✅ 許可］［❌ 拒否］が出ます。
- **選択肢の質問をボタンで（Claude Code）** … Claude が「どちらにしますか？」と聞くときは、選択肢がボタンで出ます。
- **スラッシュコマンド**

  | コマンド | すること |
  |---|---|
  | `/restart` | 新しい会話で起動し直す |
  | `/resume` | 今の会話を引き継いで起動し直す（固まったとき） |
  | `/status` | 今の状態を自分にだけ見せる |

- **@ したときだけ反応（プロジェクトごとに切り替え）** … オンにすると、チャンネルでは `@ボット` したメッセージと
  ボットへの返信だけに反応します。メモを書いたり、1 つのチャンネルに複数のボットを置いたりするときに。オフ（既定）なら全部に反応します。
- **管理画面** … プロジェクトの追加・編集・削除・起動・停止、ログイン時の自動起動の切り替え。

## 必要なもの

- Windows 10 / 11（Windows PowerShell 5.1）
- CodexアプリまたはCodex CLIでChatGPTにログイン済みであること（Discord版はSDK同梱ランタイムを使うため、グローバルな `codex` コマンド自体は不要）
- Claude Codeを使う場合は [Claude Code](https://docs.claude.com/claude-code)（`claude` コマンド）
- Node.js 18 以上（Codex SDK と Discord ボット用）
- [bun](https://bun.sh)（プラグインとこのフォルダのスクリプトを動かす）
- Discord のサーバー（自分が管理できるもの）と、プロジェクトごとのボット

## 入れ方

1. このリポジトリを好きな場所に置きます（`git clone` か ZIP）。**置き場所はあとで変えても大丈夫です**（変えたら `setup.cmd` をもう一度実行してショートカットを作り直す）。
2. `setup.cmd` をダブルクリックします。次のことを、確認しながら進めます。
   - `claude` / `codex`、Node.js、`bun` があるか確かめ、Codex 用の部品をこのフォルダに入れる
   - discord プラグインが入っていなければ入れる
   - **ふだんの Claude と Discord 用の Claude を分ける** … Discord とつなぐ部品を、Discord 用に起動した Claude でだけ動くようにします。
     ふだんの Claude の使い勝手は変わりません（くわしくは下の「なぜプラグインを無効にするのか」）。
     **n にするのは、次のどちらかの人だけです。** よく分からなければ y で大丈夫です。
     - **ふだんの Claude で discord プラグインを直接使っている：** このしくみを使わずに、公式のやり方で Discord とつないでいる人です。`y` にすると、そちらが動かなくなります。
     - **設定ファイルを自分で管理している：** 会社の管理などで、`settings.json` を勝手に書き換えてほしくない人です。
   - デスクトップにショートカット「Claude Discord 起動」「Claude Discord 管理」を作る
3. プロジェクトごとにボットを作って登録します（次の節）。

## ボットを作る（プロジェクトごとに 1 つ）

1. https://discord.com/developers/applications → **New Application**
2. **Bot**
   - **Message Content Intent をオン**（忘れると、メッセージの本文が空で届きます）
   - **Public Bot をオフ**
   - **Reset Token** でトークンをコピー（一度しか表示されません）
3. **OAuth2 → URL Generator**
   - スコープ：`bot`
   - 権限：View Channels / Send Messages / Send Messages in Threads / Read Message History / Attach Files / Add Reactions
   - Integration type：Guild Install
   - できた URL を開いて、自分のサーバーに入れる
4. Discord でプロジェクト用のチャンネルを作ります（非公開チャンネルなら、チャンネルの権限にボットを足す）。
   設定 → 詳細設定 → **開発者モード** をオンにして、チャンネルを右クリック →「チャンネル ID をコピー」。
5. 「Claude Discord 管理」の **追加…** で、作業フォルダ・名前・チャンネル ID・トークンを入れ、**Codex** または **Claude Code** を選びます。
   その前に一度だけ、管理画面の下の「あなたの Discord ユーザー ID」に自分の ID を入れて「保存」します
   （自分のアイコンを右クリック →「ユーザー ID をコピー」）。

ボットはプロジェクトごとに分けてください。1 つのボットを使い回すと、DM が全部のセッションに届いてしまいます。

## 使い方

- **起動**：「Claude Discord 起動」（全部）か、管理画面の「起動」。プロジェクトごとに PowerShell のウィンドウが開きます。
  ウィンドウを閉じるとボットは止まります。
- **ログイン時に自動で起動**：管理画面の「ログイン時に自動で起動する」をオン。
- **@ したときだけ反応**：管理画面の「編集…」で「チャンネルでは @ボット したとき（とボットへの返信）だけ反応する」をオン
  （一覧の「反応」列に `@ のみ` と出ます）。起動し直さなくても、すぐ効きます。
  決まった言葉で呼びたいときは、`discord-<名前>\access.json` に `"mentionPatterns": ["^claude"]` のように正規表現を足します
  （管理画面や `cdiscord setup` で access.json を書き直すと消えるので、そのあとで足し直してください）。
- **Codex に使わせる MCP を選ぶ**：Discord から動く Codex は、Codex アプリのプラグイン（コンピューター操作・ブラウザ・Slack など）と
  MCP サーバーを使えないようにしてあります。プロジェクトで使いたい MCP があれば、管理画面の「編集…」の「使っていい MCP」で
  チェックします（作業フォルダで Codex に見えるものが並びます）。チェックしたものだけ使え、ほかは止めたままです。起動し直すと効きます。
  ボットのウィンドウには、起動時に `MCP servers allowed: … / off: …` と出ます。
- **コマンドで操作**：`cdiscord.cmd` をこのフォルダで実行します。

  ```
  cdiscord list                      登録しているプロジェクト
  cdiscord start [名前]              全部、または 1 つを起動
  cdiscord restart 名前              閉じて起動し直す（-Resume <会話ID> で会話を引き継ぐ）
  cdiscord add                       プロジェクトのフォルダで実行すると登録（質問に答える）
  cdiscord mention 名前 on|off       チャンネルで @ したときだけ反応するか（すぐ効く）
  cdiscord agent 名前 codex|claude   使うエージェントを切り替える（起動中なら再起動が必要）
  cdiscord mcp 名前 [a,b|none]       Codex に使わせる MCP（名前だけなら一覧。起動中なら再起動が必要）
  cdiscord remove 名前               登録を消す
  cdiscord setup                     access.json を作り直し、足りないトークンを聞く
  ```

## 気をつけること

- **ボットは、あなたの PC の上で、あなたの権限で Claude Code / Codex を動かします。** トークンは他人に渡さないでください。
  トークンは `discord-<名前>\.env` に保存され、`.gitignore` で Git には入りません。
- **Codex は PC 上でコードを読み書きします。** この実装では作業フォルダ内への書き込みだけを許可し、外部コマンドの追加承認は行いません。
  許可した MCP はサンドボックスの外で、確認なしに動きます。外に送ったり消したりできる MCP は、よく考えてから許可してください。
- ステータスの吹き出し（指示の頭やファイル名）は、サーバーにいる全員に見えます。ほかの人がいるサーバーで使うなら、
  `status-presence.ts` の `toPresence` で文言を固定にしてください。
- PC がスリープするとボットはオフラインになります。
- ステータス表示・ボタン・スラッシュコマンドは、公式プラグインに起動のたびに数行を足して実現しています（下の「仕組み」）。
  プラグインが更新されて作りが変わると、それらの機能だけが出なくなることがあります。その場合もボットそのものは動きます。

## 困ったとき

1. **ボットがオンラインにならない**
   - ウィンドウに確認画面（更新のお知らせ・ログインなど）が出て止まっていないか見る。
   - プラグインが動いているか：

     ```powershell
     Get-CimInstance Win32_Process -Filter "Name='bun.exe'" | ForEach-Object { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)").CommandLine }
     ```

     `claude.exe ... --channels ... --settings ...` の下に bun がいれば動いています。
   - プラグインのログ：`%LOCALAPPDATA%\claude-cli-nodejs\Cache\<作業フォルダを変換した名前>\mcp-logs-plugin-discord-discord\*.jsonl`
     - `Successfully connected` … 正常
     - `DISCORD_BOT_TOKEN required` … トークンが読めていない（`.env` は `DISCORD_BOT_TOKEN=...` の 1 行、BOM なし）
     - ログが増えていない … プラグインの起動が飛ばされている（下の「なぜプラグインを無効にするのか」）
2. **ステータス・ボタン・コマンドが出ない** … 起動時に出る `plugin patch: ...` の行を見ます。
   `place for '...' not found` なら、プラグインの更新で足す場所が変わっています（`apply-plugin-patch.ts` の `PATCHES` を直す）。
3. **`/restart` などがコマンドの一覧に出ない** … ボットを招待し直してみてください。同じサーバーにボットが複数いると、
   一覧には全部のボットのコマンドが並ぶので、そのチャンネルのボットのものを選びます。

## なぜプラグインを無効にするのか

プラグインがユーザー設定で常に有効だと、Discord 用ではない Claude（デスクトップアプリなど）も起動のたびにプラグインを動かし、
トークンがないので失敗します。Claude Code は失敗すると `~/.claude/mcp-needs-auth-cache.json` に「最近失敗した」印を残し、
**15 分間、ほかのセッションでもそのプラグインの接続を飛ばします**。そのため、Discord 用のセッションまでボットがオンラインにならなくなります。

そこで、ユーザー設定ではプラグインを無効にし、Discord 用のセッションだけ起動時に `--settings channel-settings.json` で有効にしています。
起動の直前には、残っている失敗の印も消しています。

## 仕組み

起動（`Start-Project`）は、新しい PowerShell ウィンドウを開いて次を実行します。

```
$env:DISCORD_STATE_DIR = '<このフォルダ>\discord-<名前>'    ← トークンと access.json の場所
Set-Location -LiteralPath '<作業フォルダ>'
claude --channels plugin:discord@claude-plugins-official --settings '<このフォルダ>\channel-settings.json'
```

その直前に `prepare.ts` が次の 2 つをします。

1. `channel-settings.json` を、このフォルダの場所に合わせて作り直す（プラグインの有効化・フック・`AskUserQuestion` の禁止）。
2. `apply-plugin-patch.ts` で、プラグインの `server.ts` にこのフォルダのモジュールを読み込む行を足す（`// [DiscordClaude ...]` が目印。
   `bun apply-plugin-patch.ts --remove` で外すと元のファイルに戻る）。

| ファイル | 役割 |
|---|---|
| `setup.cmd` / `setup.ps1` / `setup-tools.ts` | 初回セットアップ |
| `cdiscord.cmd` / `claude-discord.ps1` | コマンド（CLI）。メッセージは ASCII のみ |
| `claude-discord-gui.ps1` | 管理画面（WinForms）。**UTF-8 BOM 付きで保存すること** |
| `prepare.ts` | 起動前の準備（上の 1・2） |
| `apply-plugin-patch.ts` | プラグインへの行の足し外し |
| `status-presence.ts` | ボットのステータス（プラグインの中で動く） |
| `status-hook.ts` | Claude Code のフックから呼ばれ、`discord-<名前>\status.json` に状態を書く |
| `discord-buttons.ts` | 許可の確認をチャンネルにボタンで出す・`ask_choice` の道具（プラグインの中で動く） |
| `discord-commands.ts` | `/restart` `/resume` `/status`（プラグインの中で動く） |

自分の環境のデータ（Git に入れないもの）：

| ファイル | 中身 |
|---|---|
| `claude-discord.json` | 自分のユーザー ID、プロジェクトの名前・作業フォルダ・チャンネル ID・@ したときだけ反応するか |
| `discord-<名前>\.env` | ボットのトークン |
| `discord-<名前>\access.json` | 話しかけられる人とチャンネル |
| `discord-<名前>\status.json` / `session.json` | 今の状態、会話 ID |
| `channel-settings.json` | 起動のたびに作り直される |

### ステータス

ステータスは Discord と常時つながっているプロセス（プラグイン）からしか変えられないので、`status-presence.ts` をプラグインの中で動かし、
`status.json` を 1 秒ごとに見て、変わっていれば送ります（Discord の回数制限のため、最短 5 秒おき）。
`status.json` を書くのは、メッセージを受け取ったときの `status-presence.ts`、ボタンの `discord-buttons.ts`、
Claude Code のフック（SessionStart / UserPromptSubmit / PreToolUse / Notification / PostToolUse / Stop / SessionEnd → `status-hook.ts`）です。

### ボタン

`discord-buttons.ts` は、プラグインの MCP サーバーに登録済みのハンドラーを包んでいます（MCP SDK の `_requestHandlers` / `_notificationHandlers`）。
許可の確認は、最後にメッセージが来たチャンネル（まだなければ、登録チャンネルが 1 つだけならそこ）に出し、出せないときはプラグイン本来の DM になります。
ボタンを押せるのは `access.json` の `allowFrom` にいる人だけです。

### コマンド

起動のたびに、登録チャンネルのあるサーバーにギルドコマンドを登録します。起動し直しは `cmd /c start ... claude-discord.ps1 restart <名前>` で、
`cmd` の `start` をはさむのは、`restart` が `taskkill /T` で閉じるウィンドウの木に自分自身が入らないようにするためです。
会話 ID はフックが `session.json` に残し、`/resume` が `claude --resume <会話ID>` に使います。
