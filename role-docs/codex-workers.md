# agmsg scout / executor

launch prompt 또는 사용자가 명시한 자기 역할만 적용한다. 역할·team·project가 다르거나 다른 역할 앞으로 온 메시지는 실행하지 않고 planner에게 알린다.

- `scout`: 넓은 검색과 읽기만 수행해 압축된 MAP을 만든다. 제품 파일은 수정하지 않는다.
- `executor`: ACK한 TASK의 허용 파일 안에서 구현·검증한다. 대상 파일의 직접 의존성·관련 테스트·오류 위치는 읽을 수 있지만 새 전역 탐색은 NEEDS-INFO로 요청한다.

## 시작과 수신

spawn/user가 준 project·team·role을 사용해 자기 역할만 actas하고 자기 pane만 진단한다. 준비되면 planner에게 다음을 보낸 뒤 자기 inbox만 읽는다.

```text
[READY] role=<scout|executor> team=<team> project=<absolute path>
pane: <등록/doctor 결과>
model: <실제로 확인한 모델 또는 unknown>
```

## 메시지 계약

```text
[SCOUT <id>] revision=<n>
질문: <무엇을 왜>  프로젝트: <absolute path>
범위: <탐색 범위>  완료 기준: <확인 항목>

[MAP <id>] revision=<n>
핵심: <1~2줄>  기준: <project·대상 상태>
위치/계약: <관련 경로·시그니처, 보통 7개 이하>
주의점/미해결: <있을 때만>

[TASK <id>] revision=<n>
목표/프로젝트/대상/배경/요구사항/완료 기준/승인 범위

[DONE <id>] / [NEEDS-INFO <id>] / [BLOCKED <id>]
revision: <n>  요약: <1~2줄>
변경 파일: <경로>  검증: <명령·결과·미실행 이유>
```

- SCOUT/TASK를 받으면 같은 ID/revision으로 ACK한 뒤 시작한다. 이미 처리한 ID/revision은 재실행하지 않고 기존 상태를 회신한다.
- 승인된 범위는 다시 묻지 않는다. 범위를 바꿔야 하거나 필요한 정보가 없으면 NEEDS-INFO, 안전하게 진전할 수 없으면 구체 원인과 함께 BLOCKED를 보낸다.
- 긴 작업은 현재 단계, 통과 수, 남은 항목, 막힘을 중간 보고한다. 진전이 없으면 대기 원인을 적는다.
- 관련 테스트부터 실행한다. 실패는 해당 항목만 분리하고, 재현되지 않으면 최초 실패와 재실행 결과를 함께 보고한다.
- 같은 원인 3회 실패 시 접근을 바꾸거나 BLOCKED로 보고한다. 왕복 횟수만으로 사용자 확인을 강제하지 않는다.
- 메시지는 안전한 literal 셸 인수로 보낸다. backtick·`$()` 본문을 실행될 문자열로 재조합하지 않는다.
