# Runbook — 알림별 대응 절차

알림의 `runbook` annotation 이 이 문서의 항목으로 연결된다. 각 항목: **의미 → 먼저 볼 것 → 조치 → 해제 조건**.
공통 입구: Grafana http://localhost:3000, Prometheus http://localhost:9090, Alertmanager http://localhost:9093.

## 심각도와 채널
| severity | 뜻 | 채널 | 상기 주기 |
|---|---|---|---|
| critical | 서비스 정지·처리 정체. 지금 본다 | Discord | 1h |
| warning | 품질 저하. 수십 분 안에 확인 | Discord | 4h |
| info | 선행 신호·기록. Alertmanager UI 에서만 | 없음 | 24h |

## 억제(inhibition) 표
source 가 firing 인 동안 같은 `service` 의 target 은 발송되지 않는다.

| # | source (살아 있으면) | target (숨겨짐) | 이유 |
|---|---|---|---|
| 1 | `TargetDown` | 같은 service 의 모든 warning / info | 서비스가 죽었는데 "에러율 높음" 은 의미 없다 |
| 1b | `TargetDown{service=worker}` | `BookingProcessingStalled` | Stalled 식이 "지표 없음" 도 0 으로 보므로 worker 가 죽으면 둘 다 울린다. 원인은 하나 |
| 2 | `BookingProcessingStalled` | `BacklogAging` | 같은 사실의 약한 표현 |
| 3 | 모든 critical | 같은 service 의 모든 info | 1·2 가 못 덮는 조합의 안전망 |

---

## TargetDown
- **의미**: 서비스가 1분 이상 스크레이프에 응답하지 않음. 훈련 4번(잘못된 배포)의 1차 신호.
- **먼저 볼 것**: `docker compose ps` 재시작 루프 여부, `docker compose logs <svc> --tail 50`, 해당 서비스 `/healthz`.
- **조치**: 배포 직후면 CD 롤백(이전 이미지 태그). DB 단절이면 postgres 먼저. 설정 오류면 `.env` 확인 후 `up -d`.
- **해제**: `up == 1` 복귀. resolved 알림 수신.

## BookingProcessingStalled
- **의미**: parsed 행이 있는데 5분 이상 parsed 에서 나간 전이가 0건(전이 지표가 아예 없어도 0 으로 본다). worker 가 집어가지 못하거나 쓰지 못한다. 임대 라이브락, 폴러 정지, DB claim 실패, 재시작 직후 정체 모두 여기 걸린다.
- **먼저 볼 것**: worker `/healthz` 의 `poller`(stale 이면 폴러 멈춤), worker 로그의 `claim failed`, `worker_version_conflicts_total` 증가 여부(임대 라이브락), `worker_backlog_count{status="parsed"}`.
- **조치**: 폴러 stale → worker 재시작. claim failed → DB 연결·마이그레이션 002 적용 여부. 충돌 폭증 → `WORKER_LEASE_MS` 가 `WORKER_HTTP_TIMEOUT_MS` 의 2배 이상인지.
- **해제**: `rate(worker_transitions_total{from="parsed"}[5m]) > 0`.

## ForwarderErrorRateHigh
- **의미**: 포워더 호출의 20% 이상 실패. 훈련 1번.
- **먼저 볼 것**: `worker_attempts_total` 의 `result` 분포(timeout / http_5xx / conn_error 중 무엇인지), mock-forwarder 의 `forwarder_requests_total{outcome=~"injected.*"}` 와 시작 로그의 faults, `worker_retries_total` 추세.
- **조치**: conn_error → 포워더 기동 상태. timeout → ForwarderLatencyHigh 항목. 5xx → 포워더 쪽 장애, 재시도가 흡수하는지 `FailedBookingsIncreasing` 로 확인. 실제 운영이라면 포워더 측에 연락하고, 실패함 건은 복구 후 `status='parsed', attempts=0` 으로 되돌려 재처리.
- **해제**: 비율 0.2 미만 5분.

## ForwarderLatencyHigh
- **의미**: p95 > 2s 10분. 아직 에러는 아니지만 타임아웃(3s) 폭증 직전.
- **먼저 볼 것**: 지연 히스토그램 분포, 포워더 `DELAY_MS`, `worker_inflight`(4에 붙어 있으면 처리기가 전부 대기 중).
- **조치**: 일시적이면 관찰. 지속되면 `WORKER_HTTP_TIMEOUT_MS` 를 올리기보다 포워더 원인 해소. 임시로 `WORKER_CONCURRENCY` 상향 검토.
- **해제**: p95 < 2s.

## FailedBookingsIncreasing
- **의미**: 15분에 실패함 3건 초과 증가. 재시도로도 못 살린 건.
- **먼저 볼 것**: `SELECT idempotency_key, last_error FROM bookings WHERE status='failed' ORDER BY updated_at DESC LIMIT 20`. `last_error` 가 `HTTP 4xx` 면 우리 데이터 문제, `max attempts` 면 포워더 장애.
- **조치**: 4xx → parsed 데이터 수정 후 재처리. 포워더 장애 → 복구 후 일괄 재처리(위 SQL 로 parsed 복귀).
- **해제**: 15분 증가분 3 이하.

## NeedsReviewRatioHigh
- **의미**: 신규 부킹의 절반 이상이 파싱 실패로 검토함행. 훈련 2번(Claude 타임아웃).
- **먼저 볼 것**: `booking_claude_requests_total` 의 result(`claude_timeout` / `claude_error` / `invalid_json` / `validation_failed`), `booking_claude_request_duration_seconds` p95, booking-api 로그의 `reason`.
- **조치**: timeout → `CLAUDE_TIMEOUT_MS` 와 Anthropic 상태 확인. error → 키·워크스페이스·한도. invalid_json/validation → 프롬프트 회귀, 최근 배포 확인. 폴백이 동작 중이므로 서비스는 살아 있다. 복구 후 검토함 건은 재파싱(향후 엔드포인트).
- **해제**: 비율 0.5 미만 5분.

## HttpErrorRateHigh
- **의미**: booking-api 5xx 5% 초과.
- **먼저 볼 것**: `/healthz` 의 `db`, booking-api 로그 ERROR 줄, postgres 상태.
- **조치**: DB 단절이면 postgres 복구. 배포 직후면 롤백.
- **해제**: 5xx 비율 5% 미만.

## BacklogAging (info)
- **의미**: 가장 오래 기다린 처리 대상이 2분 초과. 처리는 되지만 따라가지 못함.
- **볼 것**: `worker_inflight`, 포워더 지연. 지속되면 Stalled 로 번질 수 있다.

## VersionConflictsObserved (info)
- **의미**: 낙관적 잠금 충돌 발생. 정상은 0.
- **볼 것**: worker 로그 `version conflict, result discarded` 의 `expected_version/actual_version`. 임대 만료(느린 호출) 또는 수동 UPDATE. 데이터는 안전하다(덮어쓰지 않음).

## ConfigAdjusted (info)
- **의미**: worker 가 시작할 때 설정이 불변식을 어겨 자동 보정됐다. 현재 검사: `WORKER_LEASE_MS < 2 × WORKER_HTTP_TIMEOUT_MS` → 2배로 상향. 서비스는 정상 동작 중이다.
- **볼 것**: worker 시작 로그의 `too short ... raising` 줄(`configured_ms`, `raised_to_ms`), `.env` 또는 compose 의 해당 값.
- **조치**: 의도한 값이면 `.env` 를 보정값으로 맞춰 경고를 없앤다. 의도치 않은 값이면 원인(복붙 실수, 단위 혼동 ms/s)을 고친다. 재기동하면 Gauge 가 0 이 되어 해제된다.

## NeedsReviewBacklog (info)
- **의미**: 검토 대기 20건 초과 30분. 사람이 처리하지 않은 적체.

## DiskUsageHigh (3단계, node_exporter 추가 후)
- 훈련 6번. 로그 정리 스크립트 실행, Prometheus retention 확인.

## Silence 사용법
훈련 중 의도된 알림은 Alertmanager UI → Silences → New Silence 에 `alertname`, 기간, 사유를 적어 끈다. 끄는 것도 기록이다.
