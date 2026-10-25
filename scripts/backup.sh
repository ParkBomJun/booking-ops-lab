#!/usr/bin/env bash
# scripts/backup.sh — PostgreSQL 논리 백업(pg_dump 커스텀 포맷) + 무결성 확인 + 보관 정리.
#
# 사용:
#   scripts/backup.sh                                   # 로컬: <repo>/backups/ 에 저장
#   BACKUP_TARGET=azure BACKUP_STORAGE_ACCOUNT=<계정> scripts/backup.sh   # 로컬 저장 + Blob 업로드
#
# 환경변수:
#   BACKUP_TARGET           auto(기본) | local | azure
#                           auto = az CLI 가 있고 BACKUP_STORAGE_ACCOUNT 가 비어 있지 않으면 azure, 아니면 local
#   BACKUP_DIR              산출물 디렉터리. 기본 <repo>/backups
#   BACKUP_RETENTION_DAYS   로컬 파일 보관 일수(1 이상). 기본 7
#   BACKUP_STORAGE_ACCOUNT  azure 모드 필수. Storage Account 이름 (예: stbookingopsbackup)
#   BACKUP_CONTAINER        Blob 컨테이너 이름. 기본 backups
#   DOCKER                  docker 명령. 비우면 자동 선택(docker → docker.exe)
#
# 산출물(BACKUP_DIR):
#   <db>-<UTC시각>.dump            pg_dump -Fc 결과
#   <db>-<UTC시각>.dump.sha256     sha256sum -c 형식
#   <db>-<UTC시각>.manifest.json   db, 크기, 소요 ms, PG 버전, 테이블별 행 수, 마이그레이션 목록
#   LAST_SUCCESS                   1행: 마지막 성공 시각(UTC, ISO 8601). healthcheck.sh 가 읽는다
#
# 종료 코드: 0 성공. 그 외 실패 — stderr 마지막 줄 "backup: FAIL: ..." 한 줄이 원인.
# 이 스크립트는 DB 를 읽기만 한다. 지우는 것은 BACKUP_DIR 안의 오래된 백업 파일뿐이다.

# -E : 함수·서브셸 안에서 난 오류도 ERR trap 이 받는다
# -e : 명령이 실패하면 즉시 중단      -u : 정하지 않은 변수를 쓰면 오류
# -o pipefail : 파이프 중간 명령이 실패해도 실패로 본다 (pg_dump | gzip 류의 "조용한 실패" 방지)
# shellcheck disable=SC2016  # pg_sh '...' 안의 $변수 는 컨테이너 셸이 푼다. 작은따옴표가 의도다
set -Eeuo pipefail
# 새로 만드는 파일은 소유자만 읽고 쓴다(600). 가짜 데이터라도 백업은 접근 범위를 좁히는 습관.
umask 077

usage() { sed -n '2,/^$/p' "$0" | cut -c3-; }
case "${1:-}" in -h|--help) usage; exit 0 ;; "") ;; *) usage >&2; exit 1 ;; esac

# 스크립트 위치 기준으로 리포지토리 루트를 찾는다. cron 처럼 다른 디렉터리에서 불러도 동작한다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG=backup
# shellcheck source=lib/pg-common.sh
source "$SCRIPT_DIR/lib/pg-common.sh"

BACKUP_TARGET="${BACKUP_TARGET:-auto}"
BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_STORAGE_ACCOUNT="${BACKUP_STORAGE_ACCOUNT:-}"
BACKUP_CONTAINER="${BACKUP_CONTAINER:-backups}"
PG_SERVICE=postgres

# ---------- 실패 처리 ----------
# STEP 은 "지금 어느 단계인가". 실패하면 이 값이 한 줄 이유에 들어간다.
STEP=start
TMP_IN_CONTAINER=""   # 컨테이너 안 임시 덤프. 어떻게 끝나든 지운다.
# shellcheck disable=SC2329  # trap 으로만 호출된다
on_err() {
  local rc=$?
  printf '[%s] backup: FAIL: step=%s exit=%d (line %s)\n' "$(date -u +%FT%TZ)" "$STEP" "$rc" "${BASH_LINENO[0]}" >&2
  exit "$rc"
}
# shellcheck disable=SC2329  # trap 으로만 호출된다
cleanup() {
  if [ -n "$TMP_IN_CONTAINER" ]; then
    pg_sh 'rm -f "$1"' "$TMP_IN_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap on_err ERR
trap cleanup EXIT

# ---------- 입력 검증 ----------
STEP=config
[[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] && [ "$BACKUP_RETENTION_DAYS" -ge 1 ] \
  || die "BACKUP_RETENTION_DAYS 는 1 이상의 정수여야 한다: '$BACKUP_RETENTION_DAYS'"

case "$BACKUP_TARGET" in
  local) MODE=local ;;
  azure) MODE=azure ;;
  auto)
    if command -v az >/dev/null 2>&1 && [ -n "$BACKUP_STORAGE_ACCOUNT" ]; then MODE=azure; else MODE=local; fi ;;
  *) die "BACKUP_TARGET 은 auto | local | azure 중 하나: '$BACKUP_TARGET'" ;;
esac
if [ "$MODE" = azure ]; then
  command -v az >/dev/null 2>&1 || die "BACKUP_TARGET=azure 인데 az CLI 가 없다"
  [ -n "$BACKUP_STORAGE_ACCOUNT" ] || die "BACKUP_TARGET=azure 인데 BACKUP_STORAGE_ACCOUNT 가 비어 있다"
fi
log "mode=$MODE dir=$BACKUP_DIR retention_days=$BACKUP_RETENTION_DAYS"

mkdir -p "$BACKUP_DIR"

# ---------- 중복 실행 방지 ----------
# cron 이 겹치거나 사람이 수동으로 또 돌릴 때 덤프 두 개가 동시에 돌지 않게 한다.
# fd 9 에 lock 파일을 열고 flock -n(기다리지 않음). 스크립트가 끝나면 fd 가 닫히며 자동 해제.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BACKUP_DIR/.backup.lock"
  flock -n 9 || die "다른 backup.sh 가 실행 중 (lock: $BACKUP_DIR/.backup.lock)"
fi

# ---------- DB 준비 확인 ----------
STEP=docker
pick_docker
cd "$REPO_ROOT"   # docker compose 는 현재 디렉터리의 docker-compose.yml 을 쓴다

STEP=db-ready
pg_sh 'pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  || die "postgres 가 응답하지 않는다 (docker compose ps 로 컨테이너 상태 확인)"
DB="$(pg_live_db)"
valid_dbname "$DB" || die "컨테이너의 POSTGRES_DB 값이 이상하다: '$DB'"

# ---------- 덤프 직전 상태 기록 ----------
# 복구 후 비교할 기준값. 덤프와 같은 순간은 아니므로(별도 트랜잭션) 쓰기가 진행 중이면 몇 건 차이 날 수 있다.
STEP=inspect
PG_SERVER_VERSION="$(pg_query "$DB" "SHOW server_version")"
PG_DUMP_VERSION="$(pg_sh 'pg_dump --version' | sed 's/^pg_dump (PostgreSQL) //')"
ROWS="$(pg_row_counts "$DB")"
MIGRATIONS="$(pg_migrations "$DB")"

# ---------- pg_dump ----------
STEP=pg_dump
TS="$(date -u +%Y%m%dT%H%M%SZ)"   # 파일명은 항상 UTC. 서버(UTC)와 로컬(KST)이 섞여도 정렬이 맞는다
BASE="$DB-$TS"
TMP_IN_CONTAINER="/tmp/$BASE.dump"
t0=$(now_ms)
#   -U : 접속 역할. 컨테이너 안 로컬 소켓은 trust 인증이라 비밀번호 없음
#   -d : 대상 DB
#   -Fc: 커스텀 포맷. 압축되고, pg_restore 로 테이블 단위 선택 복구와 --list 검사가 된다. 평문 SQL 은 둘 다 안 된다
#   --lock-wait-timeout : 잠금을 30초 넘게 못 잡으면 실패. 마이그레이션 중 cron 이 무한 대기하는 일을 막는다
#   -f : 컨테이너 안 파일로 먼저 쓴다. "원본 해시" 를 여기서 재고, 호스트로 보낸 뒤 다시 비교한다
pg_sh 'pg_dump -U "$POSTGRES_USER" -d "$1" -Fc --lock-wait-timeout=30000 -f "$2"' "$DB" "$TMP_IN_CONTAINER"
DURATION_MS=$(( $(now_ms) - t0 ))

# ---------- 덤프가 읽히는지 확인 ----------
# pg_restore --list 는 아카이브의 목차(TOC)를 출력한다. 깨진 파일이면 여기서 실패한다.
STEP=verify-archive
TOC_ENTRIES="$(pg_sh 'pg_restore --list "$1" | grep -c "^[0-9]"' "$TMP_IN_CONTAINER")"
[ "$TOC_ENTRIES" -gt 0 ] || die "덤프 목차(TOC)가 비어 있다"

# ---------- 호스트로 복사 + sha256 비교 ----------
STEP=copy-out
copy_out_dump "$TMP_IN_CONTAINER" "$BACKUP_DIR/$BASE.dump"
pg_sh 'rm -f "$1"' "$TMP_IN_CONTAINER"
TMP_IN_CONTAINER=""
SIZE="$(stat -c %s "$BACKUP_DIR/$BASE.dump")"
SHA="$(cut -d ' ' -f1 "$BACKUP_DIR/$BASE.dump.sha256")"

# ---------- manifest ----------
# jq 없이 printf 로 만든다. 값은 전부 숫자 아니면 검증된 식별자라 이스케이프가 필요 없다.
STEP=manifest
row_json=""
sep=""
while IFS=$'\t' read -r t n; do
  [ -n "$t" ] || continue
  row_json="$row_json$sep\"$t\": $n"
  sep=", "
done <<< "$ROWS"
mig_json=""
if [ -n "$MIGRATIONS" ]; then
  mig_json="\"${MIGRATIONS//,/\", \"}\""   # a,b → "a", "b"
fi
{
  printf '{\n'
  printf '  "db": "%s",\n' "$DB"
  printf '  "file": "%s",\n' "$BASE.dump"
  printf '  "created_at": "%s",\n' "$(date -u +%FT%TZ)"
  printf '  "backup_target": "%s",\n' "$MODE"
  printf '  "size_bytes": %s,\n' "$SIZE"
  printf '  "sha256": "%s",\n' "$SHA"
  printf '  "duration_ms": %s,\n' "$DURATION_MS"
  printf '  "pg_server_version": "%s",\n' "$PG_SERVER_VERSION"
  printf '  "pg_dump_version": "%s",\n' "$PG_DUMP_VERSION"
  printf '  "toc_entries": %s,\n' "$TOC_ENTRIES"
  printf '  "schema_migrations": [%s],\n' "$mig_json"
  printf '  "row_counts": {%s}\n' "$row_json"
  printf '}\n'
} > "$BACKUP_DIR/$BASE.manifest.json"

# ---------- Azure Blob 업로드 ----------
if [ "$MODE" = azure ]; then
  STEP=az-login
  # VM 의 관리 ID(managed identity)로 로그인한다. 키 파일도 비밀번호도 없다.
  #   --allow-no-subscriptions : 이 ID 에는 구독 수준 권한이 없어도 된다. Storage 컨테이너 하나에 대한 데이터 역할만 준다(최소 권한)
  #   -o none                  : 토큰·테넌트 정보를 출력하지 않는다
  az login --identity --allow-no-subscriptions --only-show-errors -o none \
    || die "az login --identity 실패 (VM 관리 ID 와 역할 할당 확인)"
  STEP=az-upload
  #   --auth-mode login : 계정 키(secret) 대신 방금 로그인한 ID 의 RBAC 권한으로 올린다
  #   덮어쓰기 옵션을 주지 않는다: 같은 이름이 이미 있으면 실패한다. 기존 백업을 실수로 덮는 일을 막는다
  for f in "$BASE.dump" "$BASE.dump.sha256" "$BASE.manifest.json"; do
    az storage blob upload --auth-mode login \
      --account-name "$BACKUP_STORAGE_ACCOUNT" --container-name "$BACKUP_CONTAINER" \
      --name "$f" --file "$BACKUP_DIR/$f" --only-show-errors -o none \
      || die "Blob 업로드 실패: $f"
  done
  # Blob 의 보관 기간 정리는 Storage 수명 주기 정책(Terraform 의 azurerm_storage_management_policy)이 맡는다.
  # 스크립트는 blob 을 지우지 않는다. 이유: (1) 정책은 cron 이 죽어 있어도 돈다 (2) VM 의 ID 에 삭제 권한을 줄 필요가 없다.
  log "uploaded 3 blobs to $BACKUP_STORAGE_ACCOUNT/$BACKUP_CONTAINER (blob 정리는 수명 주기 정책)"
fi

# ---------- 로컬 보관 정리 ----------
# 보관 일수를 분으로 바꿔 -mmin 으로 찾는다. -mtime +7 은 "만 8일 이상" 으로 해석돼 하루가 어긋난다.
# BACKUP_DIR 바로 아래(-maxdepth 1)의 백업 산출물 패턴만 지운다. LAST_SUCCESS, lock, 다른 파일은 건드리지 않는다.
STEP=prune
PRUNE_MIN=$(( BACKUP_RETENTION_DAYS * 24 * 60 ))
pruned=0
while IFS= read -r -d '' f; do
  rm -f -- "$f"
  pruned=$(( pruned + 1 ))
  log "pruned $(basename "$f")"
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
           \( -name '*.dump' -o -name '*.dump.sha256' -o -name '*.manifest.json' -o -name '*.dump.part' \) \
           -mmin +"$PRUNE_MIN" -print0)

# ---------- 성공 표식 ----------
# 1행만 읽으면 된다: 마지막 성공 시각(UTC). healthcheck.sh 는 이 값이 26시간보다 오래되면 경고한다.
# 임시 파일에 쓰고 mv 한다. 쓰는 도중 읽어도 반쯤 쓰인 파일을 보지 않는다.
STEP=marker
printf '%s\nfile=%s\ntarget=%s\n' "$(date -u +%FT%TZ)" "$BASE.dump" "$MODE" > "$BACKUP_DIR/LAST_SUCCESS.tmp"
mv "$BACKUP_DIR/LAST_SUCCESS.tmp" "$BACKUP_DIR/LAST_SUCCESS"
# TODO(node_exporter, 3단계): textfile collector 로 지표를 남겨 Prometheus 규칙(time() - 값 > 26h)으로 알린다.
#   printf 'booking_backup_last_success_timestamp_seconds %s\n' "$(date +%s)" > /var/lib/node_exporter/textfile/backup.prom

STEP=finish
log "OK db=$DB file=$BASE.dump size_bytes=$SIZE duration_ms=$DURATION_MS toc_entries=$TOC_ENTRIES target=$MODE pruned=$pruned"
