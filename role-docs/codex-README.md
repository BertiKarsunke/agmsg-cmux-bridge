# agmsg 3-agent 실행 참고

이 문서는 명시적으로 팀을 시작할 때만 쓰는 실행 참고다. Codex planner와 Claude planner 중 하나를 사용자가 선택하며, planner는 한 팀에 하나만 둔다.

## 참고 기본값

| 역할 | 호스트 | 모델 | reasoning | 배달 | 실행 옵션 |
|---|---|---|---|---|---|
| planner | Codex | `gpt-6-astra` | high | turn | `--sandbox workspace-write --ask-for-approval on-request` |
| planner | Claude | 사용자 선택 | 사용자 선택 | monitor | 사용자 승인 정책 |
| scout | Codex | `gpt-5.6-terra` | medium | turn | `options/scout.yaml` |
| executor | Codex | `gpt-5.6-sol` | high | turn | `options/executor.yaml` |

이는 참고 기본값이지 최신성·가격·성능 최적값 주장이 아니다. 시작 명령의 모델/옵션과 세션에서 실제 확인한 값을 구분한다.

Codex planner 시작 예:

```bash
codex -m gpt-6-astra -c 'model_reasoning_effort="high"' \
  --sandbox workspace-write --ask-for-approval on-request \
  '이 프로젝트에서 agmsg 3-agent 팀을 시작해. planner로서 __ROLE_DIR__/planner.md를 읽고 명시한 project/team만 사용해.'
```

## project/team 고정과 시작 순서

팀은 사용자 명시값, 유효한 현재 세션 binding 하나, resolved project basename 순서로 정한다. 아래 두 값을 planner가 확인한 실제 값으로 한 번만 채우고 재계산하지 않는다.

```bash
agmsg_project="/absolute/path/to/development-project"
agmsg_team="planner-fixed-team"
agmsg_scripts="__SKILL_DIR__/scripts"
```

planner는 먼저 자기 type으로 `join.sh`를 실행하고 `__CMD_NAME__ actas planner`를 적용한 뒤, 자기 pane을 doctor하고 `team.sh`로 빈 역할을 확인한다. Codex planner는 turn, Claude planner는 monitor를 설정한다. 다른 역할의 pane은 그 역할이 등록한다.

빈 역할에만 다음 명령을 실행한다.

```bash
AGMSG_SPAWN_OPTIONS_FILE="__ROLE_DIR__/options/scout.yaml" \
  "$agmsg_scripts/spawn.sh" codex scout --project "$agmsg_project" \
  --team "$agmsg_team" --model gpt-5.6-terra --fresh \
  --boot-prompt "너는 team=$agmsg_team project=$agmsg_project 의 scout다. __ROLE_DIR__/workers.md를 읽고 자기 역할만 actas/pane 진단한 뒤 planner에게 [READY]를 보내라."

AGMSG_SPAWN_OPTIONS_FILE="__ROLE_DIR__/options/executor.yaml" \
  "$agmsg_scripts/spawn.sh" codex executor --project "$agmsg_project" \
  --team "$agmsg_team" --model gpt-5.6-sol --fresh \
  --boot-prompt "너는 team=$agmsg_team project=$agmsg_project 의 executor다. __ROLE_DIR__/workers.md를 읽고 자기 역할만 actas/pane 진단한 뒤 planner에게 [READY]를 보내라."
```

`AGMSG_SPAWN_OPTIONS_FILE`은 해당 호출에만 적용되며 기본 옵션 파일과 병합되지 않는다. `--fresh`는 처음 시작할 때의 예시다. 기존 세션을 재개할 때는 ID/revision과 파일 상태를 먼저 확인한다.

turn hook과 pane-push는 최선 노력 방식이다. spawn 성공은 프로세스 시작 결과일 뿐 Codex 워커의 준비 보장이 아니다. team·role·project·pane이 맞는 `[READY]`를 확인한 뒤 TASK를 보낸다. 무응답이면 자기 inbox와 상대 pane doctor를 확인하되 다른 역할을 현재 pane으로 재등록하거나 자동 종료하지 않는다.
