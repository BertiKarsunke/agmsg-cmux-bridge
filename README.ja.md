[English](README.md) | [한국어](README.ko.md) | 日本語

# agmsg-cmux

## 概要

agmsg-cmuxは`fujibee/agmsg`のフォークで、tmux/cmux turn-mode pane-pushを追加します。Claude Code、Codex、Gemini CLIなどのCLI AIエージェントが、デーモンやネットワークサービスなしでローカルSQLiteを通じてメッセージをやり取りできます。

## このフォークで追加されたもの

元のagmsgはローカルスクリプトとSQLiteでメッセージを保存し、読み取ります。このフォークはbest-effort turn-mode pane-pushを追加します。`scripts/send.sh`がメッセージを保存した後、受信者に登録済みのtmuxまたはcmux paneがあるか確認し、そのエージェントにagmsg skillを実行してinboxを読むよう短いプロンプトを注入します。

Pane登録はroleのライフサイクルに従います。

- `scripts/join.sh`は、エージェントがチームにjoinした後、現在のpane登録を試みます。
- Claude Codeの経路では、`scripts/actas-claim.sh`が`actas` claim成功後に現在のpaneへ登録を更新します。
- Codex、Gemini、Copilot、Cursor、OpenCode、Antigravity、Hermesなどのturn-modeエージェントは、それぞれの`actas` skillコマンドの流れで`scripts/pane.sh register`により現在のpaneを再登録します。
- reset/dropフローで使われる`scripts/reset.sh`は、削除されたroleのpane登録を解除します。

これによりagmsg-cmuxは、roleがjoin、switch、dropされる流れに合わせて、生きているpaneを追跡できます。

## 動作方式

Pane対応は`scripts/lib/pane.sh`と`scripts/pane.sh`にあります。バックエンドは自動検出されます。tmuxは`$TMUX`と`tmux`が利用可能なときに`$TMUX_PANE`を使います。cmuxは`cmux identify --json`の`caller.surface_ref`値を使い、必要に応じて`$CMUX_SURFACE_ID`をfallbackとして使います。WezTerm/Kakuは`$WEZTERM_PANE`で検出され、`$WEZTERM_UNIX_SOCKET`または`$KAKU_UNIX_SOCKET`ソケットを使います。

登録情報は、インストール済みskillディレクトリの下に次の形式で保存されます。

```text
run/pane.<team>.<name>.json
```

各recordにはbackend、pane address、project、agent type、registration timestampが保存されます。Pane-pushが有効な場合、`scripts/send.sh`は登録済みpaneがまだ生きているか確認し、inbox確認プロンプトを注入します。注入はテキストを送り、`AGMSG_PANE_COMMIT_DELAY`だけ待ってEnterを送り、もう一度待ってから2回目のEnterを送る方式です。

## インストール

必要なものは`bash`と`sqlite3`です。macOSにはどちらも含まれていますが、最小構成のLinux環境では`sqlite3`パッケージのインストールが必要な場合があります。

agmsg-cmuxフォークを使うには、pane-pushスクリプトが含まれるよう、このcheckoutからインストールします。

```bash
git clone <this-repository-url>
cd agmsg-cmux
./install.sh
```

`install.sh`はskillを`~/.agents/skills/<cmd>/`にインストールします。`<cmd>`のデフォルトは`agmsg`です。スクリプトで確認できる主なオプションは次のとおりです。

```bash
./install.sh --cmd m
./install.sh --agent-type gemini
./install.sh --agent-type opencode
./install.sh --update
```

インストール後、エージェントCLIを再起動してskillを検出させ、Claude Codeでは`/agmsg`、Codex、Gemini CLI、Antigravity、OpenCodeでは`$agmsg`を実行します。

現在の`setup.sh`の動作はupstream専用です。このスクリプトは`${AGMSG_REF:-main}`を基準に`https://github.com/fujibee/agmsg.git`をcloneし、そのcheckoutの`install.sh`を実行します。このforkを指すよう変更しない限り、canonical upstream installerが必要な場合にだけ`setup.sh`を使ってください。

## 使い方

基本的なagmsgフロー:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> <type> "$(pwd)"
~/.agents/skills/agmsg/scripts/send.sh <team> <from_agent> <to_agent> "<message>"
~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent_name>
~/.agents/skills/agmsg/scripts/history.sh <team> [agent_name] [limit]
```

Paneコマンド:

```bash
~/.agents/skills/agmsg/scripts/pane.sh register <team> <name> [type] [project]
~/.agents/skills/agmsg/scripts/pane.sh status [<team> <name>]
~/.agents/skills/agmsg/scripts/pane.sh lookup <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh test <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh unregister <team> <name>
```

コマンド概要:

- `join.sh`: チームにjoinするか新しいチームを作り、可能な場合はturn-mode pane-pushのため現在のpaneを登録します。
- `send.sh`: SQLiteにメッセージを保存し、pane-pushが有効で受信者の登録paneが生きていれば、そのpaneを起こします。
- `inbox.sh`: エージェントの新しいメッセージを読み、既読にします。
- `history.sh`: チームのメッセージhistoryを出力します。
- `pane.sh register`: roleに対して現在のtmux/cmux paneを記録します。
- `pane.sh status`: pane登録一覧を出力するか、teamとnameが指定された場合はその登録1件を出力します。
- `pane.sh lookup`: 登録されたbackend、address、project、typeをmachine-readable形式で出力します。
- `pane.sh test`: 登録済みの生きているpaneへtest pingを注入します。
- `pane.sh unregister`: roleのpane登録を削除します。

## 環境変数

| 変数 | デフォルト | 目的 |
| --- | --- | --- |
| `AGMSG_PANE_PUSH` | `1` | `0`に設定すると、通常のSQLite messagingは維持したまま、send時のpane注入を無効化します。 |
| `AGMSG_PANE_COMMIT_DELAY` | `0.4` | プロンプトをcommitするため、注入テキストと2回のEnter送信の間に待つ時間(秒)です。 |

## クレジットとライセンス

agmsg-cmuxはMITライセンスの`fujibee/agmsg`を基にしています。Pane integration patternは、同じくMITライセンスの`paichi/cmux-bridge`から借用しています。

詳しいattributionは`CREDITS.md`、MIT license全文は`LICENSE`を参照してください。
