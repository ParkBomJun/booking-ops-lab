# 훈련 4번 — 자동 롤백 (설정 결함: booking-api PORT 18080)

- 날짜: 2026-10-25 (KST 15:31~15:40)
- 환경: Azure VM `vm-bookingops-lab` (koreacentral, Standard_B2ls_v2) — **첫 실서버 롤백 훈련**
- 깨진 커밋: `6bb00dc` (CD #5, 빨강) → 복구 커밋: `<2ec0e49>` (CD #6, 초록)
- 증거: `evidence/drill4/` (history.log, deploy 로그 발췌, Prometheus up / ALERTS 구간 JSON)

## 요약

`docker-compose.yml`의 booking-api `PORT`를 8080→18080으로 바꾼 커밋을 main에 push 했다. CI 와 CD 의 verify 는 통과했고(테스트가 못 잡는 종류의 결함) 이미지 3개가 빌드·배포됐다. 컨테이너는 정상 기동했지만 호스트 8080 → 컨테이너 8080 에 리스너가 없어 `/healthz` 가 연결 거부(000)였다. `deploy.sh` 가 60초 상한 뒤 상태를 덤프하고 직전 정상 태그 `1d951b2` 로 자동 롤백, **깨진 배포 시작부터 복구까지 73초, 사람 개입 0.** GitHub deploy job 은 빨강으로 끝났고 `history.log` 에 `rolled_back` 이 남았다.

## 영향

| 항목 | 내용 |
|---|---|
| booking-api 응답 불가 | 약 67초 (06:33:07 기동 ~ 06:34:14 첫 200) |
| worker / mock-forwarder | 새 태그로 기동, 로그상 정상. 롤백 때 함께 재생성됨 |
| postgres / prometheus / grafana / alertmanager | 재생성되지 않음(Running 유지). 데이터 손실 없음 |
| 사용자 영향 | 랩 환경, 없음 |

## 타임라인 (UTC, KST = +9h)

| 시각 | T+ | 어디 | 일 |
|---|---|---|---|
| 06:31:46 | 0:00 | GitHub | push `6bb00dc` — `docker-compose.yml` 34행 `PORT: "8080"` → `"18080"` |
| ~06:32 | | Actions | verify ×3 통과 — go vet·test 는 런타임 설정을 모른다 (예상대로) |
| ~06:33:00 | | Actions | build-push ×3 → GHCR `…:6bb00dc…` |
| ~06:33:05 | 1:19 | VM | `deploy.sh 6bb00dc…` 시작: `.env` IMAGE_TAG 교체 → pull → `git checkout` → `up -d` |
| 06:33:07 | | VM | booking-api 로그 `"booking-api starting","addr":":18080"` — 컨테이너 Up, 8080 리스너 없음 |
| 06:33:08 ~ 06:34:06 | | VM | `health http://127.0.0.1:8080/healthz -> 000` (연결 거부), 2초 간격 약 30회 |
| 06:34:08 | 2:22 | VM | `health check did not stabilize within 60s` → `dump_state` (compose ps + 서비스별 로그 40줄) → `rolling back to 1d951b2…` |
| 06:34:08 | | VM | `.env` IMAGE_TAG 복원 → `git checkout --detach 1d951b2` (**compose 설정도 함께 복원**) |
| 06:34:09 | | VM | `compose pull --policy missing` → 7개 전부 `already present locally` (GHCR 무의존) |
| 06:34:09 ~ 06:34:12 | | VM | `up -d`: api·worker·mock-forwarder 3개만 Recreate, 나머지 4개 Running 유지 |
| 06:34:12 | | VM | worker `/healthz` 503 (DB 재연결 중) → 2초 뒤 정상 |
| 06:34:14 | 2:28 | VM | `health ok (1/3)` — 첫 200 |
| 06:34:18 | 2:32 | VM | `health ok (3/3)` → `rollback complete: running 1d951b2…` → `DEPLOY_RESULT=rolled_back`, history.log 기록 |
| ~06:34:40 | | Actions | deploy job 실패(exit 1) — CD #5 빨강, 요약에 출력 끝부분 |
| 06:3x | | GitHub | `git revert` push → CD #6 초록, 정상 배포 (`<2ec0e49>`) |

## 감지

| 층 | 결과 |
|---|---|
| 1차 — `deploy.sh` 헬스체크 (60초 상한, 연속 3회 200) | **감지 + 복구를 같은 프로세스가 수행.** 사람이 알기 전에 끝났다 |
| 2차 — Prometheus `TargetDown` (`for: 1m`) → Discord | **알림 없음.** 장애 67초. `ALERTS{alertname="TargetDown"}` 구간 샘플 수: `<5>` (0 이면 pending 조차 안 됨, >0 이면 pending 에서 해소). `cd.md` 6절 예상("롤백이 60초 안이면 pending 에서 끝날 수도 있다")과 일치 — **CD 가 알림보다 먼저 잡는 것이 정상, 알림은 뒷단 안전망** |
| 사람 | 개입 없음. GitHub deploy job 빨강으로 사후 인지 |

## 근본 원인

- **직접**: `PORT` 환경변수 변경(의도적 결함).
- **구조**: 컨테이너 생존 ≠ 서비스 정상. Docker 는 프로세스가 살아 있으면 `Up` 이다. 포트 불일치·설정 오류는 **밖에서 실제 요청을 보내는 확인**(`/healthz`)으로만 잡힌다.
- **왜 테스트를 통과했나**: `go vet`·단위 테스트는 코드를 검사한다. compose 환경변수는 런타임 설정이라 CI 의 검사 범위 밖이다. 이런 결함을 마지막으로 막는 자리가 배포 직후 헬스체크다.

## 조치

- 자동: 롤백 (위 타임라인). 수동 작업 없음.
- 수동: 깨진 커밋 revert → push → CD #6 정상 배포.

## 재발 방지 / 개선 과제

| # | 상태 | 내용 |
|---|---|---|
| 1 | ✅ 확인됨 | 설정 파일도 커밋 단위로 함께 롤백된다 — `git checkout <prev>` 가 compose 설정을 되돌렸다. "이미지만 롤백, 설정은 옛것" 반쪽 롤백이 없다 |
| 2 | 과제 | compose 레벨 `healthcheck` + `depends_on: condition: service_healthy` → `up -d` 단계에서 더 일찍 실패하게 |
| 3 | 과제 | `deploy.sh`: 배포 대상 태그가 현재 태그의 **조상**(`git merge-base --is-ancestor`)이면, `image_tag` 를 명시한 롤백이 아닌 한 거부 — 아래 "부수 발견" 이 동기 |
| 4 | 과제 | 롤백 완료 시 `deploy.sh` 가 Discord 에 `rolled_back new=… rollback_to=…` 한 줄 전송 — GitHub 을 안 보고 있어도 안다 |

## 부수 발견 — "Re-run" 이 운영을 한 버전 뒤로 보냈다

롤백 대상이 최신 정상 배포(`2b46837`)가 아니라 `1d951b2` 라서 처음엔 `deploy.sh` 의 롤백 대상 선택 결함을 의심했다. `history.log` 로 확인:

```
03:32:26Z ok new=1d951b2… rollback_to=none          ← 첫 수동 배포
03:45:36Z ok new=2b46837… rollback_to=1d951b2…      ← CD #4 (push)
03:47:13Z ok new=1d951b2… rollback_to=2b46837…      ← CD #3 Re-run  ★
06:34:18Z rolled_back new=6bb00dc… rollback_to=1d951b2…
```

CD #3 은 12:36(KST) 수동 실행 → OIDC subject 불일치로 실패 → Terraform 수정 후 **"Re-run all jobs"**. workflow run 은 실행 시점 커밋에 고정되므로 재실행은 **그때의 커밋 `1d951b2` 를 다시 배포**했고, 그 사이 CD #4 가 올린 `2b46837` 을 덮어썼다. 두 커밋은 `infra/` 만 달라 서비스는 동일했지만, 조건이 달랐다면 **초록 불을 보면서 운영이 한 버전 뒤로 내려가는** 상황이다.

- 롤백 대상 `1d951b2` 는 **정확히 N-1** 이었다. `deploy.sh` 결함 아님.
- 교훈: **"Re-run" 은 그 run 의 커밋을 다시 배포한다. 재배포는 `Run workflow`(최신 커밋 또는 `image_tag` 명시)로.**
- 과제 3 이 이 상황을 기계적으로 막는다.

## 배운 점

- 롤백에 GHCR 이 필요 없었다 — 7개 이미지 전부 로컬. 레지스트리 장애 중에도 롤백은 된다는 설계 주장이 실서버에서 확인됐다.
- 60초 상한은 이 서비스에 적절하다 — 정상 기동이 약 7초(up → 3회 200)라 여유가 크다. 기동이 느린 서비스(마이그레이션·캐시 워밍)라면 늘려야 한다.
- 첫 실서버 롤백이 `cd.md` 6절의 예상 타임라인(+1:05 ~ +1:10)과 거의 같았다. 로컬에서 세운 모형이 실서버에 통했다.
- `dump_state` 덕에 원인이 로그 한 줄(`"addr":":18080"`)로 보였다. 롤백은 자동이어도 **왜 실패했는지는 사람이 봐야** 하고, 그 자료를 롤백 전에 남겨두는 것이 맞다.
- 알림이 안 울린 것은 실패가 아니라 설계대로다. 다만 "조용히 롤백됐다" 를 사람이 알 통로가 GitHub 빨강뿐인 것은 아쉽다 → 과제 4.
