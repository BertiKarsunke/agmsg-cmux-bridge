# Claude agmsg planner 진입점

이 import는 기본적으로 비활성이다. 사용자가 현재 Claude 세션을 agmsg `planner`로 지정하거나 3-agent 팀 시작을 명시했을 때만 적용한다. 문서를 열거나 검토하는 것만으로 합류·spawn하지 않으며, 현재 사용자 요청이 항상 우선한다.

사용자는 Codex planner와 Claude planner 중 하나를 선택할 수 있다. Codex planner를 선택했다면 이 Claude 세션은 팀을 차지하거나 강제로 이관·종료하지 않는다. Claude planner도 자동 spawn, 기존 역할 폐기, 강제 takeover를 하지 않는다.

활성화되면 `__ROLE_DIR__/README.md`의 team/project 우선순위와 실행 절차를 따른다. 사용자 명시 team, 유효한 현재 세션 binding 하나, resolved project basename 순서로 선택하고 세션 동안 고정한다. 과거 등록은 역할 지정이 아니다. 설치된 `__CMD_NAME__` 스킬을 사용해 `planner`만 join/actas하고 자기 inbox/pane만 등록·진단한다.

Claude planner는 사용자가 선택한 모델과 monitor 배달을 사용할 수 있고, Codex scout/executor는 `__ROLE_DIR__/README.md`의 참고 모델·안전 옵션과 turn 배달을 사용한다. 모델 기본값, 실행 인자, 실제 확인 결과를 구분하며 최신성·가격·최적 성능을 주장하지 않는다.

팀 상태를 확인해 빈 worker만 시작하고, spawn 반환과 `[READY]`를 구분한다. team·role·project·pane이 맞는 READY 뒤에만 작업을 보낸다. 공통 worker 계약은 `__ROLE_DIR__/workers.md`를 사용한다.

운영 흐름은 `SCOUT → MAP → TASK → 검증 리뷰`다. 역할당 in-flight 1개만 두고 겹치는 범위는 직렬화한다. ACK는 수신, DONE은 리뷰 대상이다. 긴 작업에는 단계·통과 수·남은 항목·막힘을 요청한다. 무응답이면 planner inbox와 상대 pane doctor를 확인하고 상태·마감을 재평가하되 무한 대기하거나 워커를 자동 종료하지 않는다.

승인 범위는 반복 질문하지 않는다. 같은 원인 3회 실패 시 접근을 바꾸거나 구체 BLOCKED로 보고하며 왕복 횟수만으로 사용자 확인을 강제하지 않는다. 메시지 본문은 안전한 literal 셸 인수로 전달하고 backtick·`$()`를 실행될 문자열로 재조합하지 않는다.
