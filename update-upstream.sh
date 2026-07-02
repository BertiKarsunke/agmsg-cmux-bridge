#!/usr/bin/env bash
set -euo pipefail

if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "error: working tree가 dirty입니다. 변경사항을 정리한 뒤 다시 실행하세요." >&2
  exit 1
fi

upstream_ref=upstream/main

git config rerere.enabled true
git fetch upstream

incoming=$(git rev-list --count HEAD.."$upstream_ref")
if [ "$incoming" -eq 0 ]; then
  echo "이미 최신"
  exit 0
fi

if git merge "$upstream_ref" --no-edit; then
  echo "upstream/main 병합 완료: ${incoming}개 커밋"
  exit 0
fi

echo "충돌 발생. 충돌 파일:" >&2
git diff --name-only --diff-filter=U >&2
echo "해결 후 git add + git commit 하세요." >&2
exit 1
