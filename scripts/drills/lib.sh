#!/usr/bin/env bash
# 장애 훈련 공통 함수. 각 훈련 스크립트가 `source "$SCRIPT_DIR/lib.sh"` 로 불러 쓴다. 직접 실행하는 파일이 아니다.
#
# 전제
# - 스택이 docker compose 로 떠 있고, 호스트에서 booking-api :8080 / Prometheus :9090 / Alertmanager :9093 에 닿는다.
# - 호스트에 curl, python3 가 있다. JSON 은 python3 표준 라이브러리로만 다룬다 (jq 불필요).
# - WSL + Docker Desktop(통합 꺼짐) 환경에서는 `docker` 가 없고 `docker.exe` 만 있다. 그 경로에 공백이 있으므로
#   ("/mnt/c/Program Files/...") 항상 dk 래퍼로 따옴표를 쳐서 부른다. 서버(리눅스)에서는 docker 로 자동 대체.
# - docker.exe 는 Windows 프로세스라 WSL 셸 환경변수를 못 본다. 설정 덮어쓰기는 반드시 `--env-file` 로 한다.

PROM_URL=${PROM_URL:-http://localhost:9090}
AM_URL=${AM_URL:-http://localhost:9093}
API_URL=${API_URL:-http://localhost:8080}
DOCKER=${DOCKER:-$(command -v docker.exe || echo docker)}

# dk: docker 호출 래퍼. "$DOCKER" 에 공백이 있어도 안전.
dk() { "$DOCKER" "$@"; }

# 시각. 문서(포스트모템 타임라인)가 KST 기준이라 화면 출력도 KST.
kst_now() { TZ=Asia/Seoul date '+%H:%M:%S'; }
epoch_now() { date +%s; }

# log: 타임스탬프를 붙여 화면에만 출력.
log() { printf '[%s KST] %s\n' "$(kst_now)" "$*"; }

# mark: 화면 + 타임라인 파일(TIMELINE_FILE: epoch<TAB>KST<TAB>내용). 포스트모템 표로 옮길 "사건" 만 mark 로 남긴다.
mark() {
  log "$*"
  if [[ -n "${TIMELINE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$(epoch_now)" "$(kst_now)" "$*" >> "$TIMELINE_FILE"
  fi
}

# prom_query <expr>: 즉시 질의. 한 줄 JSON 배열 [[labels, value], ...]. 결과 없으면 [].
prom_query() {
  curl -sS -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(json.dumps([[r["metric"], r["value"][1]] for r in d.get("data", {}).get("result", [])], ensure_ascii=False))'
}

# prom_scalar <expr>: 첫 결과의 값만. 결과 없으면 빈 문자열 (호출 쪽에서 ${x:-0} 처럼 기본값을 준다).
prom_scalar() {
  curl -sS -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | python3 -c '
import sys, json
r = json.load(sys.stdin).get("data", {}).get("result", [])
print(r[0]["value"][1] if r else "")'
}

# prom_range <expr> <start_epoch> <end_epoch> <step_sec>: 구간 질의 원본 JSON (증거 파일 저장용).
prom_range() {
  curl -sS -G "$PROM_URL/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode "step=$4"
}

# alert_state <alertname>: Prometheus 의 ALERTS 기준 상태. "firing" / "pending" / "" (비활성).
alert_state() {
  prom_query "ALERTS{alertname=\"$1\"}" | python3 -c '
import sys, json
s = {m.get("alertstate") for m, _ in json.load(sys.stdin)}
print("firing" if "firing" in s else ("pending" if "pending" in s else ""))'
}

# am_alerts: Alertmanager 가 들고 있는 알림. 한 줄에 하나: alertname severity state inhibitedBy startsAt
am_alerts() {
  curl -sS "$AM_URL/api/v2/alerts" | python3 -c '
import sys, json
rows = json.load(sys.stdin)
if not rows:
    print("(없음)")
for a in rows:
    st = a["status"]; ib = st.get("inhibitedBy", [])
    print(a["labels"].get("alertname"), a["labels"].get("severity"), st["state"],
          "inhibitedBy=" + (",".join(ib) if ib else "-"), a["startsAt"])'
}

# Discord 발송 증거는 로그가 아니라 Alertmanager 자체 카운터로 본다 (성공은 INFO 로그에 안 남는다).
discord_sent_total()   { prom_scalar 'sum(alertmanager_notifications_total{integration="discord"})'; }
discord_failed_total() { prom_scalar 'sum(alertmanager_notifications_failed_total{integration="discord"})'; }

# post_booking <idempotency_key> <text>: POST /bookings.
# 출력 한 줄: http_code<TAB>status<TAB>review_reason<TAB>elapsed_ms. 연결 실패면 000.
# text 에는 큰따옴표·백슬래시를 넣지 않는다 (JSON 을 printf 로 만든다).
post_booking() {
  local key=$1 text=$2 start end raw code body parsed
  start=$(date +%s%N)   # 나노초. 이 date 는 %3N 을 자르지 않아 나노초로 받고 ms 로 나눈다
  raw=$(curl -sS -w '\n%{http_code}' -X POST "$API_URL/bookings" \
          -H 'Content-Type: application/json' -H "Idempotency-Key: $key" \
          --data "$(printf '{"text":"%s"}' "$text")") || { printf '000\t?\t?\t0\n'; return 0; }
  end=$(date +%s%N)
  code=${raw##*$'\n'}
  body=${raw%$'\n'*}
  parsed=$(printf '%s' "$body" | python3 -c '
import sys, json
try:
    b = json.load(sys.stdin); print(str(b.get("status", "?")) + "\t" + str(b.get("review_reason", "-")))
except Exception:
    print("?\t?")')
  printf '%s\t%s\t%s\n' "$code" "$parsed" "$(( (end - start) / 1000000 ))"
}

# wait_for_alert <alertname> <pending|firing|resolved> <timeout_sec>: 5초 간격 대기. 성공 0, 시간 초과 1.
# resolved = Prometheus ALERTS 에서 사라짐. pending 을 기다릴 때는 firing 도 통과로 본다.
wait_for_alert() {
  local name=$1 want=$2 timeout=$3 deadline state
  deadline=$(( $(epoch_now) + timeout ))
  while (( $(epoch_now) < deadline )); do
    state=$(alert_state "$name")
    case "$want" in
      pending)  if [[ $state == pending || $state == firing ]]; then return 0; fi ;;
      firing)   if [[ $state == firing ]]; then return 0; fi ;;
      resolved) if [[ -z $state ]]; then return 0; fi ;;
    esac
    sleep 5
  done
  return 1
}

# container_env <container> <VAR>: 환경변수 하나만 꺼낸다. 전체를 찍으면 API 키·DB 비밀번호가 같이 나온다.
container_env() {
  dk inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$2=" | head -1 | cut -d= -f2-
}

# compose_env_value <VAR> [env-file...]: compose 가 병합한 뒤 booking-api 에 실제로 줄 값. 전체 출력은 비밀값을 담으므로 grep 만 남긴다.
compose_env_value() {
  local var=$1; shift
  local args=()
  local f; for f in "$@"; do args+=(--env-file "$f"); done
  dk compose "${args[@]}" config 2>/dev/null | grep -E "^\s+$var:" | head -1 | tr -d ' "' | cut -d: -f2
}

# 스택 7개 컨테이너 중 running 인 수.
STACK_CONTAINERS="booking-postgres booking-api booking-worker mock-forwarder booking-prometheus booking-alertmanager booking-grafana"
stack_running_count() {
  local n=0 c running
  running=$(dk ps --filter status=running --format '{{.Names}}')
  for c in $STACK_CONTAINERS; do
    if grep -qx "$c" <<<"$running"; then n=$((n + 1)); fi
  done
  echo "$n"
}

# wait_healthz <url> <timeout_sec>: 200 이 올 때까지 2초 간격.
wait_healthz() {
  local deadline=$(( $(epoch_now) + $2 ))
  while (( $(epoch_now) < deadline )); do
    if curl -sf -o /dev/null "$1"; then return 0; fi
    sleep 2
  done
  return 1
}

# clock_offset_sec: Prometheus 컨테이너 시계 - 호스트 시계 (초). Docker VM 시계가 몇 시간 뒤처진 적이 있어 훈련마다 먼저 찍는다.
clock_offset_sec() {
  local h c
  h=$(date -u +%s); c=$(dk exec booking-prometheus date -u +%s)
  echo $(( c - h ))
}

# snapshot <label> <outfile>: 핵심 지표·알림·발송 카운터를 JSON 한 파일로. 훈련 전/중/후 비교용.
# 라벨은 구분에 필요한 것만 남긴다 (instance/env 등은 전부 같아서 생략).
snapshot() {
  python3 - "$1" "$2" "$PROM_URL" "$AM_URL" <<'PY'
import json, sys, time, urllib.request, urllib.parse
label, out, prom, am = sys.argv[1:5]
KEEP = {"result", "status", "alertname", "alertstate", "severity", "reason", "integration", "job", "service"}
def q(expr):
    u = prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    res = json.load(urllib.request.urlopen(u, timeout=10))["data"]["result"]
    return [[{k: v for k, v in r["metric"].items() if k in KEEP}, r["value"][1]] for r in res]
snap = {
    "label": label,
    "epoch": int(time.time()),
    "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "processed_total": q("booking_processed_total"),
    "claude_requests_total": q("booking_claude_requests_total"),
    "needs_review_count": q("booking_needs_review_count"),
    "status_count": q("booking_status_count"),
    "needs_review_ratio_5m": q('sum(rate(booking_processed_total{result="needs_review"}[5m])) / sum(rate(booking_processed_total{result=~"parsed|needs_review"}[5m]))'),
    "alerts_prometheus": q("ALERTS"),
    "discord_notifications_total": q('alertmanager_notifications_total{integration="discord"}'),
    "discord_notifications_failed_total": q('sum(alertmanager_notifications_failed_total{integration="discord"})'),
    "up": q("up"),
}
try:
    snap["alerts_alertmanager"] = [[a["labels"].get("alertname"), a["status"]["state"], a["status"].get("inhibitedBy", []), a["startsAt"]]
                                  for a in json.load(urllib.request.urlopen(am + "/api/v2/alerts", timeout=10))]
except Exception as e:
    snap["alerts_alertmanager"] = "error: %s" % e
with open(out, "w") as f:
    json.dump(snap, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
print(out)
PY
}

# evidence_dump <dir> <start_epoch> <end_epoch>: 구간 질의 결과를 파일로 (15초 간격). 알림 타임라인·비율·타임아웃 카운터·발송 카운터.
evidence_dump() {
  local dir=$1 s=$2 e=$3
  mkdir -p "$dir"
  prom_range 'ALERTS' "$s" "$e" 15 > "$dir/alerts-range.json"
  prom_range 'ALERTS_FOR_STATE' "$s" "$e" 15 > "$dir/alerts-for-state-range.json"
  prom_range 'sum(rate(booking_processed_total{result="needs_review"}[5m])) / sum(rate(booking_processed_total{result=~"parsed|needs_review"}[5m]))' "$s" "$e" 15 > "$dir/needs-review-ratio-range.json"
  prom_range 'sum by (result) (increase(booking_claude_requests_total[1m]))' "$s" "$e" 15 > "$dir/claude-requests-1m-range.json"
  prom_range 'booking_needs_review_count' "$s" "$e" 15 > "$dir/needs-review-count-range.json"
  prom_range 'sum(alertmanager_notifications_total{integration="discord"})' "$s" "$e" 15 > "$dir/discord-notifications-range.json"
  curl -sS "$AM_URL/api/v2/alerts" > "$dir/alertmanager-alerts.json"
  echo "$dir"
}
