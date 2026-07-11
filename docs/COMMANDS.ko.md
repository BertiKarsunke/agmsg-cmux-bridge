# agmsg-cmux 명령어 레퍼런스 (한국어)

이 문서는 **agmsg-cmux** 에서 쓰는 모든 명령을 정리한다. 명령 이름(`<cmd>`)은 설치 시 정한 값이며 기본값은 `agmsg`다.

> **핵심:** 설치 후에는 거의 모든 것을 **자연어**로 시키면 된다("새 메시지 있어?", "executor에게 …보내줘"). 에이전트가 알아서 아래 서브커맨드로 변환한다. 아래 표는 그 매핑과, 셸에서 직접 부를 때의 형태를 함께 담는다.

호출: **Claude Code = `/agmsg …`**, **Codex = `$agmsg …`**.

---

## 1. 스킬 명령 (`/agmsg` · `$agmsg`)

| 명령 | 하는 일 | Codex |
|------|---------|:----:|
| `/agmsg` (인자 없음) | 모든 팀 인박스 확인(새 메시지 읽기) | ✅ |
| `/agmsg history` | 메시지 기록 보기 | ✅ |
| `/agmsg team` | 팀 멤버 목록 | ✅ |
| `/agmsg send <agent> <message>` | 메시지 보내기 | ✅ |
| `/agmsg mode <monitor\|turn\|both\|off>` | 배달 모드 변경(§3) | 일부* |
| `/agmsg mode` | 현재 배달 모드 표시 | ✅ |
| `/agmsg config` | 설정값 보기 | ✅ |
| `/agmsg config set <key> <value>` | 설정값 변경 (예: `delivery.turn.check_interval 30`) | ✅ |
| `/agmsg actas <name>` | 같은 프로젝트에서 다른 역할로 전환(없으면 생성). pane 재등록까지 자동 | ✅ |
| `/agmsg drop <name>` | 이 프로젝트에서 그 역할 등록 해제 | ✅ |
| `/agmsg spawn <type> <name> [opts]` | 새 에이전트를 tmux pane/터미널에 띄우고 `actas <name>` 시킴(§4) | ✅ |
| `/agmsg despawn <name> [--force] [--timeout <s>]` | spawn으로 띄운 멤버 정리 | ✅ |
| `$agmsg pane [register\|status\|doctor\|test\|unregister]` | pane 등록·점검(§2). **Codex 명령으로 노출됨** | ✅ |
| `/agmsg hook on` / `hook off` | 레거시 별칭 → `mode turn` / `mode off` | ✅ |
| `/agmsg version` | 설치 버전 표시 | ✅ |
| `/agmsg reset` | 현재 프로젝트 등록 초기화 | ✅ |

\* 배달 모드: **Claude Code = monitor / turn / both / off**, **Codex = monitor(beta) / turn / off** (`both`는 미지원).

---

## 2. pane 명령 (turn-mode pane-push)

pane-push가 켜져 있으면(`AGMSG_PANE_PUSH=1`, 기본값) 메시지를 보낼 때 수신자의 tmux/cmux/wezterm/herdr pane을 깨워 즉시 읽게 한다. Herdr는 `$HERDR_ENV=1`과 `$HERDR_PANE_ID`로 감지되며 spawn/nudge/despawn/doctor를 지원하고 herdr 0.7.0에서 검증했다. 그러려면 수신자가 자기 pane을 등록해 둬야 한다(`join`/`actas`가 자동 등록, Codex는 매 턴 자동 갱신).

Codex(`$agmsg pane …`) 또는 셸(`pane.sh …`)에서:

| 명령 | 하는 일 |
|------|---------|
| `pane register <team> <name> [type] [project]` | 현재 pane을 그 역할로 등록/갱신 |
| `pane status [<team> <name>]` | 등록 목록(또는 특정 하나) 표시 |
| `pane doctor [<team> <name>]` | 백엔드 감지 + 등록 + 생존 여부 진단 |
| `pane lookup <team> <name>` | 등록 정보를 기계가 읽기 좋은 형태로 출력 |
| `pane test <team> <name>` | 등록된 살아있는 pane에 테스트 핑 주입 |
| `pane unregister <team> <name>` | 등록 제거 |

> peer가 "delivered via inbox only"라고 하면 `$agmsg pane register …` 로 직접 복구할 수 있다.

---

## 3. 배달 모드 (delivery mode)

| 모드 | 동작 | 지연 | 대상 |
|------|------|------|------|
| `monitor` | SessionStart 훅 → Monitor 도구 → SQLite 스트림(실시간 push) | ~5초 | Claude Code(기본) |
| `turn` | Stop 훅이 턴 사이에 `check-inbox.sh` 실행. **pane-push가 켜져 있으면 send 시 pane이 깨워져 사실상 즉시** | 다음 상호작용/즉시 | Codex(기본), 조용한 루프를 원하는 CC |
| `both` | monitor 주 + turn 안전망 | ~5초 | belt-and-suspenders (CC 전용) |
| `off` | 자동 배달 없음, 수동 `/agmsg`만 | 수동 | 미니멀리스트 |

변경: `/agmsg mode <name>`. 설정은 프로젝트별로 저장된다.

---

## 4. spawn / despawn 옵션

```
spawn <agent-type> <name> [옵션]
  --project <path>        띄울 프로젝트 (기본: 현재 디렉터리)
  --team <team>           <name>을 합류시킬 팀 (기본: 프로젝트 등록에서 자동 결정)
  --window                tmux 새 WINDOW (분할 대신)
  --split h|v             tmux 분할 방향 (h=좌우[기본], v=상하)
  --terminal <tmpl>       비-tmux 경로의 터미널 명령 템플릿 ({cmd} 치환)
  --no-wait               watcher attach를 기다리지 않고 fire-and-forget
  --ready-timeout <secs>  ready 대기 한도 (기본 90초)

despawn <name> [--force] [--timeout <secs>]
  (기본) graceful: ctrl:despawn 제어 메시지를 보내 멤버가 스스로 정리
  --force                 메시지 없이 spawn 당시 기록된 위치에서 강제 종료
  --timeout <secs>        graceful 대기 한도 (기본 30초)
```

> Codex 멤버는 watcher가 없어 graceful 종료에 응답 못 하므로 보통 `despawn … --force`.

---

## 5. 설치 / 업데이트 / 제거

```bash
# 설치 (이 포크 checkout에서 — pane-push 스크립트 포함)
./install.sh                 # 대화형 (명령 이름 질문, 기본 agmsg)
./install.sh --cmd m         # 명령 이름을 m 으로
./install.sh --agent-type gemini   # 특정 에이전트 타입용 설치
./install.sh --update        # DB/팀 설정 보존하고 스크립트/자산만 갱신

# 설치 후 에이전트(Claude Code/Codex) 재시작해야 스킬을 인식

# 업데이트 (저장소에서)
git pull && ./install.sh --update

# 제거
./uninstall.sh               # 대화형 (단계별 확인)
./uninstall.sh --yes         # 전부 제거
./uninstall.sh --keep-data   # 스킬만 제거, DB/팀 보존
```

`setup.sh` 는 upstream(`fujibee/agmsg`)을 clone해 설치하는 원라이너용이다. 이 포크 기능(pane-push)을 쓰려면 이 checkout에서 `./install.sh` 를 쓴다.

---

## 6. 셸 스크립트 직접 호출

경로: `~/.agents/skills/<cmd>/scripts/`. 평소엔 자연어/슬래시 명령이면 충분하고, 아래는 참고·고급용이다.

| 스크립트 | 용도 |
|----------|------|
| `join.sh <team> <agent> <type> <project>` | 팀 합류(없으면 생성) + pane 등록 시도 |
| `leave.sh <team> <agent\|all>` | 팀에서 나가기 (`all` = 모든 멤버 제거 후 팀 삭제) |
| `send.sh <team> <from> <to> "<msg>"` | 메시지 저장 + (pane-push 켜짐 시) 수신자 pane 깨우기 |
| `inbox.sh <team> <agent> [--quiet]` | 새 메시지 읽고 읽음 처리 |
| `history.sh <team> [agent] [limit]` | 메시지 기록 |
| `team.sh <team>` | 팀 멤버 목록 |
| `whoami.sh <project> [type]` | 이 프로젝트의 identity 조회 |
| `identities.sh <project> <type>` | 등록된 (team, agent) 쌍 나열 |
| `pane.sh <command> …` | pane 등록·점검 (§2) |
| `delivery.sh set\|status\|stop\|restart …` | 배달 모드 설정/상태/제어 |
| `reset.sh <project> <type> [agent\|all] [session]` | 현재 프로젝트 등록 초기화 (`all` = 해당 project/type의 모든 agent) |
| `rename.sh <team> <old> <new>` | 에이전트 이름 변경 |
| `rename-team.sh <old> <new>` | 팀 이름 변경(메시지 마이그레이션 포함) |
| `spawn.sh <type> <name> [opts]` / `despawn.sh …` | 멤버 띄우기/정리 |
| `config.sh get\|set …` | 설정값 |
| `version.sh` | 버전 |

> `check-inbox.sh` · `session-start.sh` · `session-end.sh` · `watch.sh` · `actas-claim.sh` 등은 훅이 자동으로 부르는 내부 스크립트라 직접 호출할 일은 거의 없다.

---

## 7. 환경변수

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `AGMSG_PANE_PUSH` | `1` | `0`이면 send 시 pane 주입 비활성화(인박스 배달은 유지) |
| `AGMSG_PANE_COMMIT_DELAY` | `0.4` | pane 주입 시 텍스트·Enter 사이 대기 초 |
| `AGMSG_TEAM_LEADER` | `planner` | 새 멤버 합류 시 `[JOIN]` 알림을 받을 에이전트 |
| `AGMSG_ANNOUNCE_JOIN` | `1` | `0`이면 합류 알림 끄기 |
| `AGMSG_STORAGE_PATH` | (기본 DB) | 메시지 SQLite DB 경로 오버라이드 |
| `AGMSG_BUSY_TIMEOUT` | `5000` | SQLite busy timeout(ms) |
| `AGMSG_TERMINAL` | — | spawn의 비-tmux 터미널 명령 템플릿 |
| `AGMSG_NODE` / `AGMSG_CODEX_NODE` | — | Codex 브리지가 쓸 Node 경로 지정 |
| `AGMSG_PANE_BACKEND` / `AGMSG_PANE_SELF` | (자동 감지) | pane 백엔드/주소 강제 — 진단·테스트용 |

---

## 8. 이 프로젝트 협업 셋업에서 자주 쓰는 흐름 (opus48: planner + scout + executor)

```text
# planner(Claude Code, monitor) 세션이 tmux 안이면 워커를 직접 띄움
/agmsg spawn codex scout
/agmsg spawn codex executor

# 팀 확인
/agmsg team

# 탐색 위임 → 구현 위임 (자연어로 충분)
"scout에게 [SCOUT S-1] 결제 진입점 어디인지 물어봐줘"
"executor에게 [TASK E-1] 보내줘"

# 구현 작업이 둘 이상 동시에 필요할 때만 보조 구현자 추가
/agmsg spawn codex executor-extra
# 끝나면 정리
/agmsg despawn executor-extra --force
```

Codex 한 대로 겸직할 때: 탐색 단계엔 `scout`, 구현 단계엔 `$agmsg actas executor`로 전환(끝나면 `$agmsg actas scout` 복귀). pane은 `actas`가 자동 재등록한다.

상세 역할 규약은 planner의 `CLAUDE.md`, Codex의 `AGENTS.md` 참고.
