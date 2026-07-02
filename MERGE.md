# upstream 머지 런북

- 구조: 이 저장소는 origin=BertiKarsunke/agmsg-cmux-bridge fork, upstream=fujibee/agmsg이고, master는 upstream/main보다 로컬 커밋이 다수 앞서 있다.
- 평소 절차: 리포 루트에서 `./update-upstream.sh`를 실행하면 된다.
- 충돌 시 절차: 충돌 파일을 열어 해결한 뒤 `git add <file>` 후 `git commit` 한다. `rerere`가 켜져 있어 같은 충돌은 다음부터 자동 해결된다.
- 충돌 주의 영역: 로컬 변경이 `scripts/`, `tests/`, `docs/` 전반과 겹쳐 충돌이 자주 날 수 있다.
- 검증: 머지 후 `bats tests`를 실행하고, 필요하면 관련 스크립트를 수동으로 확인한다.
