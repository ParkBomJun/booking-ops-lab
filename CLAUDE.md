# Booking Ops Lab — 부킹 처리 서비스 운영 플랫폼

## 프로젝트 목적
물류 스타트업 **ITOps 엔지니어** 포지션 지원용 포트폴리오.

작은 부킹 처리 서비스를 하나 만들고, **이 서비스를 클라우드에서 안정적으로 운영하는 체계 전체**를 직접 구축한다.
**앱은 단순하게, 인프라·운영이 주인공이다.**

핵심 메시지:
**"클라우드 인프라를 코드로 구축하고, CI/CD로 안전하게 배포하고, 장애를 먼저 감지해 원인을 분석하고, 재발을 막는 운영을 할 수 있다."**

## 지원 포지션 요구사항과 이 프로젝트의 대응
| 공고 항목 | 이 프로젝트에서 보여줄 것 |
|---|---|
| 모니터링 시스템 구축·운영 | Prometheus + Grafana 대시보드, Alertmanager 알림 |
| 장애 원인 분석·대응 프로세스 | 장애 주입 훈련 + 포스트모템 문서 |
| 운영 지표 기반 품질 개선 | 에러율·지연시간·재시도 지표와 개선 기록 |
| 반복 업무 자동화 스크립트 | 백업, 헬스체크, 정리 작업 bash 스크립트 + cron |
| CI/CD 도입·관리 | GitHub Actions: 테스트 → 이미지 빌드 → 배포 → 헬스체크 → 실패 시 자동 롤백 |
| 보안 점검·대응 체계 | 비밀값 관리, 최소 권한, 네트워크 접근 제한, 보안 점검 체크리스트 |
| 접근 권한 관리 | CI용 권한 분리(OIDC), DB 계정 권한 분리, 접근 통제 문서 |
| 클라우드 인프라 운영 (필수) | Terraform으로 Azure 인프라 구축·운영 |
| DB 운영 (우대) | PostgreSQL 백업 자동화 + 복구 훈련 |
| 해운·물류 이해 (우대) | 부킹·포워더 연동 도메인으로 서비스 구성 |

## 작업자 정보 (중요)
- 작업자의 강점은 **현장 IT 운영**(대규모 PC 배포·이미징 자동화, 장애 대응, 금융권 상주 환경)이다.
- 클라우드·CI/CD는 **실무 경험이 없고 이 프로젝트로 처음 제대로 해본다.**
- **Go는 처음**이다. React는 경험 있음.
- 평일은 시간이 거의 없고, 금·토·일에 몰아서 작업한다.

## Claude 작업 규칙
1. **인프라 설정은 한 줄씩 설명하면서 작성한다.** Terraform, GitHub Actions, Dockerfile, Prometheus 설정 등은 이 포트폴리오의 핵심이므로 작업자가 면접에서 모든 줄을 설명할 수 있어야 한다.
2. Go 코드는 단순하게 유지하고, 새로운 개념이 처음 나오면 한국어로 짧게 설명한다.
3. 작게 만들고 → 실행해보고 → 다음으로 간다.
4. 각 작업이 끝나면 관련 문서(`docs/`)를 업데이트한다. 특히 **AI가 처음에 틀리게 만든 부분과 고친 과정**은 `docs/ai-usage.md`에 반드시 기록한다.
5. 데이터는 **전부 직접 만든 가짜 데이터**만 쓴다. 실제 회사·고객·개인 정보, 현 직장 관련 정보는 절대 넣지 않는다.
6. 비밀값은 `.env`, GitHub Secrets, Azure Key Vault로만 관리한다. 절대 커밋하지 않는다.
7. **Azure 리소스를 만들거나 지우는 명령은 실행 전에 작업자에게 확인받는다.** 비용이 드는 작업은 예상 비용을 먼저 말한다.
8. 계획보다 늦어지면 아래 "범위 줄이기 순서"를 따른다.

## 시스템 구성

### 애플리케이션 (단순하게)
- **booking-api (Go)**: 부킹 요청 텍스트를 받아 파싱·검증 후 DB 저장. 같은 요청은 한 번만 저장(멱등성).
  - 파싱: Claude API 사용. **타임아웃 + 실패 시 검토 대기함으로 보내는 폴백** 필수 (외부 의존성 장애 대응 시연용).
- **worker (Go)**: 모의 포워더에 상태 조회·전송. 타임아웃, 지수 백오프 재시도, 최대 횟수 초과 시 실패함 이동.
- **mock-forwarder (Go)**: 환경변수로 장애를 주입하는 모의 외부 시스템.
  - `FAIL_RATE`, `DELAY_MS`, `DUP_RATE`, `OUT_OF_ORDER`
- **PostgreSQL**
- 별도 프론트엔드는 만들지 않는다. **Grafana가 운영 화면 역할**을 한다.

### 모든 서비스가 제공할 것
- `/healthz` (DB 등 의존성 포함 상태)
- `/metrics` (Prometheus 형식): 요청 수, 에러 수, 지연시간, 재시도 횟수, 실패함·검토 대기함 건수
- `log/slog` JSON 구조화 로그 (부킹 ID, 단계, 소요시간)

### 운영 스택
- **Docker / docker-compose**: 로컬과 서버 동일 구성
- **Prometheus**: 지표 수집 (앱 + node_exporter + postgres_exporter)
- **Grafana**: 서비스·서버·DB 대시보드
- **Alertmanager**: 알림 (Discord 또는 이메일 웹훅)
  - 예: 에러율 급증, 재시도 폭증, 실패함 증가, 디스크 80% 초과, 헬스체크 실패

### Azure 인프라 (Terraform으로만 생성)
- 리소스 그룹, 가상 네트워크, 서브넷, NSG(필요한 포트만, SSH는 내 IP만)
- Linux VM 1대 (작은 사양) — docker-compose로 전체 스택 실행
- Storage Account (Blob) — DB 백업 저장
- Key Vault — 비밀값 저장
- **예산 알림을 가장 먼저 설정한다.** 안 쓸 때는 `terraform destroy`로 정리한다.

### CI/CD (GitHub Actions)
1. PR / push: `go vet`, `go test`, Dockerfile 빌드 확인
2. main 병합: 이미지 빌드 → GHCR 푸시 (커밋 SHA 태그)
3. 배포: VM에 새 이미지 반영 → `/healthz` 확인
4. **헬스체크 실패 시 이전 태그로 자동 롤백**
5. Azure 인증은 장기 비밀키 대신 **OIDC 연동** 사용

### 자동화 스크립트 (bash, `scripts/`)
- `backup.sh`: pg_dump → Blob 업로드, 보관 기간 지난 백업 정리
- `restore.sh`: 백업에서 복구 (복구 훈련용)
- `healthcheck.sh`: 전체 서비스 상태 점검 리포트
- cron 등록 방법 문서화

## 디렉터리 구조 (예정)
```
/services
  /booking-api
  /worker
  /mock-forwarder
/infra
  /terraform          # Azure 인프라
  /monitoring         # prometheus.yml, 알림 규칙, Grafana 대시보드 JSON
/scripts              # 운영 자동화 bash 스크립트
/.github/workflows    # CI/CD
/docs
  architecture.md     # 구조도
  runbook.md          # 장애 유형별 대응 절차
  postmortems/        # 장애 훈련별 포스트모템
  security.md         # 보안 점검 체크리스트, 접근 권한 정책
  ai-usage.md         # AI 도구 활용 기록 (AI 실수와 수정 포함)
docker-compose.yml
README.md
```

## 장애 훈련 시나리오 (포스트모템 작성 대상)
각 훈련은 **감지 → 알림 → 원인 분석 → 조치 → 재발 방지**를 문서로 남긴다.
1. 모의 포워더 실패율 50% → 재시도 폭증 감지
2. Claude API 타임아웃 → 검토 대기함 급증 감지, 폴백 동작 확인
3. 같은 부킹 중복 전송 → 멱등성으로 중복 저장 없음 확인
4. 잘못된 버전 배포 → 헬스체크 실패 → 자동 롤백
5. DB 데이터 손상 가정 → 백업에서 복구, 복구 소요시간 측정
6. 디스크 사용량 급증 → 알림 → 로그 정리 자동화

포스트모템 양식: 요약 / 영향 / 타임라인 / 감지 방법 / 근본 원인 / 조치 / 재발 방지 / 배운 점

## 단계별 목표

### 1단계 (1주차): 로컬에서 서비스 + 모니터링
- [ ] Go 개발 환경, booking-api `/healthz` 띄우기
- [ ] docker-compose: PostgreSQL + booking-api
- [ ] 부킹 파싱(Claude API, 타임아웃·폴백 포함) → 저장, 멱등성
- [ ] `/metrics` 노출, Prometheus + Grafana 로컬 연결, 기본 대시보드

### 2단계 (2주차): 장애 대응 체계 + CI → **이 단계 끝나면 지원**
- [ ] mock-forwarder + worker (재시도, 상태 역행 방지)
- [ ] Alertmanager 알림 규칙
- [ ] 장애 훈련 1~3번 + 포스트모템
- [ ] GitHub Actions CI (vet, test, 빌드)
- [ ] README 초안 + 구조도, GitHub 공개

### 3단계 (3주차): Azure 운영 환경
- [ ] Azure 예산 알림 설정
- [ ] Terraform으로 네트워크·VM·Storage·Key Vault 구축
- [ ] CD: GHCR → VM 배포 → 헬스체크 → 자동 롤백, OIDC 인증
- [ ] 백업·복구 스크립트 + cron, 복구 훈련(5번)
- [ ] 장애 훈련 4·6번, `security.md`, `runbook.md`
- [ ] README에 대시보드 스크린샷과 결과 정리

## 범위 줄이기 순서 (늦어질 때 뒤에서부터 뺀다)
1. 장애 훈련 6번
2. postgres_exporter / node_exporter (앱 지표만 유지)
3. Key Vault (GitHub Secrets로 대체)
4. OIDC (서비스 주체 비밀값으로 대체, 단 README에 개선 과제로 명시)

**절대 빼지 않는 것**: 모니터링 + 알림, 장애 훈련 1~3번과 포스트모템, CI/CD + 자동 롤백, Terraform 인프라.

## 완료 기준
README 하나로 다음을 보여줄 수 있다:
- Terraform으로 만든 Azure 인프라 구조도
- Grafana 대시보드에서 장애 주입 시 지표가 튀고 알림이 오는 화면
- 잘못된 배포가 자동 롤백되는 CI/CD 기록
- 장애 훈련별 포스트모템
- 백업 복구 훈련 결과