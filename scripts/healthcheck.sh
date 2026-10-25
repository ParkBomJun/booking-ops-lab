#!/usr/bin/env bash
# healthcheck.sh — 스택 전체 상태를 한 표로 출력한다. 로컬(WSL + docker.exe)과 VM 에서 같은 스크립트를 쓴다.
#
# 사용법:  scripts/healthcheck.sh            (cron 은 매시간, 출력은 로그 파일로)
# 종료 코드: 0 = CRIT 없음(WARN 은 허용), 1 = CRIT 하나 이상.
# 점검 항목: 컨테이너 상태 / 각 /healthz / Prometheus 타깃 / firing 알림 / 디스크 / 시간 동기화 /
#            호스트-컨테이너 시계 오차(5시간 40분 어긋났던 사건의 재발 감지) / 마지막 백업 나이 / 배포된 태그
# 필요한 것: bash, curl, python3(JSON 파싱). docker 는 있으면 쓰고 없으면 그 항목만 건너뛴다.

set -uo pipefail   # -e 는 일부러 뺀다: 점검 하나가 실패해도 나머지 점검은 계속해야 한다.
export TZ=UTC

# ---------- 설정. 전부 환경변수로 덮어쓸 수 있다 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
BASE_URL="${BASE_URL:-http://127.0.0.1}"   # 로컬은 0.0.0.0, VM 은 127.0.0.1 바인딩 — 어느 쪽이든 이 주소로 닿는다
PROM_URL="${PROM_URL:-$BASE_URL:9090}"
EXPECTED_CONTAINERS="${EXPECTED_CONTAINERS:-booking-postgres booking-api mock-forwarder booking-worker booking-prometheus booking-alertmanager booking-grafana}"
HEALTHZ="${HEALTHZ:-booking-api:8080 worker:8081 mock-forwarder:8082}"
DISK_WARN="${DISK_WARN:-80}"               # 알림 규칙 DiskUsageHigh 와 같은 80%
DISK_CRIT="${DISK_CRIT:-90}"
CLOCK_WARN_SEC="${CLOCK_WARN_SEC:-5}"
CLOCK_CRIT_SEC="${CLOCK_CRIT_SEC:-60}"
BACKUP_WARN_HOURS="${BACKUP_WARN_HOURS:-26}"   # 매일 밤 백업이면 26시간 넘게 없는 건 이상
BACKUP_DIR="${BACKUP_DIR:-$REPO_DIR/backups}"
BACKUP_MARKER="${BACKUP_MARKER:-$BACKUP_DIR/LAST_SUCCESS}"   # backup.sh 가 성공 때 쓰는 파일. 1행 = 성공 시각(UTC ISO 8601)

# ---------- 결과 모으기 ----------
ROWS=()
CRIT=0
WARN=0
row() {  # row <OK|WARN|CRIT|INFO> <항목> <상세>
  case "$1" in CRIT) CRIT=$(( CRIT + 1 )) ;; WARN) WARN=$(( WARN + 1 )) ;; esac
  ROWS+=("$(printf '%-4s  %-22s %s' "$1" "$2" "$3")")
}
fetch() { curl -s -m 5 "$@"; }          # 5초 안에 답 없으면 "없음" 으로 본다
py() { python3 -I -c "$1"; }            # stdin 의 JSON 을 파싱해 한 줄로 낸다. -I: 현재 디렉터리의 .py 를 모듈로 집지 않음

# docker 명령 고르기: 환경변수 > docker(데몬 연결 가능) > docker.exe(WSL 에서 Docker Desktop 직접 호출) > 없음
DOCKER=""
if [[ -n "${DOCKER_BIN:-}" ]]; then DOCKER="$DOCKER_BIN"
elif docker info >/dev/null 2>&1; then DOCKER="docker"
elif command -v docker.exe >/dev/null 2>&1 && docker.exe info >/dev/null 2>&1; then DOCKER="docker.exe"
fi
dk() { "$DOCKER" "$@" 2>/dev/null | tr -d '\r'; }   # docker.exe 는 Windows 줄끝(\r)을 낼 수 있어 제거

# ---------- 점검 ----------
check_containers() {
  if [[ -z "$DOCKER" ]]; then row WARN containers "docker 명령을 쓸 수 없어 건너뜀"; return; fi
  local ps
  if ! ps="$(dk ps -a --format '{{.Names}} {{.State}}')"; then row CRIT containers "docker ps 실패"; return; fi
  local -a expected missing=() notrun=()
  read -r -a expected <<< "$EXPECTED_CONTAINERS"
  local c state running=0
  for c in "${expected[@]}"; do
    state="$(awk -v n="$c" '$1 == n {print $2}' <<< "$ps")"
    if [[ -z "$state" ]]; then missing+=("$c")
    elif [[ "$state" != "running" ]]; then notrun+=("$c=$state")
    else running=$(( running + 1 )); fi
  done
  # 재시작 횟수 > 0 인 컨테이너. 크래시 루프(훈련 4번) 의 흔적.
  local restarts
  restarts="$(dk inspect --format '{{.Name}}={{.RestartCount}}' "${expected[@]}" | awk -F= '$2 > 0 {sub("^/", "", $1); printf "%s(%s) ", $1, $2}')"
  local detail="${running}/${#expected[@]} running"
  if (( ${#missing[@]} > 0 )); then detail+="; missing: ${missing[*]}"; fi
  if (( ${#notrun[@]} > 0 )); then detail+="; not running: ${notrun[*]}"; fi
  if [[ -n "$restarts" ]]; then detail+="; restarts: ${restarts% }"; fi
  if (( ${#missing[@]} > 0 || ${#notrun[@]} > 0 )); then row CRIT containers "$detail"
  elif [[ -n "$restarts" ]]; then row WARN containers "$detail"
  else row OK containers "$detail"; fi
}

check_healthz() {
  local -a pairs; read -r -a pairs <<< "$HEALTHZ"
  local pair name port out code body
  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"; port="${pair##*:}"
    # 본문 뒤에 줄바꿈 + 상태 코드를 붙여 받는다. 연결 실패면 코드는 000.
    out="$(fetch -w '\n%{http_code}' "$BASE_URL:$port/healthz" 2>/dev/null)" || true
    code="${out##*$'\n'}"; body="${out%$'\n'*}"
    if ! [[ "$code" =~ ^[0-9]{3}$ ]]; then code="000"; body=""; fi
    if [[ "$code" == "200" ]]; then row OK "healthz $name" "200 $body"
    else row CRIT "healthz $name" "HTTP $code ${body:-(no response)}"; fi
  done
}

check_targets() {
  local json out
  if ! json="$(fetch "$PROM_URL/api/v1/targets")"; then row CRIT "prometheus targets" "Prometheus 응답 없음 ($PROM_URL)"; return; fi
  if ! out="$(py '
import sys, json
t = json.load(sys.stdin)["data"]["activeTargets"]
up = sum(1 for x in t if x["health"] == "up")
down = [x["labels"].get("job", "?") for x in t if x["health"] != "up"]
print(up, len(t), ",".join(down) or "-")
' <<< "$json")"; then row CRIT "prometheus targets" "응답 파싱 실패"; return; fi
  local up total down; read -r up total down <<< "$out"
  if (( up == total )); then row OK "prometheus targets" "$up/$total up"
  else row CRIT "prometheus targets" "$up/$total up; down: $down"; fi
}

check_alerts() {
  local json out
  if ! json="$(fetch "$PROM_URL/api/v1/alerts")"; then row WARN "alerts firing" "Prometheus 응답 없음"; return; fi
  if ! out="$(py '
import sys, json, collections
a = json.load(sys.stdin)["data"]["alerts"]
firing = [x for x in a if x["state"] == "firing"]
by = collections.Counter(x["labels"].get("severity", "none") for x in firing)
pending = sum(1 for x in a if x["state"] == "pending")
names = ",".join(sorted({x["labels"].get("alertname", "?") for x in firing})) or "-"
print(by.get("critical", 0), by.get("warning", 0), by.get("info", 0), pending, names)
' <<< "$json")"; then row WARN "alerts firing" "응답 파싱 실패"; return; fi
  local c w i p names; read -r c w i p names <<< "$out"
  local detail="critical=$c warning=$w info=$i pending=$p"
  if [[ "$names" != "-" ]]; then detail+=" [$names]"; fi
  if (( c > 0 )); then row CRIT "alerts firing" "$detail"
  elif (( w > 0 )); then row WARN "alerts firing" "$detail"
  else row OK "alerts firing" "$detail"; fi
}

check_disk() {
  local use ddf=""
  use="$(df -P / | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
  if [[ -n "$DOCKER" ]]; then ddf="$(dk system df --format '{{.Type}}={{.Size}}' | tr '\n' ' ')"; fi
  local detail="/ ${use}% used; docker: ${ddf:-n/a}"
  if (( use >= DISK_CRIT )); then row CRIT disk "$detail"
  elif (( use >= DISK_WARN )); then row WARN disk "$detail"
  else row OK disk "$detail"; fi
}

check_timesync() {
  local out leap off
  # chrony(VM) 가 먼저, 없거나 데몬이 안 돌면 systemd-timesyncd(timedatectl), 둘 다 없으면 WARN.
  if command -v chronyc >/dev/null 2>&1 && out="$(chronyc tracking 2>/dev/null)"; then
    leap="$(awk -F': *' '/^Leap status/ {print $2}' <<< "$out")"
    off="$(awk -F': *' '/^System time/ {print $2}' <<< "$out")"
    if [[ "$leap" == "Normal" ]]; then row OK "time sync (chrony)" "$off"
    else row WARN "time sync (chrony)" "leap=$leap; $off"; fi
  elif command -v timedatectl >/dev/null 2>&1 && out="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"; then
    if [[ "$out" == "yes" ]]; then row OK "time sync (systemd)" "NTPSynchronized=yes"
    else row WARN "time sync (systemd)" "NTPSynchronized=$out"; fi
  else
    row WARN "time sync" "chronyc/timedatectl 없음 — 확인 불가"
  fi
}

check_clock_offset() {
  # 컨테이너 쪽 시계를 Prometheus 의 time() 질의로 읽는다 (= Prometheus 프로세스의 현재 시각). docker exec 가 필요 없다.
  # 2026-10-18 에 Docker VM 시계가 호스트보다 5시간 40분 느려 그래프가 비어 보였다. 그 재발을 여기서 잡는다.
  local off="" src="" json ct
  if json="$(fetch "$PROM_URL/api/v1/query?query=time()")"; then
    off="$(py '
import sys, json, time
v = float(json.load(sys.stdin)["data"]["result"][1]); print(round(v - time.time(), 1))
' <<< "$json" 2>/dev/null)" || off=""
    src="prometheus time()"
  fi
  if [[ -z "$off" && -n "$DOCKER" ]]; then   # Prometheus 가 죽었으면 postgres 컨테이너(셸 있음)의 date 로 대체
    ct="$(dk exec booking-postgres date -u +%s)"
    if [[ "$ct" =~ ^[0-9]+$ ]]; then off=$(( ct - $(date -u +%s) )); src="postgres date"; fi
  fi
  if [[ -z "$off" ]]; then row WARN "container clock" "측정 불가 (Prometheus·docker 모두 응답 없음)"; return; fi
  local abs="${off#-}"; abs="${abs%.*}"
  if (( abs >= CLOCK_CRIT_SEC )); then row CRIT "container clock" "offset ${off}s vs host ($src) — 그래프·알림 시각이 어긋난다"
  elif (( abs >= CLOCK_WARN_SEC )); then row WARN "container clock" "offset ${off}s vs host ($src)"
  else row OK "container clock" "offset ${off}s vs host ($src)"; fi
}

check_backup() {
  # 기준은 backup.sh 가 성공 끝에 쓰는 LAST_SUCCESS 의 1행(시각). 파일 mtime 이 아니라 적힌 시각을 읽는다 — 복사·복구로 mtime 이 바뀌어도 속지 않는다.
  local ts="" when="" age_h newest
  if [[ -f "$BACKUP_MARKER" ]]; then
    ts="$(head -n 1 "$BACKUP_MARKER")"
    if ! when="$(date -d "$ts" +%s 2>/dev/null)"; then row WARN "last backup" "LAST_SUCCESS 1행을 시각으로 읽지 못함: '$ts'"; return; fi
  elif [[ -d "$BACKUP_DIR" ]]; then   # 마커가 없으면 가장 새 덤프 파일의 mtime 으로 대신한다
    newest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)"
    if [[ -n "$newest" ]]; then when="$(stat -c %Y "$newest")"; ts="mtime of $(basename "$newest")"; fi
  fi
  if [[ -z "$when" ]]; then row INFO "last backup" "기록 없음 — backup.sh 가 아직 안 돌았다 ($BACKUP_MARKER)"; return; fi
  age_h=$(( ( $(date +%s) - when ) / 3600 ))
  if (( age_h > BACKUP_WARN_HOURS )); then row WARN "last backup" "${age_h}h ago ($ts)"
  else row OK "last backup" "${age_h}h ago ($ts)"; fi
}

check_deploy_tag() {
  if [[ -f "$REPO_DIR/.deploy/current_tag" ]]; then row INFO "deployed tag" "$(<"$REPO_DIR/.deploy/current_tag")"
  else row INFO "deployed tag" "없음 (로컬 빌드 또는 첫 배포 전)"; fi
}

# ---------- 출력 ----------
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then echo "healthcheck.sh: python3 가 필요합니다 (JSON 파싱)" >&2; exit 1; fi
  check_containers
  check_healthz
  check_targets
  check_alerts
  check_disk
  check_timesync
  check_clock_offset
  check_backup
  check_deploy_tag

  printf 'booking-ops-lab healthcheck  %(%Y-%m-%dT%H:%M:%SZ)T  host=%s  docker=%s\n' -1 "$(hostname)" "${DOCKER:-none}"
  printf '%-4s  %-22s %s\n' STAT CHECK DETAIL
  printf '%s\n' "${ROWS[@]}"
  local verdict="OK"
  if (( WARN > 0 )); then verdict="WARN"; fi
  if (( CRIT > 0 )); then verdict="CRIT"; fi
  printf 'RESULT: %s (crit=%d warn=%d)\n' "$verdict" "$CRIT" "$WARN"
  (( CRIT == 0 ))
}

main "$@"
