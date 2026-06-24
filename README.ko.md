[English](README.md) | 한국어 | [日本語](README.ja.md)

# agmsg-cmux

## 요약

agmsg-cmux는 `fujibee/agmsg`의 포크로, tmux/cmux turn-mode pane-push를 추가합니다. Claude Code, Codex, Gemini CLI 같은 CLI AI 에이전트가 데몬이나 네트워크 서비스 없이 로컬 SQLite를 통해 서로 메시지를 주고받을 수 있습니다.

## 이 포크에서 추가된 것

원본 agmsg는 로컬 스크립트와 SQLite로 메시지를 저장하고 읽습니다. 이 포크는 best-effort turn-mode pane-push를 추가합니다. `scripts/send.sh`가 메시지를 저장한 뒤 수신자에게 등록된 tmux 또는 cmux pane이 있는지 확인하고, 해당 에이전트가 agmsg skill을 실행해 inbox를 읽도록 짧은 프롬프트를 주입합니다.

Pane 등록은 role 생명주기를 따릅니다.

- `scripts/join.sh`는 에이전트가 팀에 join한 뒤 현재 pane 등록을 시도합니다.
- `scripts/actas-claim.sh`는 `actas` claim이 성공한 뒤 현재 pane으로 등록을 갱신합니다.
- reset/drop 흐름에서 쓰이는 `scripts/reset.sh`는 제거된 role의 pane 등록을 해제합니다.

이를 통해 agmsg-cmux는 role이 join, switch, drop 되는 과정에 맞춰 살아 있는 pane을 추적합니다.

## 동작 방식

Pane 지원은 `scripts/lib/pane.sh`와 `scripts/pane.sh`에 있습니다. 백엔드는 자동 감지됩니다. tmux는 `$TMUX`와 `tmux`가 사용 가능할 때 `$TMUX_PANE`을 사용합니다. cmux는 `cmux identify --json`의 `caller.surface_ref` 값을 사용하고, 필요하면 `$CMUX_SURFACE_ID`를 fallback으로 사용합니다.

등록 정보는 설치된 skill 디렉터리 아래에 다음 형식으로 저장됩니다.

```text
run/pane.<team>.<name>.json
```

각 record에는 backend, pane address, project, agent type, registration timestamp가 저장됩니다. Pane-push가 활성화되어 있으면 `scripts/send.sh`는 등록된 pane이 아직 살아 있는지 확인하고 inbox 확인 프롬프트를 주입합니다. 주입은 텍스트를 보낸 뒤 `AGMSG_PANE_COMMIT_DELAY`만큼 기다리고 Enter를 보낸 다음, 다시 기다린 뒤 두 번째 Enter를 보내는 방식입니다.

## 설치

요구사항은 `bash`와 `sqlite3`입니다. macOS에는 둘 다 포함되어 있으며, 최소 Linux 환경에서는 `sqlite3` 패키지를 설치해야 할 수 있습니다.

agmsg-cmux 포크를 사용하려면 pane-push 스크립트가 포함되도록 이 checkout에서 설치합니다.

```bash
git clone <this-repository-url>
cd agmsg-cmux
./install.sh
```

`install.sh`는 skill을 `~/.agents/skills/<cmd>/`에 설치하며, `<cmd>`의 기본값은 `agmsg`입니다. 스크립트에서 확인되는 주요 옵션은 다음과 같습니다.

```bash
./install.sh --cmd m
./install.sh --agent-type gemini
./install.sh --agent-type opencode
./install.sh --update
```

설치 후에는 에이전트 CLI를 재시작해 skill이 감지되도록 한 다음, Claude Code에서는 `/agmsg`, Codex, Gemini CLI, Antigravity, OpenCode에서는 `$agmsg`를 실행합니다.

현재 `setup.sh` 동작은 upstream 전용입니다. 이 스크립트는 `${AGMSG_REF:-main}` 기준으로 `https://github.com/fujibee/agmsg.git`을 clone한 뒤 그 checkout의 `install.sh`를 실행합니다. 이 fork를 가리키도록 변경하지 않는 한, canonical upstream installer가 필요할 때만 `setup.sh`를 사용하세요.

## 사용법

기본 agmsg 흐름:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> <type> "$(pwd)"
~/.agents/skills/agmsg/scripts/send.sh <team> <from_agent> <to_agent> "<message>"
~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent_name>
~/.agents/skills/agmsg/scripts/history.sh <team> [agent_name] [limit]
```

Pane 명령:

```bash
~/.agents/skills/agmsg/scripts/pane.sh register <team> <name> [type] [project]
~/.agents/skills/agmsg/scripts/pane.sh status [<team> <name>]
~/.agents/skills/agmsg/scripts/pane.sh lookup <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh test <team> <name>
~/.agents/skills/agmsg/scripts/pane.sh unregister <team> <name>
```

명령 요약:

- `join.sh`: 팀에 join하거나 새 팀을 만들고, 가능하면 turn-mode pane-push를 위해 현재 pane을 등록합니다.
- `send.sh`: SQLite에 메시지를 저장하고, pane-push가 활성화되어 있으며 수신자의 등록 pane이 살아 있으면 해당 pane을 깨웁니다.
- `inbox.sh`: 에이전트의 새 메시지를 읽고 읽음 처리합니다.
- `history.sh`: 팀의 메시지 history를 출력합니다.
- `pane.sh register`: role에 대해 현재 tmux/cmux pane을 기록합니다.
- `pane.sh status`: pane 등록 목록을 출력하거나, team과 name이 주어지면 해당 등록 하나를 출력합니다.
- `pane.sh lookup`: 등록된 backend, address, project, type을 machine-readable 형식으로 출력합니다.
- `pane.sh test`: 등록된 살아 있는 pane에 test ping을 주입합니다.
- `pane.sh unregister`: role의 pane 등록을 제거합니다.

## 환경변수

| 변수 | 기본값 | 목적 |
| --- | --- | --- |
| `AGMSG_PANE_PUSH` | `1` | `0`으로 설정하면 일반 SQLite 메시징은 유지하면서 send 시점의 pane 주입을 비활성화합니다. |
| `AGMSG_PANE_COMMIT_DELAY` | `0.4` | 프롬프트를 commit하기 위해 주입 텍스트와 두 번의 Enter 전송 사이에 기다리는 시간(초)입니다. |

## 출처와 라이선스

agmsg-cmux는 MIT 라이선스의 `fujibee/agmsg`를 기반으로 합니다. Pane integration pattern은 역시 MIT 라이선스인 `paichi/cmux-bridge`에서 차용했습니다.

자세한 attribution은 `CREDITS.md`, MIT license 전문은 `LICENSE`를 참고하세요.
