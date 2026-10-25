#!/usr/bin/env bash
# scripts/restore.sh — 덤프 파일을 지정한 DB 로 복구한다. 복구 훈련(5번)과 실제 복구에 같이 쓴다.
#
# 사용:
#   scripts/restore.sh --target <db> [--yes] <덤프파일>
#   scripts/restore.sh --target <db> [--yes] --from-azure <blob이름>
#   운영 DB 로 복구(덮어쓰기)할 때만:  --target <운영DB> --yes --i-know-this-overwrites <덤프파일>
#
# 안전장치:
#   --yes 가 없으면 계획만 출력하고 끝낸다(종료 코드 2). 아무것도 바꾸지 않는다.
#   --target 은 항상 명시한다. 기본값이 없다.
#   대상이 운영 DB(컨테이너의 POSTGRES_DB)면 --i-know-this-overwrites 까지 있어야 한다.
#   postgres / template0 / template1 은 거부한다.
#   복구 전에 대상 DB 를 먼저 덤프한다 (<db>-pre-restore-<UTC>.dump). 되돌릴 길을 남긴다.
#   운영 DB 복구 중에는 worker 를 멈춘다(복구 도중 행을 집어가지 않게). 끝나면(실패해도) 다시 켠다.
#   덤프 옆에 .sha256 이 있으면 먼저 검사한다. .manifest.json 이 있으면 복구 후 행 수를 비교한다.
#
# 환경변수: BACKUP_DIR(기본 <repo>/backups), BACKUP_STORAGE_ACCOUNT, BACKUP_CONTAINER(기본 backups), DOCKER
# 종료 코드: 0 성공 | 2 계획만 출력 | 3 복구는 됐지만 검증 불일치 | 1 그 외 실패("restore: FAIL: ..." 한 줄)

# shellcheck disable=SC2016  # pg_sh '...' 안의 $변수 는 컨테이너 셸이 푼다. 작은따옴표가 의도다
set -Eeuo pipefail
umask 077

usage() { sed -n '2,/^$/p' "$0" | cut -c3-; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG=restore
# shellcheck source=lib/pg-common.sh
source "$SCRIPT_DIR/lib/pg-common.sh"

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
BACKUP_STORAGE_ACCOUNT="${BACKUP_STORAGE_ACCOUNT:-}"
BACKUP_CONTAINER="${BACKUP_CONTAINER:-backups}"
PG_SERVICE=postgres

# ---------- 인자 ----------
TARGET=""; YES=0; OVERWRITE_OK=0; FROM_AZURE=""; DUMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)      [ $# -ge 2 ] || die "--target 에 DB 이름이 필요하다"; TARGET="$2"; shift 2 ;;
    --from-azure)  [ $# -ge 2 ] || die "--from-azure 에 blob 이름이 필요하다"; FROM_AZURE="$2"; shift 2 ;;
    --yes)         YES=1; shift ;;
    --i-know-this-overwrites) OVERWRITE_OK=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --*)           die "모르는 옵션: $1" ;;
    *)             [ -z "$DUMP" ] || die "덤프 파일은 하나만 줄 수 있다"; DUMP="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; die "--target <db> 는 필수다"; }
valid_dbname "$TARGET" || die "DB 이름 형식이 아니다: '$TARGET' (소문자·숫자·밑줄)"
case "$TARGET" in postgres|template0|template1) die "시스템 DB 에는 복구하지 않는다: $TARGET" ;; esac
if [ -n "$DUMP" ] && [ -n "$FROM_AZURE" ]; then die "덤프 파일과 --from-azure 중 하나만 준다"; fi
if [ -z "$DUMP" ] && [ -z "$FROM_AZURE" ]; then usage >&2; die "덤프 파일 또는 --from-azure <blob> 이 필요하다"; fi

# ---------- 실패 처리 ----------
STEP=start
TMP_IN_CONTAINER=""
WORKER_STOPPED=0
# shellcheck disable=SC2329  # trap 으로만 호출된다
on_err() {
  local rc=$?
  printf '[%s] restore: FAIL: step=%s exit=%d (line %s)\n' "$(date -u +%FT%TZ)" "$STEP" "$rc" "${BASH_LINENO[0]}" >&2
  exit "$rc"
}
# shellcheck disable=SC2329  # trap 으로만 호출된다
cleanup() {
  # 어떤 이유로 끝나든: 멈췄던 worker 는 다시 켜고, 컨테이너 안 임시 파일은 지운다.
  if [ "$WORKER_STOPPED" = 1 ]; then
    log "worker 재시작"
    compose start worker >/dev/null 2>&1 || log "worker 재시작 실패 — 수동으로 'docker compose start worker'"
  fi
  if [ -n "$TMP_IN_CONTAINER" ]; then
    pg_sh 'rm -f "$1"' "$TMP_IN_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap on_err ERR
trap cleanup EXIT

# ---------- DB 와 운영 DB 이름 ----------
STEP=docker
pick_docker
cd "$REPO_ROOT"
STEP=db-ready
pg_sh 'pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  || die "postgres 가 응답하지 않는다 (docker compose ps 로 컨테이너 상태 확인)"
LIVE_DB="$(pg_live_db)"
# 운영 DB 이름을 못 읽으면 "운영 DB 인지" 판단을 못 하므로 멈춘다(fail-closed).
valid_dbname "$LIVE_DB" || die "운영 DB 이름을 확인할 수 없다 — 안전을 위해 중단"
IS_LIVE=0
[ "$TARGET" = "$LIVE_DB" ] && IS_LIVE=1
if [ "$IS_LIVE" = 1 ] && [ "$OVERWRITE_OK" = 0 ]; then
  die "대상 '$TARGET' 은 운영 DB 다. 정말 덮어쓰려면 --i-know-this-overwrites 를 함께 준다"
fi

# ---------- 덤프 파일 준비 ----------
STEP=source
if [ -n "$FROM_AZURE" ]; then
  # blob 이름은 파일명 한 조각이어야 한다. '/' 나 '..' 가 섞이면 BACKUP_DIR 바깥에 쓰게 되므로 거부한다.
  [[ "$FROM_AZURE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$FROM_AZURE" != *..* ]] \
    || die "blob 이름 형식이 아니다: '$FROM_AZURE' (영숫자 . _ - 만, 경로 불가)"
  command -v az >/dev/null 2>&1 || die "--from-azure 에는 az CLI 가 필요하다"
  [ -n "$BACKUP_STORAGE_ACCOUNT" ] || die "BACKUP_STORAGE_ACCOUNT 가 비어 있다"
  mkdir -p "$BACKUP_DIR"
  # 이미 로그인돼 있으면(사람이 az login 한 경우) 그대로 쓰고, 아니면 VM 관리 ID 로 로그인한다.
  az account show -o none 2>/dev/null \
    || az login --identity --allow-no-subscriptions --only-show-errors -o none \
    || die "az 로그인 실패"
  az_get() {  # $1 = blob 이름. 로컬 같은 이름으로 내려받는다
    az storage blob download --auth-mode login \
      --account-name "$BACKUP_STORAGE_ACCOUNT" --container-name "$BACKUP_CONTAINER" \
      --name "$1" --file "$BACKUP_DIR/$1" --only-show-errors -o none
  }
  az_get "$FROM_AZURE" || die "Blob 다운로드 실패: $FROM_AZURE"
  # 검증용 파일은 있으면 받고, 없어도 진행한다.
  az_get "$FROM_AZURE.sha256" 2>/dev/null || log "sha256 blob 없음"
  az_get "${FROM_AZURE%.dump}.manifest.json" 2>/dev/null || log "manifest blob 없음"
  DUMP="$BACKUP_DIR/$FROM_AZURE"
fi
[ -f "$DUMP" ] || die "덤프 파일이 없다: $DUMP"
DUMP="$(readlink -f "$DUMP")"
DUMP_DIR="$(dirname "$DUMP")"
DUMP_NAME="$(basename "$DUMP")"
SHA_FILE="$DUMP.sha256"
MANIFEST="${DUMP%.dump}.manifest.json"

STEP=checksum
if [ -f "$SHA_FILE" ]; then
  # sha256 파일에는 파일명이 상대 경로로 적혀 있어 그 디렉터리에서 검사한다.
  (cd "$DUMP_DIR" && sha256sum -c --quiet "$(basename "$SHA_FILE")") || die "sha256 불일치: $DUMP_NAME"
  log "sha256 OK ($DUMP_NAME)"
else
  log "sha256 파일이 없어 검사를 건너뛴다"
fi

HAS_MANIFEST=no
[ -f "$MANIFEST" ] && HAS_MANIFEST=yes
log "plan: source=$DUMP_NAME target=$TARGET live_db=$IS_LIVE stop_worker=$IS_LIVE manifest=$HAS_MANIFEST"
if [ "$YES" = 0 ]; then
  log "계획만 출력했다. 실행하려면 --yes 를 붙인다"
  exit 2
fi

# ---------- 복구 ----------
T_TOTAL0=$(now_ms)
TS="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$IS_LIVE" = 1 ]; then
  STEP=stop-worker
  # worker 가 복구 중간 상태의 행을 집어가면 안 된다. stop 은 drain 을 기다린다(stop_grace_period 15s).
  compose stop worker >/dev/null
  WORKER_STOPPED=1
  log "worker 정지"
fi

STEP=copy-in
# 덤프를 컨테이너 안으로 보낸다(stdin). 보낸 뒤 양쪽 sha256 이 같아야 진행한다.
TMP_IN_CONTAINER="/tmp/restore-$TS-$DUMP_NAME"
pg_sh 'cat > "$1"' "$TMP_IN_CONTAINER" < "$DUMP"
SHA_C="$(pg_sh 'sha256sum "$1" | cut -d " " -f1' "$TMP_IN_CONTAINER")"
SHA_H="$(sha256sum "$DUMP" | cut -d ' ' -f1)"
[ "$SHA_C" = "$SHA_H" ] || die "컨테이너로 복사 중 손상 (호스트 $SHA_H != 컨테이너 $SHA_C)"

STEP=pre-restore-dump
# 대상 DB 가 이미 있으면 덮어쓰기 전에 그대로 한 번 떠 둔다. 복구가 잘못됐을 때 되돌리는 용도.
EXISTS="$(pg_query postgres "SELECT 1 FROM pg_database WHERE datname = '$TARGET'")"
if [ "$EXISTS" = 1 ]; then
  PRE="/tmp/$TARGET-pre-restore-$TS.dump"
  pg_sh 'pg_dump -U "$POSTGRES_USER" -d "$1" -Fc --lock-wait-timeout=30000 -f "$2"' "$TARGET" "$PRE"
  mkdir -p "$BACKUP_DIR"
  copy_out_dump "$PRE" "$BACKUP_DIR/$TARGET-pre-restore-$TS.dump"
  pg_sh 'rm -f "$1"' "$PRE"
  log "pre-restore dump: $BACKUP_DIR/$TARGET-pre-restore-$TS.dump"
else
  STEP=createdb
  pg_sh 'createdb -U "$POSTGRES_USER" "$1"' "$TARGET"
  log "createdb $TARGET (없어서 새로 만듦)"
fi

STEP=pg_restore
t0=$(now_ms)
#   --clean        : 만들기 전에 같은 이름의 객체를 DROP 한다. 이미 있는 DB 위에 덮어쓸 때 필요
#   --if-exists    : DROP 에 IF EXISTS 를 붙인다. 빈 DB(방금 createdb)에서 "없는 객체 DROP" 오류가 나지 않는다
#   --no-owner     : 덤프에 적힌 소유자(booking)를 강제하지 않는다. 다른 환경의 다른 역할 이름으로도 복구된다
#   --single-transaction : 전체를 한 트랜잭션으로. 중간에 실패하면 전부 롤백돼 "반쯤 복구된 DB" 가 남지 않는다
#                          (오류 하나라도 나면 바로 중단하는 --exit-on-error 를 포함한다)
pg_sh 'pg_restore -U "$POSTGRES_USER" -d "$1" --clean --if-exists --no-owner --single-transaction "$2"' \
  "$TARGET" "$TMP_IN_CONTAINER"
RESTORE_MS=$(( $(now_ms) - t0 ))
log "pg_restore 완료: ${RESTORE_MS}ms"

# ---------- 검증 ----------
STEP=verify
VERIFY_RC=0
ROWS="$(pg_row_counts "$TARGET")"
MIGS="$(pg_migrations "$TARGET")"
EXP_ROWS=""; EXP_MIGS=""
if [ "$HAS_MANIFEST" = yes ]; then
  # manifest 는 backup.sh 가 만든 고정 형식이라 sed/grep 로 충분하다. jq 를 서버에 깔지 않아도 된다.
  EXP_ROWS="$(sed -n 's/.*"row_counts": {\([^}]*\)}.*/\1/p' "$MANIFEST")"
  EXP_MIGS="$(sed -n 's/.*"schema_migrations": \[\([^]]*\)\].*/\1/p' "$MANIFEST" | tr -d '" ')"
fi
printf '%-24s %10s %10s  %s\n' TABLE RESTORED MANIFEST RESULT >&2
while IFS=$'\t' read -r t n; do
  [ -n "$t" ] || continue
  if [ "$HAS_MANIFEST" = yes ]; then
    exp="$(printf '%s' "$EXP_ROWS" | grep -o "\"$t\": [0-9]*" | grep -o '[0-9]*$' || true)"
    if [ -z "$exp" ]; then res="manifest에 없음"; VERIFY_RC=3
    elif [ "$exp" = "$n" ]; then res=OK
    else res=MISMATCH; VERIFY_RC=3; fi
  else
    exp="-"; res="(manifest 없음)"
  fi
  printf '%-24s %10s %10s  %s\n' "$t" "$n" "$exp" "$res" >&2
done <<< "$ROWS"
# manifest 에는 있는데 복구 결과에 없는 테이블
if [ "$HAS_MANIFEST" = yes ]; then
  for t in $(printf '%s' "$EXP_ROWS" | grep -o '"[a-z0-9_]*":' | tr -d '":'); do
    printf '%s\n' "$ROWS" | grep -q "^$t"$'\t' || { printf '%-24s %10s %10s  %s\n' "$t" "-" "?" "복구 결과에 없음" >&2; VERIFY_RC=3; }
  done
fi
log "schema_migrations: restored=[$MIGS] manifest=[${EXP_MIGS:--}]"
if [ "$HAS_MANIFEST" = yes ] && [ "$MIGS" != "$EXP_MIGS" ]; then VERIFY_RC=3; fi

STEP=finish
TOTAL_MS=$(( $(now_ms) - T_TOTAL0 ))
if [ "$VERIFY_RC" = 0 ]; then
  log "VERIFY OK"
else
  log "VERIFY MISMATCH — 복구는 끝났지만 manifest 와 다르다 (운영 DB 는 덤프 이후 쓰기가 있었을 수 있다)"
fi
log "RTO evidence: restore_ms=$RESTORE_MS total_ms=$TOTAL_MS source=$DUMP_NAME target=$TARGET"
exit "$VERIFY_RC"
