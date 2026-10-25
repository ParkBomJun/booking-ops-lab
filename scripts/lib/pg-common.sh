#!/usr/bin/env bash
# scripts/lib/pg-common.sh — backup.sh 와 restore.sh 가 함께 쓰는 조각.
# 직접 실행하지 않는다. 각 스크립트가 `source` 로 불러온다.
# 이 파일은 set -e 같은 셸 옵션을 바꾸지 않는다. 옵션은 불러온 스크립트가 정한다.
# shellcheck shell=bash disable=SC2016  # pg_sh 의 작은따옴표 조각은 컨테이너 셸이 푼다. 의도된 것

# ---------- 로그 ----------
# 메시지는 전부 stderr 로 보낸다. stdout 은 "값을 돌려주는" 자리로 비워 둔다.
# 그래야 DB=$(pg_live_db) 같은 명령 치환에 로그가 섞여 들어가지 않는다.
# TAG 는 불러온 스크립트가 정한다(backup / restore). cron 메일에서 한 줄만 봐도 어느 스크립트인지 안다.
log() { printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "${TAG:-pg}" "$*" >&2; }
# die: 한 줄 이유를 찍고 1 로 끝낸다. "FAIL:" 접두어는 cron 메일·알림에서 grep 하기 위한 고정 문자열.
die() { printf '[%s] %s: FAIL: %s\n' "$(date -u +%FT%TZ)" "${TAG:-pg}" "$*" >&2; exit 1; }

# 밀리초 단위 현재 시각. 소요 시간(RTO 증거) 측정용. 호스트에서만 호출한다.
# bash 5 의 내장 변수 EPOCHREALTIME("초.마이크로초")을 쓴다. date 구현에 기대지 않는다:
# GNU date 는 %3N 을 지원하지만 uutils(Ubuntu 25.10 의 기본 coreutils)는 무시하고 나노초 9자리를 찍어 값이 100만 배 틀어졌다.
# 소수점 문자는 로케일에 따라 '.' 또는 ',' 이므로 숫자만 남긴다. bash 4 이하면 date +%s%N 으로 대신한다.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local us="${EPOCHREALTIME//[^0-9]/}"
    printf '%s\n' $(( us / 1000 ))
  else
    printf '%s\n' $(( $(date +%s%N) / 1000000 ))
  fi
}

# ---------- docker 선택 ----------
# 우선순위: 1) 환경변수 DOCKER  2) 데몬에 실제로 붙는 docker  3) docker.exe
# 3) 은 WSL 에서 Docker Desktop 의 WSL 통합이 꺼져 있을 때를 위한 대비. 서버(VM)에서는 2) 로 끝난다.
pick_docker() {
  if [ -n "${DOCKER:-}" ]; then
    log "docker: $DOCKER (DOCKER 환경변수)"
    return
  fi
  # `docker version` 은 데몬까지 왕복한다. 바이너리만 있고 데몬에 못 붙는 경우를 걸러낸다.
  if command -v docker >/dev/null 2>&1 && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    DOCKER=docker
  elif command -v docker.exe >/dev/null 2>&1; then
    DOCKER=docker.exe
  else
    die "docker 를 찾을 수 없다 (docker / docker.exe 모두 없음). DOCKER=<명령> 으로 지정할 수 있다"
  fi
  log "docker: $DOCKER"
}

# compose 하위 명령 래퍼. 호출한 쪽이 미리 리포지토리 루트로 cd 해 두어야 docker-compose.yml 을 찾는다.
compose() { "$DOCKER" compose "$@"; }

# pg_sh '<셸 조각>' [인자...]
# postgres 컨테이너 안에서 sh -c 로 실행한다.
#   -T : TTY 를 붙이지 않는다. 덤프(바이너리)를 stdin/stdout 으로 그대로 흘려보내려면 필수.
#   인자는 컨테이너 셸의 $1, $2 로 들어간다. 문자열을 이어 붙여 명령을 만들지 않으므로
#   DB 이름에 따옴표나 공백이 섞여도 명령이 깨지거나 엉뚱한 명령이 실행되지 않는다.
# 컨테이너 안에서는 로컬 소켓 + trust 인증이라 비밀번호가 필요 없다. 호스트 스크립트는 .env 를 읽지 않는다.
pg_sh() {
  local script="$1"
  shift
  compose exec -T "${PG_SERVICE:-postgres}" sh -c "$script" sh "$@"
}

# 운영 DB 이름. compose 가 컨테이너에 넣어 준 POSTGRES_DB 를 그대로 읽는다.
pg_live_db() { pg_sh 'printf %s "$POSTGRES_DB"'; }

# DB 이름 검증: 소문자로 시작, 소문자·숫자·밑줄만, 최대 63자(PostgreSQL 식별자 한도).
# 이 검사를 통과한 이름만 SQL 문자열에 끼워 넣는다.
valid_dbname() { [[ "$1" =~ ^[a-z][a-z0-9_]{0,62}$ ]]; }

# pg_query <db> <SQL> : 결과를 "값만, 줄 단위" 로 돌려준다.
#   -X 는 ~/.psqlrc 무시, -q 는 조용히, -A 는 정렬 없음, -t 는 헤더·행수 생략, ON_ERROR_STOP 은 오류 시 종료 코드 1.
pg_query() { pg_sh 'psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1" -c "$2"' "$1" "$2"; }

# SQL 은 호스트 쪽 bash 변수로 적어 인자로 넘긴다. 컨테이너 셸 조각(작은따옴표 안)에 작은따옴표를 쓰지 않기 위해서다.
SQL_TABLES="SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"
SQL_HAS_MIGRATIONS="SELECT to_regclass('public.schema_migrations') IS NOT NULL"
SQL_MIGRATIONS="SELECT coalesce(string_agg(version, ',' ORDER BY version), '') FROM schema_migrations"

# pg_row_counts <db> : public 스키마의 일반 테이블마다 정확한 행 수. 출력 "테이블<TAB>행수".
# 통계 추정치(pg_class.reltuples)가 아니라 count(*) 를 쓴다. 복구 검증에는 정확한 값이 필요하고, 이 규모(수천 행)에선 ms 단위다.
pg_row_counts() {
  pg_sh '
    db="$1"; sql="$2"
    psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -c "$sql" |
      while IFS= read -r t; do
        n=$(psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -c "SELECT count(*) FROM public.\"$t\"")
        printf "%s\t%s\n" "$t" "$n"
      done
  ' "$1" "$SQL_TABLES"
}

# pg_migrations <db> : "001_create_bookings,002_worker_columns" 형태. 테이블이 없으면 빈 문자열.
pg_migrations() {
  if [ "$(pg_query "$1" "$SQL_HAS_MIGRATIONS")" = "t" ]; then
    pg_query "$1" "$SQL_MIGRATIONS"
  else
    printf ''
  fi
}

# copy_out_dump <컨테이너 경로> <호스트 경로>
# 컨테이너 안의 파일을 호스트로 흘려보낸 뒤 양쪽 sha256 을 비교한다. 다르면 실패.
# 덤프는 컨테이너 안에서 먼저 파일로 만들고(그 시점의 해시가 "원본"), 전송 후 호스트에서 다시 재서 맞춘다.
# docker.exe(WSL) 경로나 네트워크 문제로 바이트가 깨지는 경우를 여기서 잡는다. .part 로 받았다가 검증 후 제 이름으로 바꾼다.
copy_out_dump() {
  local src="$1" dst="$2" sha_c sha_h
  sha_c=$(pg_sh 'sha256sum "$1" | cut -d " " -f1' "$src")
  pg_sh 'cat "$1"' "$src" > "$dst.part"
  sha_h=$(sha256sum "$dst.part" | cut -d ' ' -f1)
  if [ "$sha_c" != "$sha_h" ]; then
    rm -f "$dst.part"
    die "전송 중 손상: 컨테이너 sha256=$sha_c 호스트 sha256=$sha_h ($src)"
  fi
  mv "$dst.part" "$dst"
  # sha256sum -c 가 읽을 수 있는 형식("해시  파일명")으로 옆에 남긴다.
  printf '%s  %s\n' "$sha_h" "$(basename "$dst")" > "$dst.sha256"
}
