# scripts — 운영 자동화 스크립트

## 백업·복구

| 스크립트 | 하는 일 |
|---|---|
| `backup.sh` | 컨테이너 안에서 `pg_dump -Fc` → `backups/<db>-<UTC>.dump` + `.sha256` + `.manifest.json`. 양쪽 sha256 비교, `pg_restore --list` 로 목차 확인, 보관 기간 지난 로컬 파일 정리, `LAST_SUCCESS` 갱신. `BACKUP_TARGET=azure` 면 Blob 컨테이너 `backups` 에 업로드(관리 ID, `--auth-mode login`). Blob 정리는 Storage 수명 주기 정책이 한다 |
| `restore.sh` | 덤프를 `--target <db>` 로 복구. `--yes` 없으면 계획만. 운영 DB 는 `--i-know-this-overwrites` 까지 필요. 복구 전 대상 DB 안전 덤프, 운영 DB 면 worker 정지·재시작, `pg_restore --clean --if-exists --no-owner --single-transaction`, 복구 후 행 수·마이그레이션을 manifest 와 비교, `restore_ms`/`total_ms` 출력 |
| `lib/pg-common.sh` | 둘이 같이 쓰는 조각: docker/docker.exe 선택, `compose exec -T postgres` 래퍼, 행 수 조회, sha256 검증 복사 |

```bash
scripts/backup.sh                                                                  # 로컬 백업
scripts/restore.sh --target bookings_restore_test --yes backups/booking-<UTC>.dump   # 다른 이름의 DB 로 복구해 확인
scripts/restore.sh --target booking --yes --i-know-this-overwrites backups/booking-<UTC>.dump   # 운영 DB 덮어쓰기(훈련 5번)
```

설계·RPO/RTO·cron·훈련 절차·측정값: [`docs/backup.md`](../docs/backup.md).

## 배포·상태 점검

| 스크립트 | 하는 일 |
|---|---|
| `deploy.sh <sha>` | VM 전용. `.env` 의 `IMAGE_TAG` 교체 → `compose pull` → 저장소를 같은 커밋으로 checkout → `up -d` → `/healthz` 3개가 연속 3회 200 이면 성공(`.deploy/current_tag`). 60초 안에 안 되면 이전 태그로 같은 경로를 되밟아 롤백. 마지막 줄 `DEPLOY_RESULT=ok\|rolled_back\|failed`, 종료 코드 0/1/2. CD(`.github/workflows/cd.yml`)가 `az vm run-command` 로 부른다. 로그 `/var/log/booking-deploy.log`, 이력 `.deploy/history.log` |
| `healthcheck.sh` | 로컬·VM 공용. 컨테이너 7개 상태·재시작 횟수, `/healthz` 3개, Prometheus 타깃, firing 알림(심각도별), 디스크(`df`, `docker system df`), 시간 동기화(chrony), 호스트-컨테이너 시계 오차, 마지막 백업 나이(`backups/LAST_SUCCESS` 1행), 배포된 태그를 표로. CRIT 이 하나라도 있으면 종료 코드 1 |

```bash
scripts/healthcheck.sh                       # 로컬. docker → docker.exe 순으로 자동 선택
sudo /opt/booking-ops-lab/scripts/deploy.sh <커밋 sha>   # VM 에서 수동 배포·롤백
```

설계·줄 단위 설명·롤백 훈련(4번): [`docs/cd.md`](../docs/cd.md).

## 스크립트와 cron 한눈에

| 스크립트 | 언제 | 누가 부르나 | 남기는 것 |
|---|---|---|---|
| `backup.sh` | 매일 18:30 UTC (03:30 KST) | VM cron (`/etc/cron.d/booking-backup`, [`docs/backup.md`](../docs/backup.md)) | `backups/*.dump`, Blob, `backups/LAST_SUCCESS` |
| `healthcheck.sh` | 매시간 5분 | VM cron (`/etc/cron.d/booking-healthcheck`, 아래) | journal: `journalctl -t booking-healthcheck` |
| `deploy.sh` | main push, 수동 실행 | CD → `az vm run-command` (root) | `/var/log/booking-deploy.log`, `.deploy/history.log` |
| `restore.sh` | 훈련 5번, 실제 복구 | 사람 | 복구 전 안전 덤프, `restore_ms` |
| `drills/*` | 장애 훈련 1~3번 | 사람, 로컬 | 포스트모템 근거 ([`drills/README.md`](drills/README.md)) |

`/etc/cron.d/booking-healthcheck` (시스템 cron 형식 — 시각 5칸 뒤에 **사용자 칸**이 하나 더 있다):

```cron
# ┌ 분(0-59) ┌ 시(0-23) ┌ 일(1-31) ┌ 월(1-12) ┌ 요일(0-6, 0=일) ┌ 사용자 ┌ 명령
# * 는 "매번". `5 * * * *` = 매시간 5분. `30 18 * * *` = 매일 18:30. VM 시계는 UTC.
# cron 은 로그인 셸이 아니라 PATH 가 거의 비어 있다. 그래서 여기서 정한다. opsadmin 은 docker 그룹이라 docker 명령이 된다.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
5 * * * * opsadmin /opt/booking-ops-lab/scripts/healthcheck.sh 2>&1 | logger -t booking-healthcheck
```

적용: `sudo install -m 644 <파일> /etc/cron.d/booking-healthcheck` → `sudo systemctl reload cron` → 한 시간 뒤 `journalctl -t booking-healthcheck -n 20`. 백업 cron 줄(`30 18 * * * opsadmin … backup.sh`)은 `docs/backup.md` 의 것을 그대로 쓴다.
