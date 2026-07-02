# BUG: `spawn`으로 띄운 두 codex 워커가 같은 cmux surface를 공유 → pane-push 충돌

- **agmsg-cmux 버전**: 1.3.0 (`VERSION`)
- **backend**: cmux
- **보고자 관점**: planner(claude-code)가 같은 팀의 codex 워커 2대를 `spawn`으로 띄운 뒤 pane-push 동작을 검증하다 발견
- **관련 스크립트(추정)**: `scripts/spawn.sh`, `scripts/pane.sh`

---

## 요약 (TL;DR)

`/agmsg spawn codex scout` 와 `/agmsg spawn codex executor` 를 연속 실행하면 두 워커가
**서로 다른 cmux pane에 뜨지 않고 동일한 surface(`CMUX_SURFACE_ID` 동일)에 물린다.**
그 결과 pane-registry에 둘 다 같은 addr(`surface:11`)로 등록되고, 어느 워커에게
메시지를 보내도 pane-push가 **항상 같은 pane 하나만** nudge한다.

inbox 전달(SQLite)은 정상이라 메시징·협업 자체는 동작하지만, pane-push의
"수신자 pane을 골라 깨운다"는 핵심 기능이 무력화된다.

---

## 재현 절차

1. cmux 안에서 planner(claude-code)가 team `my1pick`에 join (planner는 별도 pane = `surface:1`).
2. planner 세션에서:
   ```
   /agmsg spawn codex scout
   /agmsg spawn codex executor
   ```
   - 각각 `spawned codex '<name>' in cmux split` 출력 (즉 spawn 자체는 "split 생성"이라고 보고).
3. `/agmsg team` → planner / scout / executor 모두 `[live]`.
4. 각 워커에 핑을 보내면 **둘 다 자기 inbox로 정상 수신·회신**함(별개 세션 확인됨).
5. 그런데 `send.sh`의 pane-push 출력이 scout·executor 모두 동일:
   ```
   pane-push: nudged scout    (cmux surface:11)
   pane-push: nudged executor (cmux surface:11)
   ```

---

## 관측된 현상 (정확한 증거)

### 1) pane registry에 두 워커가 같은 addr

`pane.sh status` (team=my1pick, 무관 항목 제외):

```
my1pick   executor   cmux   surface:11   /Users/szyi/Project/FSNWork/my1pick   codex
my1pick   scout      cmux   surface:11   /Users/szyi/Project/FSNWork/my1pick   codex
my1pick   planner    cmux   surface:1    /Users/szyi/Project/FSNWork/my1pick   claude-code
```

- scout, executor → **둘 다 `surface:11`**. planner만 `surface:1`로 분리.
- 같은 status에 남아 있던 옛 잔재 항목은 UUID 형태로 등록돼 있었음
  (예: `executor-extra ... 16B49F37-34F3-4FA6-98FA-22308B627907`).
  → **등록 addr 표현이 일관되지 않음**: 어떤 건 `surface:N`(숫자 별칭), 어떤 건 UUID.

### 2) `doctor`는 "ok"로 판정 (충돌을 못 잡음)

`pane.sh doctor my1pick scout` / `... executor` 둘 다:

```
detected backend: cmux
self addr: surface:1                 ← planner 쪽에서 실행해서 planner surface
env hints: CMUX_SURFACE_ID=178E7419-1ECF-4DEE-86E6-70AF71FBA82A
registry my1pick/<name> addr: surface:11
registry my1pick/<name> alive: alive
verdict: ok
```

- 두 워커가 같은 addr를 공유하는데도 `verdict: ok`. **doctor에 충돌(중복 addr) 검사가 없음.**

### 3) actas 재등록으로도 안 고쳐짐

각 워커에게 "자기 pane 안에서 `$agmsg actas <name>` 다시 실행해 재등록" 지시 →
둘 다 "재등록 완료" 회신했지만 `pane.sh status`는 **여전히 둘 다 `surface:11`**.

### 4) 근본 원인: 두 워커의 `CMUX_SURFACE_ID`가 실제로 동일

각 워커 pane 안에서 `echo $CMUX_SURFACE_ID` 실행 결과:

```
scout    = 05ABF1E4-044B-4851-8CE6-77E4598D180F
executor = 05ABF1E4-044B-4851-8CE6-77E4598D180F   ← 완전히 동일
```

즉 레지스트리 값만 틀어진 게 아니라, **두 codex 프로세스가 물리적으로 같은 cmux
surface 컨텍스트에서 실행**되고 있다. actas가 자기 `CMUX_SURFACE_ID`를 읽어
재등록해도 값이 같으니 분리될 수 없다.

(주의: planner의 `CMUX_SURFACE_ID`는 `178E7419-...`로 다름. 워커 2대만 `05ABF1E4-...`를 공유.)

---

## 진단

- `spawn.sh`가 `cmux split`으로 워커를 띄운다고 보고하지만, **두 번째 워커가 자기만의
  새 surface를 못 받고 첫 번째(또는 focus된) surface를 그대로 상속**하는 것으로 보인다.
  두 codex 프로세스의 `CMUX_SURFACE_ID`가 동일하다는 게 결정적 증거.
- 그 결과 pane 등록이 같은 addr로 겹치고, pane-push는 한 pane만 깨운다.
- `surface:11`이라는 숫자 별칭 자체가 focus/active surface 기준으로 해석되어
  UUID(`05ABF1E4`) → `surface:11`로 매핑되는 과정에서 워커 고유성이 사라지는 정황도 있음.

## 의심 지점 (수정 시 확인 요망)

1. **`spawn.sh`의 cmux split 생성**: split이 실제로 새 surface를 만드는지, 그리고 새로
   띄운 codex 프로세스의 env에 **그 새 surface의 `CMUX_SURFACE_ID`가 주입**되는지.
   현재는 부모/focus surface 값이 그대로 상속되는 것으로 의심됨.
2. **pane addr 표현 일관성**: `surface:N`(숫자 별칭) vs UUID 혼용. 등록·nudge·lookup에서
   기준을 UUID(`CMUX_SURFACE_ID`)로 통일하는 게 안전해 보임.
3. **`pane.sh doctor`에 중복 addr 검사 추가**: 같은 팀 내 두 (team,name)이 동일 addr로
   등록되면 `verdict: collision` 등으로 경고해야 함. 지금은 `ok`로 통과.
4. **`spawn.sh`에서 스폰 직후 자기 addr 유일성 검증**: 방금 띄운 워커의 addr가 기존
   등록과 겹치면 즉시 실패/경고.

---

## 영향도

- **협업/메시징**: 영향 없음. inbox는 per-agent SQLite라 각 워커가 자기 메시지를 정상 수신.
- **pane-push 실시간성**: 반쪽. turn 모드 워커를 "즉시 깨우기"가 같은 pane에만 걸려,
  대상이 아닌 워커가 깨거나 대상 워커가 다음 turn까지 안 깨는 경우 발생.
- **오해 소지**: `spawn` 출력은 "in cmux split"으로 성공처럼 보이고 `doctor`도 `ok`라,
  사용자가 문제를 인지하기 어렵다.

---

## 참고 환경

- 프로젝트: `/Users/szyi/Project/FSNWork/my1pick`
- 팀: `my1pick` (planner=claude-code, scout/executor=codex)
- 날짜: 2026-07-01

---

## 해결 (2026-07-01)

근본 원인: 스폰된 워커 쉘이 자기 surface의 `CMUX_SURFACE_ID`를 못 받고 stale/공유
값을 상속 → 둘 다 같은 addr로 자가 등록. 게다가 등록 addr가 위치성 `surface:N`
short ref라 surface가 열리고 닫히면 밀리거나 겹칠 수 있었음.

수정:
1. `spawn.sh launch_in_cmux` — 방금 만든 surface의 UUID를 뽑아 respawn 커맨드에
   `export CMUX_SURFACE_ID=<uuid>`로 **고정** 주입. 스폰마다 유일한 UUID라 두 워커가
   같은 surface로 등록될 수 없다. placement 기록도 UUID로.
2. `lib/pane.sh agmsg_pane_self` (cmux) — 자기 addr를 short ref 대신 **UUID**
   (`CMUX_SURFACE_ID`)로 반환. 전역 유일 + 안정적.
3. `pane.sh doctor` — 같은 backend+addr를 공유하는 두 (team,name)을 `COLLISION` /
   `verdict: collision`으로 경고 (진단 #2·#3). 더는 `ok`로 통과 안 함.

검증: `bats tests/test_pane.bats tests/test_spawn.bats` 통과(신규 collision 테스트
포함), cmux에서 2회 split→respawn 시 각 워커가 서로 다른 UUID로 등록됨을 실측 확인.

미적용(진단 #4, spawn 직후 유일성 검증): #1이 충돌 자체를 구조적으로 없애고 #3가
사후 탐지하므로 생략. 필요하면 추가.

---

## ⚠️ 재발 (2026-07-01, 위 "해결" 이후 — 예방 미완, 탐지만 동작)

> planner가 위 수정이 반영된 빌드에서 다시 `spawn codex scout` + `spawn codex executor`를
> 실행한 결과, **충돌이 그대로 재현**됐다. 수정 #3(doctor)만 동작하고 **#1/#2의 예방이
> 안 먹힌다.** 즉 진단 방향은 맞았으나 원인 층위가 한 겹 더 깊다.

- **버전**: `v1.3.0-1-gb99cd9d-dirty` (`version.sh`), HEAD `b99cd9d`

### 재현

```
/agmsg spawn codex scout      → "spawned codex 'scout' in cmux split"
/agmsg spawn codex executor   → "spawned codex 'executor' in cmux split"
```
(둘 다 별개 spawn. planner 세션은 tmux/cmux 안. `/agmsg team` → 셋 다 `[live]`.)

### 관측 — 여전히 같은 addr, 이번엔 UUID로 겹침

`pane.sh status` (my1pick 관련만):
```
my1pick   executor   cmux   4B47DC1D-F325-4274-AF9D-3692827BC6BD   .../my1pick   codex
my1pick   scout      cmux   4B47DC1D-F325-4274-AF9D-3692827BC6BD   .../my1pick   codex
my1pick   planner    cmux   178E7419-1ECF-4DEE-86E6-70AF71FBA82A   .../my1pick   claude-code
```
- 수정 #2로 addr 표기는 `surface:N` → **UUID로 통일**됨(개선 확인). 그러나 scout·executor가
  **동일 UUID `4B47DC1D`** 를 공유 → 충돌 성질은 그대로.
- `pane.sh test my1pick scout` / `... executor` 둘 다 `OK surface:20` — **같은 물리 pane**을 nudge.

### 수정 #3 (doctor collision)는 정상 동작 ✅

`pane.sh doctor my1pick scout` (executor도 대칭):
```
registry my1pick/scout addr: 4B47DC1D-F325-4274-AF9D-3692827BC6BD
registry my1pick/scout COLLISION: shares cmux addr 4B47DC1D-...-BB6BD with my1pick/executor
verdict: collision (duplicate pane addr: my1pick/scout)
```
→ 더는 `ok`로 통과 안 함. **탐지는 완성됨.**

### 그런데 예방(#1/#2)은 실패 ❌ — 결정적 증거

- 설치본 `scripts/spawn.sh`의 `launch_in_cmux`에는 수정 #1이 **그대로 존재**:
  `boot_cmd="export CMUX_SURFACE_ID=$surface_uuid; exec $BOOT"` (respawn-pane 직전).
- 수정 #2로 `agmsg_pane_self`(cmux)는 `$CMUX_SURFACE_ID`를 그대로 반환하고, 워커의
  actas 자가등록은 그 값을 addr로 쓴다. **그런데 두 워커 모두 `4B47DC1D`로 등록됐다는 건,
  두 codex 프로세스의 `CMUX_SURFACE_ID`가 실제로 다시 동일하다는 뜻**(원 리포트 §4와 동일 양상,
  값만 `05ABF1E4…` → `4B47DC1D…`로 바뀜).
- 즉 spawn이 respawn-pane 커맨드에 유일 UUID를 `export`로 넣어도, **자식 codex 쉘의
  최종 `CMUX_SURFACE_ID`가 그 값이 아니다.**

### 원인 재추정 (원인 층위가 #1의 가정과 다름)

수정 #1은 "`export CMUX_SURFACE_ID=<uuid>; exec $BOOT`로 넣으면 자식이 그 값을 쓴다"를 전제한다.
재발 증거는 이 전제가 깨짐을 시사한다. 유력 가설(택1 또는 복합):

1. **cmux가 쉘 초기화 시 자기 `CMUX_SURFACE_ID`를 재주입**해 우리의 `export`를 덮어쓴다.
   그리고 그 재주입 값이 **focus된 surface 기준**이라, 연속 spawn 시 나중에 focus된
   surface(=`4B47DC1D`) 값을 두 워커가 공유한다. (`new-surface … --focus true`가 매 spawn마다
   focus를 옮기는 점과 부합.)
2. **`cmux new-split --surface "$from"`가 두 번째 호출에서 새 surface를 안 만들고**
   기존/focus surface를 반환 → respawn-pane이 같은 surface에 두 번 걸린다.

어느 쪽이든 **"env로 자식에 UUID를 심어 자가등록에 반영"하는 방식이 cmux의 per-shell
`CMUX_SURFACE_ID` 주입과 경합**해 신뢰할 수 없다는 게 핵심.

### 제안 — 자가등록 신뢰를 버리고 spawn이 권위적으로 등록

`spawn.sh`는 자기가 만든 surface UUID(`$surface_uuid`)를 **확실히 안다**. 자식의 env·actas
자가등록에 의존하지 말고:

1. **spawn.sh가 직접 등록**: surface 생성 직후 `pane.sh register <team> <name> cmux <surface_uuid> <project>`를
   spawn 쪽에서 호출해 addr을 권위적으로 확정. 자식 actas는 이미 맞는 값이면 no-op.
   (env 경합을 원천 차단 — 가장 견고.)
2. 또는 **env 대신 파일/인자 경로로 전달**: actas 프롬프트나 임시 파일에 surface UUID를 실어
   워커가 cmux 주입값이 아니라 그 값을 등록하게.
3. **생성 UUID 유일성 assert**: spawn 직후 `$surface_uuid`가 기존 등록과 겹치면 즉시
   `die`(진단 #4). #1 가정이 깨진 지금은 이 사후 가드가 실질적 안전망이 된다.
4. `new-split`/`new-surface`가 매 spawn마다 **정말 새 surface UUID를 반환하는지** 로깅으로 확인
   (가설 2 검증). 같은 UUID를 반환한다면 cmux 호출 인자(`--surface "$from"` 재사용) 자체를 재검토.

### 영향/상태

- 협업·메시징: 무해(원본과 동일, inbox는 per-agent SQLite).
- pane-push: 반쪽. 대상이 아닌 워커를 깨우거나 대상이 안 깨는 문제 지속.
- **회귀 아님 / 미완**: 탐지(#3)는 추가돼 사용자가 `doctor`로 인지 가능해진 건 개선.
  단 예방(#1/#2)은 목표 미달 → 위 제안(특히 #1: spawn 권위적 등록)로 재수정 필요.

### 참고 환경

- 프로젝트 `/Users/szyi/Project/FSNWork/my1pick`, 팀 `my1pick`
  (planner=claude-code, scout/executor=codex), backend cmux, 날짜 2026-07-01.

---

## 해결 v2 (2026-07-01, 재발 대응)

재발 원인 확정(실측): `cmux --id-format both new-split`은 매 호출마다 **서로 다른 새
surface UUID를 정상 반환**한다(예: `surface:22/255C…`, `surface:23/A92B…` — 물리
surface는 분리됨 = 원 리포트 §4의 "hypothesis 1"). 문제는 **워커의 `actas`가 도는
시점의 ambient `CMUX_SURFACE_ID`가 신뢰 불가**라는 것. cmux가 codex의 actas 서브
프로세스에 focus/세션 의존적인 값을 (재)주입해 두 워커가 같은 값을 읽고 같은 addr로
자가등록한다. 그래서 v1의 `export CMUX_SURFACE_ID=<uuid>`가 **덮여서** 안 먹혔다.

핵심 교훈: **cmux가 관리하는 변수(`CMUX_SURFACE_ID`)에 우리 값을 심는 방식은 cmux의
per-shell 재주입과 경합한다.** 이기려면 cmux가 절대 건드리지 않는 채널을 써야 한다.

수정: `spawn.sh launch_in_cmux`가 respawn 커맨드에서 **`AGMSG_PANE_SELF=<surface_uuid>`**
를 export한다. `agmsg_pane_self`는 이 변수를 **backend 조회보다 먼저, 무조건** 반환하고,
cmux는 이 agmsg 전용 변수를 절대 쓰지 않으므로 actas 서브프로세스까지 온전히 살아
남는다. 스폰마다 유일한 surface UUID라 두 워커가 절대 같은 addr로 등록될 수 없다.
(`CMUX_SURFACE_ID`도 같이 export해 backend 감지는 cmux로 유지.)

검증(실측):
- `new-split` 2회 → 매번 새 UUID 반환 확인(`surface:22`, `surface:23`).
- `AGMSG_PANE_SELF`가 mismatched ambient `CMUX_SURFACE_ID`를 이겨 그 값으로 등록됨을
  단위 확인. 두 워커(다른 `AGMSG_PANE_SELF`) → distinct addr 등록 확인.
- `bats tests/test_spawn.bats tests/test_pane.bats` 전부 통과.

미적용(진단 #4, spawn 권위적 직접등록): `AGMSG_PANE_SELF` 핀이 cmux 경합을 원천
차단하므로 불필요. 자가등록 경로를 우회하는 백엔드가 생기면 그때 추가.
