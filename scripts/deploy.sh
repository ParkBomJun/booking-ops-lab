#!/usr/bin/env bash
# deploy.sh — VM 에서 실행되는 배포 스크립트. CD(.github/workflows/cd.yml) 가 `az vm run-command` 로 호출한다.
#
# 사용법:  deploy.sh <image_tag>        image_tag = git 커밋 SHA (16진수 7~40자)
# 하는 일: .env 의 IMAGE_TAG 교체 → pull → (repo 를 같은 커밋으로 checkout) → up -d → /healthz 확인
#          → 실패하면 이전 태그로 같은 경로를 되밟아 롤백.
# 약속:   stdout 마지막 줄은 반드시 `DEPLOY_RESULT=ok|rolled_back|failed`. CD 는 이 줄만 보고 판정한다.
#          종료 코드: 0 = ok, 1 = rolled_back(이전 버전으로 복귀, 서비스는 살아 있음), 2 = failed(사람이 봐야 함).
# 로그:   /var/log/booking-deploy.log 에 모든 줄이 UTC 시각과 함께 남는다. run-command 출력은 4KB 에서 잘리므로
#          원인 분석은 이 파일로 한다.

set -euo pipefail   # -e 실패 시 중단, -u 미정의 변수 금지, pipefail 파이프 중간 실패도 실패로

# ---------- 설정. 전부 환경변수로 덮어쓸 수 있다 (로컬 시험용) ----------
REPO_DIR="${REPO_DIR:-/opt/booking-ops-lab}"                 # 저장소 checkout 위치 (compose 파일, 모니터링 설정)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"                        # compose 가 읽는 env. IMAGE_TAG 를 여기 쓴다
STATE_DIR="${STATE_DIR:-$REPO_DIR/.deploy}"                   # current_tag, previous_tag, history.log, lock
LOG_FILE="${LOG_FILE:-/var/log/booking-deploy.log}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
SYNC_REPO="${SYNC_REPO:-1}"                                   # 1 이면 git checkout <tag> 로 설정 파일도 같은 커밋에 맞춘다
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-60}"                # 이 시간 안에 안정 상태가 안 되면 롤백
HEALTH_STABLE_CHECKS="${HEALTH_STABLE_CHECKS:-3}"             # 연속 N 번 200 이어야 "건강" (뜨자마자 죽는 경우 잡기)
HEALTH_INTERVAL_SEC="${HEALTH_INTERVAL_SEC:-2}"
HEALTH_URLS="${HEALTH_URLS:-http://127.0.0.1:8080/healthz http://127.0.0.1:8081/healthz http://127.0.0.1:8082/healthz}"

export TZ=UTC   # 로그 시각을 Prometheus·Grafana 와 같은 UTC 로

# ---------- 로그 ----------
# printf 의 %(...)T 는 bash 내장 날짜 출력. date 프로세스를 줄마다 띄우지 않는다.
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T [deploy] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
# 명령 출력의 각 줄에 시각을 붙여 로그 파일과 stdout 양쪽에 남긴다.
stamp() { while IFS= read -r line; do printf '%(%Y-%m-%dT%H:%M:%SZ)T   %s\n' -1 "$line"; done | tee -a "$LOG_FILE"; }
# 명령을 실행하고 출력을 stamp 로 넘긴다. pipefail 덕에 명령의 실패가 그대로 반환된다.
run() { log "\$ $*"; "$@" 2>&1 | stamp; }

# ---------- 결과 마커. 어떤 경로로 끝나든 마지막 줄을 보장한다 ----------
RESULT=""
finish() {
  local rc=$?
  if [[ -z "$RESULT" ]]; then
    RESULT="failed"   # 예상 못 한 오류(set -e)로 빠져나온 경우
    log "unexpected exit (rc=$rc) — see $LOG_FILE"
  fi
  printf '%(%Y-%m-%dT%H:%M:%SZ)T [deploy] DEPLOY_RESULT=%s\n' -1 "$RESULT" >> "$LOG_FILE"
  printf 'DEPLOY_LOG=%s\n' "$LOG_FILE"
  printf 'DEPLOY_RESULT=%s\n' "$RESULT"
  case "$RESULT" in ok) exit 0 ;; rolled_back) exit 1 ;; *) exit 2 ;; esac
}
trap finish EXIT

# ---------- 준비 ----------
mkdir -p "$STATE_DIR"
# 로그 파일에 쓸 수 없으면(로컬 시험 등) 상태 디렉터리로 대체한다. 로그 때문에 배포가 죽으면 안 된다.
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  LOG_FILE="$STATE_DIR/deploy.log"
fi

NEW_TAG="${1:-}"
if ! [[ "$NEW_TAG" =~ ^[0-9a-f]{7,40}$ ]]; then
  log "usage: deploy.sh <image_tag>  (git commit sha, hex 7-40 chars). got: '${NEW_TAG}'"
  exit 2
fi

# 동시 배포 방지. fd 9 에 잠금 파일을 열고 flock -n(기다리지 않음). 스크립트가 끝나면 fd 가 닫혀 잠금도 풀린다.
exec 9>"$STATE_DIR/deploy.lock"
if ! flock -n 9; then
  log "another deploy is already running (lock: $STATE_DIR/deploy.lock)"
  exit 2
fi

CURRENT_TAG=""
PREVIOUS_TAG=""
if [[ -f "$STATE_DIR/current_tag" ]]; then CURRENT_TAG="$(<"$STATE_DIR/current_tag")"; fi
if [[ -f "$STATE_DIR/previous_tag" ]]; then PREVIOUS_TAG="$(<"$STATE_DIR/previous_tag")"; fi
# 롤백 대상: 보통은 지금 돌고 있는 태그. 같은 태그를 재배포하는 경우(재시도)는 그 전 태그.
ROLLBACK_TAG="$CURRENT_TAG"
if [[ "$CURRENT_TAG" == "$NEW_TAG" ]]; then ROLLBACK_TAG="$PREVIOUS_TAG"; fi

# compose 호출을 한 곳에 모은다. 두 파일을 겹치고, env 파일을 명시한다 (--env-file 을 주면 .env 자동 로드는 꺼진다).
compose() {
  "$DOCKER_BIN" compose --project-directory "$REPO_DIR" --env-file "$ENV_FILE" \
    -f "$REPO_DIR/docker-compose.yml" -f "$REPO_DIR/docker-compose.prod.yml" "$@"
}

# .env 의 IMAGE_TAG 를 바꾼다(없으면 추가). 태그는 위에서 16진수로 검증했으므로 sed 패턴에 안전하다.
set_image_tag() {
  local tag="$1"
  if [[ ! -f "$ENV_FILE" ]]; then log "env file not found: $ENV_FILE"; return 1; fi
  # 끝 줄바꿈 보장. 없으면 추가한 줄이 기존 마지막 줄 뒤에 붙어 무시된다 (훈련 1번 때 겪은 일).
  # tail -c1 = 마지막 1바이트. $(...) 는 끝의 줄바꿈을 지우므로, 결과가 비어 있지 않으면 마지막 글자가 줄바꿈이 아니다.
  if [[ -n "$(tail -c1 "$ENV_FILE")" ]]; then echo >> "$ENV_FILE"; fi
  if grep -q '^IMAGE_TAG=' "$ENV_FILE"; then
    sed -i -e "s/^IMAGE_TAG=.*/IMAGE_TAG=${tag}/" "$ENV_FILE"
  else
    printf 'IMAGE_TAG=%s\n' "$tag" >> "$ENV_FILE"
  fi
  log "IMAGE_TAG=${tag} written to $ENV_FILE"
}

# git 은 저장소 "소유자" 권한으로 실행한다. run-command 는 root 로 돌지만 /opt/booking-ops-lab 은 cloud-init 이
# opsadmin 소유로 만들었다. root 가 그냥 git 을 돌리면 "dubious ownership" 으로 거부되고, 억지로 돌리면 .git 안에
# root 소유 파일이 생겨 이후 opsadmin 의 git 작업이 깨진다. runuser 로 소유자가 되어 실행하면 둘 다 피한다.
git_() {
  local owner; owner="$(stat -c %U "$REPO_DIR")"
  if [[ "$(id -un)" == "root" && "$owner" != "root" ]]; then
    runuser -u "$owner" -- git -C "$REPO_DIR" "$@"
  else
    git -C "$REPO_DIR" "$@"
  fi
}

# compose 파일·prometheus.yml·알림 규칙을 이미지와 같은 커밋으로 맞춘다. 이미지만 바꾸고 설정은 옛날 것이면 반쪽 배포다.
# git 저장소가 아니면(수동 복사 설치) 건너뛴다.
sync_repo() {
  local tag="$1"
  if [[ "$SYNC_REPO" != "1" ]]; then log "repo sync skipped (SYNC_REPO=$SYNC_REPO)"; return 0; fi
  if ! git_ rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "repo sync skipped ($REPO_DIR is not a git checkout)"; return 0
  fi
  run git_ fetch --quiet origin || return 1
  # cloud-init 은 --depth 1 로 얕게 복제한다. 옛 커밋(롤백 대상 등)이 없으면 전체 이력을 받는다. 한 번 받으면 다음부터는 바로 통과.
  if ! git_ cat-file -e "${tag}^{commit}" 2>/dev/null; then
    log "commit ${tag} is not in the local clone (shallow clone?) — fetching full history"
    run git_ fetch --quiet --unshallow origin || run git_ fetch --quiet origin "$tag" || return 1
  fi
  # --detach: 브랜치가 아니라 커밋 자체를 체크아웃. VM 에서 커밋을 만들 일은 없다.
  run git_ checkout --quiet --detach "$tag" || return 1
}

# 모든 /healthz 가 연속 HEALTH_STABLE_CHECKS 번 200 이면 성공. 제한 시간 안에 못 이루면 실패.
wait_healthy() {
  local -a urls
  read -r -a urls <<< "$HEALTH_URLS"
  local deadline=$(( SECONDS + HEALTH_TIMEOUT_SEC )) streak=0 url code all_ok
  while (( SECONDS < deadline )); do
    all_ok=1
    for url in "${urls[@]}"; do
      # -m 3: 3초 안에 응답 없으면 포기. 실패 시 http_code 는 000.
      code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" || true)"
      if [[ "$code" != "200" ]]; then all_ok=0; log "health $url -> ${code:-000}"; break; fi
    done
    if (( all_ok )); then
      streak=$(( streak + 1 ))
      log "health ok (${streak}/${HEALTH_STABLE_CHECKS})"
      if (( streak >= HEALTH_STABLE_CHECKS )); then return 0; fi
    else
      streak=0
    fi
    sleep "$HEALTH_INTERVAL_SEC"
  done
  log "health check did not stabilize within ${HEALTH_TIMEOUT_SEC}s"
  return 1
}

# 실패 원인 분석용 스냅샷. stdout(4KB 제한) 이 아니라 로그 파일에만 남긴다.
dump_state() {
  {
    echo "----- docker compose ps -----"
    compose ps 2>&1 || true
    echo "----- last 40 log lines per app service -----"
    compose logs --tail 40 --no-color booking-api worker mock-forwarder 2>&1 || true
    echo "-----------------------------"
  } >> "$LOG_FILE"
}

record() {  # 배포 이력 한 줄. README 의 "롤백 기록" 근거가 된다.
  printf '%(%Y-%m-%dT%H:%M:%SZ)T %s new=%s rollback_to=%s\n' -1 "$1" "$NEW_TAG" "${ROLLBACK_TAG:-none}" >> "$STATE_DIR/history.log"
}

# 이전 태그로 되돌린다. 같은 pull → up → health 경로를 쓰되, pull 은 "없을 때만"(--policy missing):
# 이전 이미지는 디스크에 있으므로 GHCR 이 죽어 있어도 롤백이 된다.
rollback() {
  if [[ -z "$ROLLBACK_TAG" ]]; then
    log "no previous tag to roll back to (first deploy?) — service may be down, needs a human"
    dump_state; record failed; RESULT="failed"; exit 2
  fi
  log "rolling back to ${ROLLBACK_TAG}"
  set_image_tag "$ROLLBACK_TAG"
  sync_repo "$ROLLBACK_TAG" || log "warning: repo sync to ${ROLLBACK_TAG} failed, continuing with current files"
  run compose pull --quiet --policy missing || log "warning: pull of ${ROLLBACK_TAG} failed, using local images"
  run compose up -d --remove-orphans --quiet-pull || log "warning: compose up during rollback returned non-zero"
  if wait_healthy; then
    log "rollback complete: running ${ROLLBACK_TAG}"
    printf '%s\n' "$ROLLBACK_TAG" > "$STATE_DIR/current_tag"
    record rolled_back; RESULT="rolled_back"; exit 1
  fi
  log "rollback did NOT restore health — service down, needs a human"
  dump_state; record failed; RESULT="failed"; exit 2
}

# ---------- 본 흐름 ----------
main() {
  log "=== deploy start: new=${NEW_TAG} current=${CURRENT_TAG:-none} rollback_target=${ROLLBACK_TAG:-none} ==="
  if ! set_image_tag "$NEW_TAG"; then RESULT="failed"; exit 2; fi

  # 1) pull 먼저. 태그가 GHCR 에 없으면 여기서 끝난다 — 아직 아무것도 바꾸지 않았으므로 롤백도 필요 없다.
  if ! run compose pull --quiet; then
    log "pull failed — nothing was restarted. restoring IMAGE_TAG"
    if [[ -n "$CURRENT_TAG" ]]; then set_image_tag "$CURRENT_TAG"; fi
    record failed; RESULT="failed"; exit 2
  fi

  # 2) 설정 파일을 같은 커밋으로. 실패하면(VM 에서 손으로 고친 파일이 있는 등) 아직 컨테이너는 그대로다.
  if ! sync_repo "$NEW_TAG"; then
    log "repo sync failed — nothing was restarted. restoring IMAGE_TAG"
    if [[ -n "$CURRENT_TAG" ]]; then set_image_tag "$CURRENT_TAG"; fi
    record failed; RESULT="failed"; exit 2
  fi

  # 3) 바뀐 서비스만 다시 만든다. --remove-orphans: compose 파일에서 사라진 서비스의 컨테이너 정리.
  if ! run compose up -d --remove-orphans --quiet-pull; then
    log "compose up failed"
    dump_state; rollback
  fi

  # 4) 건강 확인. 실패하면 롤백.
  if ! wait_healthy; then
    dump_state; rollback
  fi

  # 5) 성공 기록. previous_tag 는 수동 롤백(workflow_dispatch) 때 참고한다.
  if [[ -n "$CURRENT_TAG" && "$CURRENT_TAG" != "$NEW_TAG" ]]; then
    printf '%s\n' "$CURRENT_TAG" > "$STATE_DIR/previous_tag"
  fi
  printf '%s\n' "$NEW_TAG" > "$STATE_DIR/current_tag"
  record ok

  # 6) 태그 없는(dangling) 이미지만 정리. -a 는 쓰지 않는다: 이전 태그 이미지를 지우면 롤백이 GHCR 에 의존하게 된다.
  run "$DOCKER_BIN" image prune -f || log "warning: image prune failed (ignored)"

  log "=== deploy ok: ${NEW_TAG} (previous: ${CURRENT_TAG:-none}) ==="
  printf 'DEPLOY_TAG=%s\nPREVIOUS_TAG=%s\n' "$NEW_TAG" "${CURRENT_TAG:-none}"
  RESULT="ok"
}

main "$@"
