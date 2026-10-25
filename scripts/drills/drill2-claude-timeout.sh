#!/usr/bin/env bash
# 장애 훈련 2번: Claude API 타임아웃 → 검토 대기함 급증 → NeedsReviewRatioHigh(warning) → Discord
#
# 순서
#  0. 사전 점검: 시계 차이, 컨테이너 7개, compose 병합 확인, 기준선 스냅샷(baseline.json)
#  1. 주입: .env.drill2(CLAUDE_TIMEOUT_MS=1) 를 두 번째 env 파일로 얹어 booking-api 만 재생성.
#     1ms 면 TLS 도 못 맺고 끝나므로 Claude API 에 요청이 닿지 않는다 → 과금 0.
#  2. 트래픽: RATE_INTERVAL_SEC 마다 RATE_N 건 POST. 매 건 201 + status=needs_review + review_reason=claude_timeout 이어야 한다.
#     첫 건이 그렇지 않으면 "주입 안 됨" 으로 보고 즉시 중단한다 (trap 이 원복).
#  3. 관찰: 비율 식, ALERTS(pending→firing), Discord 발송 카운터. Discord 가 가면 트래픽을 멈춘다(STOP_ON_DISCORD=1).
#  4. 원복: 정상 .env 만으로 booking-api 재생성, CLAUDE_TIMEOUT_MS 가 compose 기본값으로 돌아왔는지 확인.
#  5. 회복 증명: 실제 Claude 호출 RECOVERY_REQUESTS 건(비용 발생, 최대 10) → status=parsed 확인.
#  6. 해제 대기: ALERTS 에서 사라질 때까지 최대 WAIT_RESOLVE_SEC. 그 뒤 resolved 메시지가 Discord 로 가는지 카운터로 확인.
#  7. 증거 저장(after.json, *-range.json, timeline.tsv, requests.tsv, summary.json) + 최종 점검.
#
# 어떤 경로로 끝나든(에러, Ctrl-C 포함) trap 이 booking-api 를 정상 .env 로 되돌린다.
#
# 매개변수 (환경변수로 덮어쓴다)
#   DURATION_SEC=720            주입 트래픽 최대 시간
#   RATE_N=3 RATE_INTERVAL_SEC=20   "20초마다 3건"
#   STOP_ON_DISCORD=1           Discord 발송이 확인되면 DURATION 전에 트래픽 중단
#   RECOVERY_REQUESTS=5         원복 후 실제 Claude 호출 건수 (0~10). 0 이면 생략
#   RECOVERY_INTERVAL_SEC=20
#   WAIT_RESOLVE_SEC=720        해제 대기 상한
#   WAIT_RESOLVED_NOTIFY_SEC=600  해제 후 Discord resolved 발송 대기 상한 (warning 라우트 group_interval 10m)
#   EVIDENCE_DIR=docs/postmortems/evidence/drill2   같은 이름 파일은 덮어쓴다. 보관하려면 다른 경로를 준다
#   DOCKER=docker.exe|docker    lib.sh 가 자동 선택
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DURATION_SEC=${DURATION_SEC:-720}
RATE_N=${RATE_N:-3}
RATE_INTERVAL_SEC=${RATE_INTERVAL_SEC:-20}
STOP_ON_DISCORD=${STOP_ON_DISCORD:-1}
RECOVERY_REQUESTS=${RECOVERY_REQUESTS:-5}
RECOVERY_INTERVAL_SEC=${RECOVERY_INTERVAL_SEC:-20}
WAIT_RESOLVE_SEC=${WAIT_RESOLVE_SEC:-720}
WAIT_RESOLVED_NOTIFY_SEC=${WAIT_RESOLVED_NOTIFY_SEC:-600}
EVIDENCE_DIR=${EVIDENCE_DIR:-$REPO_DIR/docs/postmortems/evidence/drill2}
ALERT=NeedsReviewRatioHigh
# 저장소 루트 기준 상대 경로. docker.exe 는 Windows 쪽에서 경로를 풀기 때문에 /home/... 절대 경로를 주면 못 찾는다.
ENV_OVERRIDE=.env.drill2
RATIO_EXPR='sum(rate(booking_processed_total{result="needs_review"}[5m])) / sum(rate(booking_processed_total{result=~"parsed|needs_review"}[5m]))'

if (( RECOVERY_REQUESTS > 10 )); then echo "RECOVERY_REQUESTS 는 10 이하 (실제 API 비용)"; exit 2; fi

cd "$REPO_DIR"   # compose 는 이 디렉터리(프로젝트 이름, .env, 상대 경로 env 파일) 기준으로 동작한다
mkdir -p "$EVIDENCE_DIR"
TIMELINE_FILE="$EVIDENCE_DIR/timeline.tsv"
REQ_FILE="$EVIDENCE_DIR/requests.tsv"
: > "$TIMELINE_FILE"
printf 'epoch\tkst\tphase\tkey\thttp\tstatus\treview_reason\telapsed_ms\n' > "$REQ_FILE"

# ---- 원복. 몇 번 불려도 안전해야 한다 (정상 경로에서 한 번, trap 에서 또 한 번) ----
INJECTED=0
RESTORED=0
restore() {
  if (( RESTORED )); then return 0; fi
  RESTORED=1
  mark "restore: docker compose --env-file .env up -d --no-deps booking-api"
  if ! dk compose --env-file .env up -d --no-deps booking-api; then
    echo "!! restore 실패. 수동으로: docker compose --env-file .env up -d booking-api"; return 1
  fi
  wait_healthz "$API_URL/healthz" 60 || echo "!! /healthz 가 60초 안에 안 돌아옴"
  local want got
  want=$(compose_env_value CLAUDE_TIMEOUT_MS .env)
  got=$(container_env booking-api CLAUDE_TIMEOUT_MS)
  mark "restore: 컨테이너 CLAUDE_TIMEOUT_MS=$got (compose 기본값 $want)"
  if [[ "$got" != "$want" ]]; then echo "!! 노브가 기본값으로 안 돌아왔다: got=$got want=$want"; return 1; fi
}
on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if (( INJECTED )) && (( ! RESTORED )); then echo "[drill2] 비정상 종료(rc=$rc) → 원복"; fi
  if (( INJECTED )); then restore || rc=1; fi
  echo "[drill2] 종료 rc=$rc. 컨테이너 running: $(stack_running_count)/7"
  exit "$rc"
}
trap on_exit EXIT INT TERM

# ---- 0. 사전 점검 ----
echo "== 장애 훈련 2번: Claude 타임아웃 → NeedsReviewRatioHigh =="
echo "repo=$REPO_DIR docker=$DOCKER evidence=$EVIDENCE_DIR"
[[ -f .env ]] || { echo "!! .env 가 없다"; exit 1; }
OFFSET=$(clock_offset_sec)
mark "preflight: 시계 차이 prometheus-host = ${OFFSET}s"
if (( OFFSET > 60 || OFFSET < -60 )); then echo "!! Docker VM 시계가 ${OFFSET}s 어긋남. 그래프는 시간 범위를 명시해 읽는다 (계속 진행)"; fi
N=$(stack_running_count)
mark "preflight: 컨테이너 running $N/7"
if (( N != 7 )); then echo "!! 7개가 전부 떠 있지 않다. 중단"; exit 1; fi
printf 'CLAUDE_TIMEOUT_MS=1\n' > "$ENV_OVERRIDE"   # 비밀값 없음. 매번 새로 써서 내용을 확실히 한다
MERGED=$(compose_env_value CLAUDE_TIMEOUT_MS .env "$ENV_OVERRIDE")
DEFAULT_TIMEOUT=$(compose_env_value CLAUDE_TIMEOUT_MS .env)
mark "preflight: compose 병합 CLAUDE_TIMEOUT_MS 주입값=$MERGED 기본값=$DEFAULT_TIMEOUT"
if [[ "$MERGED" != "1" ]]; then echo "!! 병합 결과가 1 이 아니다. env 파일 경로·줄바꿈 확인"; exit 1; fi

snapshot baseline "$EVIDENCE_DIR/baseline.json" >/dev/null
DISCORD0=$(discord_sent_total); DISCORD0=${DISCORD0:-0}
FAILED0=$(discord_failed_total); FAILED0=${FAILED0:-0}
NR0=$(prom_scalar 'booking_needs_review_count'); NR0=${NR0:-0}
STATE0=$(alert_state "$ALERT")
mark "baseline: discord_sent=$DISCORD0 discord_failed=$FAILED0 needs_review_count=$NR0 $ALERT=${STATE0:-none}"

# ---- 1. 주입 ----
mark "inject: docker compose --env-file .env --env-file $ENV_OVERRIDE up -d --no-deps booking-api"
INJECTED=1
dk compose --env-file .env --env-file "$ENV_OVERRIDE" up -d --no-deps booking-api
wait_healthz "$API_URL/healthz" 60 || { echo "!! booking-api /healthz 가 안 올라온다"; exit 1; }
KNOB=$(container_env booking-api CLAUDE_TIMEOUT_MS)
T_INJECT=$(epoch_now)
mark "inject: 컨테이너 CLAUDE_TIMEOUT_MS=$KNOB  ← T0"
if [[ "$KNOB" != "1" ]]; then echo "!! 주입 실패: 컨테이너 노브가 $KNOB"; exit 1; fi

# ---- 2·3. 트래픽 + 관찰 ----
# 전부 지어낸 데이터. 큰따옴표·백슬래시 금지 (post_booking 이 printf 로 JSON 을 만든다).
TEXTS=(
  "테스트상사 수출 부킹 요청드립니다. 부산항(KRPUS)에서 로테르담(NLRTM)까지 40HC 2대, 화물은 자동차 부품, 선적 희망일 2026-11-05, 수하인 Test Logistics BV."
  "가상물산 부킹: 인천(KRINC) → 함부르크(DEHAM), 20GP x 3, 품목 가전제품, ETD 2026-11-12, consignee Beispiel Handels GmbH."
  "샘플무역 부킹 문의. 출발 부산신항 KRPUS, 도착 로스앤젤레스 USLAX, 40GP 1대, 섬유 원단, 2026-11-20 출항 희망, 수하인 Sample Imports Inc."
  "테스트상사 추가 부킹: 광양(KRKAN) → 싱가포르(SGSIN), 40HC x 4, 화학제품(비위험물), ETD 2026-11-08, 수하인 Demo Trading Pte."
)
send_one() {  # <phase> <seq> → requests.tsv 한 줄 기록, 결과 한 줄 출력 (http<TAB>status<TAB>reason<TAB>ms)
  local phase=$1 seq=$2 key text line
  key="drill2-$(date +%s%N)-$seq"
  text=${TEXTS[$(( seq % ${#TEXTS[@]} ))]}
  line=$(post_booking "$key" "$text")
  printf '%s\t%s\t%s\t%s\t%s\n' "$(epoch_now)" "$(kst_now)" "$phase" "$key" "$line" >> "$REQ_FILE"
  printf '%s' "$line"
}

mark "traffic: ${RATE_INTERVAL_SEC}초마다 ${RATE_N}건, 최대 ${DURATION_SEC}초, Discord 발송 시 중단=$STOP_ON_DISCORD"
T_PENDING=""; T_FIRING=""; T_DISCORD=""; SEQ=0; SENT=0; NR_SENT=0
DEADLINE=$(( T_INJECT + DURATION_SEC ))
while (( $(epoch_now) < DEADLINE )); do
  for ((i = 0; i < RATE_N; i++)); do
    SEQ=$((SEQ + 1))
    IFS=$'\t' read -r code status reason elapsed <<<"$(send_one inject "$SEQ")"
    SENT=$((SENT + 1))
    if [[ "$status" == needs_review && "$reason" == claude_timeout ]]; then NR_SENT=$((NR_SENT + 1)); fi
    if (( SEQ == 1 )); then
      mark "traffic: 첫 요청 http=$code status=$status review_reason=$reason elapsed_ms=$elapsed"
      if [[ "$status" != needs_review || "$reason" != claude_timeout ]]; then
        echo "!! 첫 요청이 claude_timeout 폴백이 아니다 → 주입 안 됨, 중단"; exit 1
      fi
    fi
  done
  state=$(alert_state "$ALERT"); ratio=$(prom_scalar "$RATIO_EXPR")
  d=$(discord_sent_total); d=${d:-0}
  now=$(epoch_now)
  if [[ -z $T_PENDING && ( $state == pending || $state == firing ) ]]; then T_PENDING=$now; mark "alert: $ALERT pending  (T0+$((now - T_INJECT))s)"; fi
  if [[ -z $T_FIRING && $state == firing ]]; then T_FIRING=$now; mark "alert: $ALERT firing  (T0+$((now - T_INJECT))s)"; fi
  if [[ -z $T_DISCORD ]] && (( d > DISCORD0 )); then T_DISCORD=$now; mark "discord: notifications_total $DISCORD0 → $d  (T0+$((now - T_INJECT))s)"; fi
  log "t=+$((now - T_INJECT))s sent=$SENT needs_review=$NR_SENT ratio=${ratio:-n/a} alert=${state:-none} discord=$d"
  if (( STOP_ON_DISCORD )) && [[ -n $T_DISCORD ]]; then mark "traffic: Discord 발송 확인 → 트래픽 중단"; break; fi
  sleep "$RATE_INTERVAL_SEC"
done
T_TRAFFIC_END=$(epoch_now)
mark "traffic: 종료. 총 $SENT 건, claude_timeout 폴백 $NR_SENT 건 (T0+$((T_TRAFFIC_END - T_INJECT))s)"
snapshot during "$EVIDENCE_DIR/during.json" >/dev/null

# ---- 4. 원복 ----
restore
T_RESTORE=$(epoch_now)

# ---- 5. 회복 증명 (실제 호출, 비용 발생) ----
OK=0
if (( RECOVERY_REQUESTS > 0 )); then
  mark "recovery: 실제 Claude 호출 ${RECOVERY_REQUESTS}건, ${RECOVERY_INTERVAL_SEC}초 간격 (model=$(container_env booking-api CLAUDE_MODEL))"
  for ((r = 1; r <= RECOVERY_REQUESTS; r++)); do
    SEQ=$((SEQ + 1))
    IFS=$'\t' read -r code status reason elapsed <<<"$(send_one recovery "$SEQ")"
    if [[ "$status" == parsed ]]; then OK=$((OK + 1)); fi
    log "recovery #$r http=$code status=$status review_reason=$reason elapsed_ms=$elapsed"
    if (( r < RECOVERY_REQUESTS )); then sleep "$RECOVERY_INTERVAL_SEC"; fi
  done
  mark "recovery: parsed $OK/$RECOVERY_REQUESTS"
fi

# ---- 6. 해제 대기 ----
mark "resolve: $ALERT 해제 대기 (최대 ${WAIT_RESOLVE_SEC}초). 5분 윈도우라 마지막 타임아웃 요청 뒤 5분 이상 걸릴 수 있다"
T_RESOLVED=""
deadline=$(( $(epoch_now) + WAIT_RESOLVE_SEC ))
while (( $(epoch_now) < deadline )); do
  state=$(alert_state "$ALERT")
  if [[ -z $state ]]; then T_RESOLVED=$(epoch_now); break; fi
  ratio=$(prom_scalar "$RATIO_EXPR")
  log "resolve-wait alert=$state ratio=${ratio:-n/a}"
  sleep 15
done
if [[ -n $T_RESOLVED ]]; then
  mark "resolve: ALERTS 에서 사라짐  (T0+$((T_RESOLVED - T_INJECT))s, 원복 후 $((T_RESOLVED - T_RESTORE))s)"
else
  mark "resolve: ${WAIT_RESOLVE_SEC}초 안에 해제 안 됨 (상태=$(alert_state "$ALERT"))"
fi

# resolved 메시지는 Alertmanager 가 다음 group_interval 틱에 보낸다 (warning 라우트 10m). 카운터가 오를 때까지 기다린다.
T_RESOLVED_NOTIFY=""
if [[ -n $T_DISCORD && -n $T_RESOLVED ]]; then
  D_FIRING=$(discord_sent_total); D_FIRING=${D_FIRING:-0}
  mark "discord: resolved 발송 대기 (최대 ${WAIT_RESOLVED_NOTIFY_SEC}초, 현재 $D_FIRING)"
  deadline=$(( $(epoch_now) + WAIT_RESOLVED_NOTIFY_SEC ))
  while (( $(epoch_now) < deadline )); do
    d=$(discord_sent_total); d=${d:-0}
    if (( d > D_FIRING )); then T_RESOLVED_NOTIFY=$(epoch_now); mark "discord: notifications_total $D_FIRING → $d (resolved, 해제 후 $((T_RESOLVED_NOTIFY - T_RESOLVED))s)"; break; fi
    sleep 15
  done
  if [[ -z $T_RESOLVED_NOTIFY ]]; then mark "discord: resolved 발송이 ${WAIT_RESOLVED_NOTIFY_SEC}초 안에 안 옴"; fi
fi

# ---- 7. 증거 + 최종 점검 ----
T_END=$(epoch_now)
snapshot after "$EVIDENCE_DIR/after.json" >/dev/null
evidence_dump "$EVIDENCE_DIR" $(( T_INJECT - 120 )) "$T_END" >/dev/null
TO_NOW=$(prom_scalar 'sum(increase(booking_claude_requests_total{result="claude_timeout"}[2m]))')
mark "check: 최근 2분 claude_timeout 증가분 = ${TO_NOW:-없음(재시작 후 시계열 없음 = 0건)}"
mark "check: CLAUDE_TIMEOUT_MS=$(container_env booking-api CLAUDE_TIMEOUT_MS), 컨테이너 running $(stack_running_count)/7"
D_END=$(discord_sent_total); F_END=$(discord_failed_total)
mark "check: discord notifications_total $DISCORD0 → ${D_END:-?}, failed $FAILED0 → ${F_END:-?}"
echo "== Alertmanager 에 남은 알림 =="; am_alerts || true

python3 - "$EVIDENCE_DIR/summary.json" "$T_INJECT" "${T_PENDING:-}" "${T_FIRING:-}" "${T_DISCORD:-}" "$T_TRAFFIC_END" "$T_RESTORE" "${T_RESOLVED:-}" "${T_RESOLVED_NOTIFY:-}" "$SENT" "$NR_SENT" "$OK" "$RECOVERY_REQUESTS" "$DISCORD0" "${D_END:-}" "$FAILED0" "${F_END:-}" "$OFFSET" <<'PY'
import json, sys, time
out, *v = sys.argv[1:]
keys = ["t_inject","t_pending","t_firing","t_discord","t_traffic_end","t_restore","t_resolved","t_resolved_notify",
        "sent","needs_review_sent","recovery_parsed","recovery_requests","discord_before","discord_after","discord_failed_before","discord_failed_after","clock_offset_sec"]
d = {k: (int(x) if x not in ("", None) and x.lstrip("-").isdigit() else x or None) for k, x in zip(keys, v)}
t0 = d["t_inject"]
def kst(e): return time.strftime("%H:%M:%S", time.gmtime(e + 9*3600)) if e else None
d["kst"] = {k: kst(d[k]) for k in keys[:8]}
d["since_t0_sec"] = {k: (d[k] - t0 if d[k] else None) for k in keys[1:8]}
with open(out, "w") as f:
    json.dump(d, f, ensure_ascii=False, separators=(",", ":")); f.write("\n")
PY

echo; echo "== 타임라인 (KST) =="; cut -f2,3 "$TIMELINE_FILE"
echo; echo "증거: $EVIDENCE_DIR (baseline/during/after.json, *-range.json, timeline.tsv, requests.tsv, summary.json)"
