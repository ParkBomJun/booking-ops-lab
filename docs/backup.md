# DB 백업·복구

PostgreSQL 을 매일 `pg_dump` 로 떠서 보관하고, 덤프 하나로 DB 를 되살리는 절차. 스크립트는 `scripts/backup.sh`, `scripts/restore.sh`, 공통 조각 `scripts/lib/pg-common.sh`.
장애 훈련 5번(데이터 손상 → 복구 → 소요시간 측정)의 도구이기도 하다.

## 1. 설계 결정

| 결정 | 선택 | 이유 |
|---|---|---|
| 백업 방식 | `pg_dump -Fc` (커스텀 포맷, 논리 백업) | 압축된다. `pg_restore --list` 로 목차 검사가 된다. 테이블 단위 선택 복구가 된다. 평문 SQL 은 셋 다 안 된다. 이 DB 는 수 MB 라 논리 백업 속도(1~2초)로 충분하다 |
| 실행 위치 | 컨테이너 안(`docker compose exec postgres`) | 호스트에 PostgreSQL 클라이언트를 깔지 않는다. 서버 버전과 pg_dump 버전이 항상 같다. 로컬 소켓은 trust 인증이라 스크립트가 비밀번호를 만지지 않는다(`.env` 를 읽지 않는다) |
| 주기·보관 | 매일 1회, 로컬 7일(서버는 2일), Blob 14일 | 하루치 손실(RPO 24h)을 받아들이는 대신 운영 부담이 작다. 더 짧은 RPO 는 PITR(7절)이 필요하다 |
| 무결성 | 컨테이너 안 sha256 ↔ 호스트 sha256 비교, `pg_restore --list` | "파일이 있다" 와 "복구된다" 는 다르다. 전송 중 깨진 바이트와 깨진 아카이브를 백업 시점에 잡는다 |
| Blob 정리 | 스크립트가 지우지 않는다. Storage 수명 주기 정책(`infra/terraform/storage.tf`, `backup_retention_days`)이 지운다 | 정책은 cron 이 죽어도, VM 이 사라져도 돈다. 두 곳에서 지우면 어느 쪽이 지웠는지 추적이 안 된다. 소프트 삭제 7일이 실수의 안전망 |
| 운영 DB 복구 | `--yes` + `--target` + `--i-know-this-overwrites` 세 가지가 전부 있어야 한다 | 복구는 "덮어쓰기" 다. 실수로 운영 DB 를 백업 시점으로 되돌리면 그 자체가 장애다 |

## 2. RPO / RTO

- **RPO(복구 시점 목표)**: 잃어도 되는 최대 데이터 구간. 매일 18:30 UTC(03:30 KST) 백업이면 최악 **24시간**.
- **RTO(복구 시간 목표)**: 손상을 알아챈 뒤 서비스가 정상으로 돌아오기까지. 목표 **5분 이내**(사람 판단 포함).

2026-10-22 로컬 측정(WSL + Docker Desktop, `docker.exe`, DB 437행 · 디스크 7.9MB):

| 단계 | 측정값 |
|---|---|
| `pg_dump -Fc` 자체 | 1,291 ms |
| backup.sh 전체(검사·복사·manifest 포함) | 4.96 s |
| 덤프 크기 | 21,088 B (TOC 16 항목) |
| `pg_restore` 자체 (빈 DB 에) | 619 ms |
| restore.sh 전체 (복사·검증 포함, 빈 DB) | 6.76 s |
| restore.sh 전체 (이미 있는 DB 위에, 사전 덤프 포함) | 6.31 s (`pg_restore` 824 ms) |

서버에서는 여기에 Blob 다운로드(초 단위)와 worker 정지·재시작(drain 최대 15초)이 더해진다. 훈련 5번에서 다시 잰다.

## 3. 산출물

`backups/` (git 제외) 에 아래 네 가지. 파일명의 시각은 항상 UTC.

| 파일 | 내용 |
|---|---|
| `<db>-<UTC>.dump` | `pg_dump -Fc` 결과 |
| `<db>-<UTC>.dump.sha256` | `sha256sum -c` 형식 |
| `<db>-<UTC>.manifest.json` | db, 크기, `duration_ms`, PG 서버·pg_dump 버전, 선택된 TOC 항목 수, 적용된 마이그레이션 목록, 테이블별 행 수 |
| `LAST_SUCCESS` | 1행 = 마지막 성공 시각(UTC ISO 8601). 2·3행 = 파일명, 대상. healthcheck.sh 가 1행만 읽는다 |
| `<db>-pre-restore-<UTC>.dump` | restore.sh 가 덮어쓰기 직전에 뜬 안전 덤프 |

manifest 예:

```json
{
  "db": "booking",
  "file": "booking-20261022T113755Z.dump",
  "created_at": "2026-10-22T11:37:57Z",
  "backup_target": "local",
  "size_bytes": 21088,
  "sha256": "1aa985e7…",
  "duration_ms": 1291,
  "pg_server_version": "17.10",
  "pg_dump_version": "17.10",
  "toc_entries": 16,
  "schema_migrations": ["001_create_bookings", "002_worker_columns"],
  "row_counts": {"bookings": 437, "schema_migrations": 2}
}
```

행 수는 덤프와 같은 트랜잭션이 아니다. 쓰기가 진행 중이면 몇 건 차이 날 수 있다(복구 검증에서 그 점을 감안한다).

## 4. backup.sh 블록별

| 블록 | 하는 일 | 왜 |
|---|---|---|
| `set -Eeuo pipefail`, `umask 077` | 실패 즉시 중단, 파이프 중간 실패도 실패, 새 파일은 600 | cron 에서 "조용히 반쯤 성공" 이 가장 위험하다 |
| 입력 검증 | `BACKUP_RETENTION_DAYS` ≥ 1 정수, `BACKUP_TARGET` ∈ auto/local/azure | 0 이면 방금 만든 백업까지 지운다 |
| 모드 결정 | `auto` = az CLI 가 있고 `BACKUP_STORAGE_ACCOUNT` 가 있으면 azure, 아니면 local | 개발 PC 에 az 가 깔려 있어도 계정 이름이 없으면 업로드를 시도하지 않는다 |
| `flock -n` | 같은 디렉터리에서 두 개가 동시에 돌지 않게 | cron 겹침, 수동 실행 겹침 |
| `pick_docker` | `DOCKER` 환경변수 → 데몬에 붙는 `docker` → `docker.exe` | WSL 통합이 꺼진 PC 와 서버를 같은 스크립트로 |
| `pg_isready` + `POSTGRES_DB` 읽기 | 컨테이너가 응답하는지, DB 이름은 무엇인지 | DB 이름은 컨테이너 환경변수에서. 호스트의 `.env` 는 열지 않는다 |
| inspect | 서버 버전, 테이블별 `count(*)`, `schema_migrations` | manifest 의 기준값 |
| `pg_dump -U … -d … -Fc --lock-wait-timeout=30000 -f /tmp/…` | 컨테이너 안 파일로 덤프 | `--lock-wait-timeout`: 마이그레이션이 잠금을 잡고 있으면 30초 뒤 실패. cron 이 영원히 매달리지 않는다 |
| `pg_restore --list` | 목차가 읽히는지, 항목 수 | 깨진 아카이브를 여기서 거른다 |
| `copy_out_dump` | 컨테이너 sha256 → `cat` 으로 호스트 전송 → 호스트 sha256 비교 → `.part` 를 제 이름으로 | 전송 손상 검출. `.part` 가 남아 있으면 "미완성" 이란 뜻 |
| manifest | `printf` 로 JSON | 서버에 jq 를 강제하지 않는다. 값이 전부 숫자나 검증된 식별자라 이스케이프가 필요 없다 |
| Azure | `az login --identity --allow-no-subscriptions` → `az storage blob upload --auth-mode login` ×3 | 관리 ID 에는 Storage 데이터 역할만 있다(구독 권한 없음). 공유 키가 꺼진 계정이라 `--auth-mode login` 이 필수. 덮어쓰기 옵션을 주지 않아 같은 이름이 있으면 실패 |
| prune | `find -maxdepth 1 -type f -name '*.dump' … -mmin +N` | `-mtime +7` 은 "만 8일" 로 해석돼 하루 어긋난다. `LAST_SUCCESS`, lock, 다른 파일은 패턴에 없어 안 지운다 |
| `LAST_SUCCESS` | 임시 파일에 쓰고 `mv` | 읽는 쪽(healthcheck.sh)이 반쯤 쓰인 파일을 보지 않는다 |
| `trap ERR` / `trap EXIT` | 실패 시 `backup: FAIL: step=<단계>` 한 줄, 컨테이너 임시 파일 삭제 | cron 메일·journal 에서 한 줄로 원인 파악 |

## 5. restore.sh 블록별

| 블록 | 하는 일 | 왜 |
|---|---|---|
| 인자 | `--target`(필수), `--yes`, `--i-know-this-overwrites`, `--from-azure <blob>`, 덤프 파일 | `--yes` 없으면 계획만 출력하고 종료 코드 2. 아무것도 바꾸지 않는다 |
| 이름 검증 | 소문자·숫자·밑줄만. `postgres/template0/template1` 거부 | 이 검사를 통과한 이름만 SQL 에 끼운다 |
| 운영 DB 판정 | 컨테이너의 `POSTGRES_DB` 와 같으면 `--i-know-this-overwrites` 요구. 이름을 못 읽으면 중단(fail-closed) | "모르면 안 한다" |
| `--from-azure` | blob 이름은 파일명 한 조각만(`/`, `..` 거부). 로그인돼 있으면 그대로, 아니면 관리 ID 로 로그인 → `.dump`, `.sha256`, `.manifest.json` 다운로드(뒤 둘은 없어도 진행) | 서버에서 Blob 복구. 로컬에서 az 로그인한 사람도 같은 명령 |
| sha256 검사 | `.sha256` 이 옆에 있으면 `sha256sum -c` | 깨진 파일로 운영 DB 를 덮지 않는다 |
| worker 정지 | 대상이 운영 DB 일 때만 `docker compose stop worker`. 끝나면(실패해도) `start` | 복구 도중 행을 집어가 중간 상태로 전이시키면 안 된다. booking-api 는 세운 상태로 두므로 복구 몇 초 동안의 요청은 5xx 가 날 수 있다 |
| copy-in | 덤프를 stdin 으로 컨테이너 `/tmp` 에 넣고 양쪽 sha256 비교 | backup 과 대칭 |
| pre-restore dump | 대상 DB 가 있으면 먼저 `pg_dump -Fc` 로 `backups/<db>-pre-restore-<UTC>.dump` | 되돌릴 길. 백업 이후 생긴 행(RPO 구간)도 여기 남아 나중에 건질 수 있다 |
| `createdb` | 대상이 없으면 새로 만든다 | 훈련용 빈 DB, 다른 이름으로 복구해 비교하는 용도 |
| `pg_restore` 플래그 | `--clean` 만들기 전에 같은 이름 객체 DROP · `--if-exists` DROP 에 IF EXISTS(빈 DB 에서 오류 없음) · `--no-owner` 덤프의 소유자를 강제하지 않음(다른 환경·다른 역할 이름에도 복구) · `--single-transaction` 전부 하나의 트랜잭션(중간 실패 시 전부 롤백, `--exit-on-error` 포함) | "반쯤 복구된 DB" 가 남지 않는다 |
| 검증 | 테이블별 `count(*)` 와 `schema_migrations` 를 manifest 와 비교. 다르면 종료 코드 3 | 복구 "성공" 의 기준을 숫자로 |
| RTO evidence | `restore_ms`(pg_restore 만), `total_ms`(전체) | 포스트모템에 그대로 적는다 |

## 6. 실행

### 로컬
```bash
scripts/backup.sh                                   # backups/ 에 저장. docker 가 안 붙으면 docker.exe 로 자동 전환
scripts/restore.sh --target bookings_restore_test backups/booking-<UTC>.dump         # 계획만 (종료 2)
scripts/restore.sh --target bookings_restore_test --yes backups/booking-<UTC>.dump   # 새 DB 에 복구해 비교
docker compose exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" bookings_restore_test'   # 정리
```

환경변수:

| 변수 | 기본 | 뜻 |
|---|---|---|
| `BACKUP_TARGET` | `auto` | `local` / `azure` / `auto`(az + 계정명 있으면 azure) |
| `BACKUP_DIR` | `<repo>/backups` | 산출물 위치 |
| `BACKUP_RETENTION_DAYS` | `7` | 로컬 파일 보관 일수 |
| `BACKUP_STORAGE_ACCOUNT` | 없음 | Storage 계정 이름 (`terraform output storage_account_name`) |
| `BACKUP_CONTAINER` | `backups` | Blob 컨테이너 (`storage.tf` 와 같아야 한다) |
| `DOCKER` | 자동 | `docker` 명령 경로. 지정하면 자동 선택을 건너뛴다 |

### 서버(VM) cron
VM 은 UTC 다. 03:30 KST = **전날 18:30 UTC**. `/etc/cron.d/booking-backup`:

```cron
# cron 은 로그인 셸이 아니다. PATH 가 거의 비어 있고 ~/.bashrc 도 읽지 않는다. 그래서 전부 여기서 정한다.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
# 서버는 compose 파일 두 장을 겹쳐 쓴다(docker-compose.prod.yml). 스크립트가 같은 프로젝트를 보도록 맞춘다.
COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml
BACKUP_TARGET=azure
BACKUP_STORAGE_ACCOUNT=stbookingopslab000     # 예시. terraform output storage_account_name 값
BACKUP_RETENTION_DAYS=2                       # VM 디스크는 작다. 장기 보관은 Blob(14일, Terraform backup_retention_days)
30 18 * * * opsadmin /opt/booking-ops-lab/scripts/backup.sh 2>&1 | logger -t booking-backup
```

cron 환경이 셸과 다른 점:

| 항목 | 로그인 셸 | cron | 대응 |
|---|---|---|---|
| `PATH` | 넓다 | `/usr/bin:/bin` 정도 | 위처럼 명시. `docker`, `az` 가 `/usr/bin` 에 있어야 한다 |
| `docker.exe` | WSL 에만 | 없음 | `pick_docker` 가 `docker` 를 먼저 고른다. VM 에는 docker.exe 자체가 없다 |
| 현재 디렉터리 | 아무 곳 | `$HOME` | 스크립트가 스스로 리포지토리 루트로 `cd` 한다 |
| docker 권한 | `opsadmin` 은 docker 그룹 | 같은 사용자로 실행하면 같다 | cron 줄의 사용자 칸을 `opsadmin` 으로 |
| `az` 설정 | `~/.azure` | 같은 사용자면 같다 | `az login --identity` 는 매번 해도 된다 |
| 출력 | 터미널 | 메일(없으면 버려짐) | `logger` 로 journal 에. `journalctl -t booking-backup` |

적용: `sudo install -m 644 <파일> /etc/cron.d/booking-backup` → `sudo systemctl reload cron` → 다음 날 `cat /opt/booking-ops-lab/backups/LAST_SUCCESS`.

## 7. 복구 훈련 절차 (훈련 5번: 손상 가정 → 복구 → 소요시간 측정)

전부 가짜 데이터. 운영 DB 에 하는 것이므로 **훈련 전 `backup.sh` 를 한 번 더** 돌려 기준 덤프를 만든다.

| # | 단계 | 명령 / 확인 | 기록할 것 |
|---|---|---|---|
| 0 | 기준 | `scripts/backup.sh`, `cat backups/LAST_SUCCESS`, manifest 의 `row_counts` | 백업 시각 = RPO 시작점 |
| 1 | 손상 주입 | `docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DELETE FROM bookings WHERE id % 3 = 0"'` | 주입 시각 T0 |
| 2 | 감지 | Grafana 상태별 건수 급감, `booking_needs_review_count` 등 Gauge 변화. 알림 규칙 후보: 건수 급감(`delta(... [5m]) < -N`) | 감지 시각, 어떤 화면에서 |
| 3 | 복구 | `scripts/restore.sh --target booking --yes --i-know-this-overwrites backups/booking-<UTC>.dump` (서버는 `--from-azure booking-<UTC>.dump`) | 출력의 `restore_ms`, `total_ms`. worker 정지·재시작 로그 |
| 4 | 검증 | 출력 표 `VERIFY OK`, Grafana 건수 복귀, `curl 127.0.0.1:8080/healthz`, worker `/healthz` 의 poller | 정상 복귀 시각 T1 |
| 5 | 결과 | RTO = T1 − 감지 시각. RPO 실제값 = 손상 시각 − 백업 시각. 손실 구간 데이터는 `backups/booking-pre-restore-<UTC>.dump` 에 남아 있다 | 포스트모템 `docs/postmortems/` |

포스트모템 양식은 CLAUDE.md 와 같다: 요약 / 영향 / 타임라인 / 감지 방법 / 근본 원인 / 조치 / 재발 방지 / 배운 점.

## 8. 무엇을 지켜볼 것인가

| 신호 | 방법 | 기준 |
|---|---|---|
| 백업이 멈춤 | healthcheck.sh 가 `backups/LAST_SUCCESS` 1행의 나이를 계산 | 26시간 초과면 경고(하루 주기 + 여유 2시간) |
| 같은 것을 Prometheus 로 | node_exporter textfile collector 에 `booking_backup_last_success_timestamp_seconds` (backup.sh 의 TODO) | 규칙 `time() - booking_backup_last_success_timestamp_seconds > 26*3600` → warning |
| 백업 크기 급변 | manifest `size_bytes` 추이 (또는 같은 지표를 textfile 로) | 전날 대비 ±50% 면 확인. 0 에 가까우면 빈 DB 를 떴다는 뜻 |
| Blob 에 실제로 있는가 | `az storage blob list --auth-mode login --account-name … -c backups -o table` | 날짜별 3개(dump, sha256, manifest) |
| 복구가 실제로 되는가 | 월 1회 `restore.sh --target bookings_restore_test` 로 복구 후 삭제 | `VERIFY OK` 와 `restore_ms` 기록 |

## 9. 한계와 다음 단계

- **PITR(시점 복구) 없음.** 지금은 "마지막 백업 시점" 으로만 돌아간다. 특정 시각(예: 잘못된 DELETE 직전)으로 돌아가려면 WAL 아카이빙이 필요하다: `archive_mode=on` + `archive_command`(WAL 조각을 Blob 으로) + 주기적 `pg_basebackup` + 복구 시 `restore_command` 와 `recovery_target_time`. 도구로는 pgBackRest / WAL-G. 대가는 저장소·운영 복잡도·VM 디스크. 단일 소형 VM 랩에서는 하루 RPO 를 받아들이고 뺐다.
- **단일 VM.** VM 디스크가 죽으면 로컬 백업도 같이 사라진다. 그래서 Blob 업로드가 "진짜 백업" 이고 로컬은 2일짜리 캐시다. Blob 은 LRS(한 데이터센터 3중 복제)라 리전 장애는 안 막는다.
- **논리 백업의 한계.** `pg_dump` 는 DB 가 커지면 선형으로 느려지고, 복구는 인덱스를 다시 만든다. 수 GB 이상이면 물리 백업(pg_basebackup)으로 바꾼다.
- **버전.** 덤프는 PG 17.10 에서 떴다. 같은 메이저 또는 더 새 버전으로만 복구한다. 더 오래된 서버로는 안 된다.
- **복구 중 API.** booking-api 는 세워 두므로 복구 몇 초 동안 요청이 실패할 수 있다. 완전 무중단이 필요하면 다른 이름으로 복구한 뒤 이름을 바꾸는(rename) 방식으로 바꾼다.
- **행 수 기준값의 시차.** manifest 의 행 수는 덤프와 다른 트랜잭션이다. 쓰기 중이면 수 건 차이가 날 수 있고, 그때는 종료 코드 3 이 "실패" 가 아니라 "확인 필요" 다.
- **Azure 경로는 아직 실행해 보지 못했다.** 로컬에 az CLI 가 없고, 인프라도 만들기 전이다. 3단계에서 VM 위에서 처음 돌릴 때 `BACKUP_TARGET=azure` 경로와 `--from-azure` 를 실제로 검증하고 이 문서의 측정표를 갱신한다.

## 10. 2026-10-22 로컬 검증 기록

운영 스택을 띄운 채(다른 훈련이 동시에 행을 넣는 중) `docker.exe` 로 실행. 운영 DB 는 읽기만 했다.

| 확인 | 결과 |
|---|---|
| ShellCheck 0.11.0 (`-x`, 스크립트 3개) | 경고 0 |
| `backup.sh` (local) | OK. 4.96 s, `pg_dump` 1,291 ms, 21,088 B, TOC 16, 437 행 |
| 호스트 파일을 컨테이너로 되돌려 `pg_restore --list` | 정상(CUSTOM, gzip, 17.10) |
| `restore.sh` 계획 모드(`--yes` 없음) | 종료 코드 2, 변경 없음 |
| `restore.sh --target bookings_restore_test --yes` (새 DB) | `pg_restore` 619 ms, 전체 6,758 ms, `VERIFY OK` (437/437, 2/2, 마이그레이션 일치) |
| 복구본 내용 해시 vs 백업 직후 운영 DB 해시 | 같음(`f350f5…`). 그 사이 운영 DB 는 440 행으로 늘어 있었다(다른 훈련의 쓰기) |
| 같은 DB 에 두 번째 복구(`--clean --if-exists` + 사전 덤프 경로) | 사전 덤프 21,136 B 생성, `pg_restore` 824 ms, 전체 6,309 ms, `VERIFY OK` |
| 안전장치 | 운영 DB 이름 + `--i-know-this-overwrites` 없음 → 거부. `postgres` → 거부. `Bad-Name` → 거부. `BACKUP_TARGET=azure` + az 없음 → 거부. `BACKUP_RETENTION_DAYS=0` → 거부 |
| 뒷정리 | `dropdb bookings_restore_test`, 컨테이너 `/tmp` 비어 있음, worker 는 "Up 4 days" 그대로(정지된 적 없음) |
