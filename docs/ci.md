# CI — GitHub Actions

파일: `.github/workflows/ci.yml` (의존성 자동 갱신: `.github/dependabot.yml`, 로컬 동일 검사: `Makefile`)

목적은 하나다. **깨진 커밋이 main 에, 그리고 3단계에서 서버에 올라가는 것을 사람 손 전에 기계가 막는다.**
CI 는 읽고 검사만 한다. 이미지 푸시·VM 배포·롤백은 3단계 `cd.yml` 에서 따로 만든다(4절).

## 1. 파이프라인 한눈에

```
트리거   pull_request (모든 브랜치의 PR)        push (main 브랜치만)
                      │                                 │
                      └───────────────┬─────────────────┘
                                      ▼   (PR 과 main push 에서 도는 내용은 완전히 같다)
        ┌─────────────────────────────┼─────────────────────────────────┐
        ▼                             ▼                                 ▼
  go (×3 매트릭스)              docker (×3 매트릭스)              monitoring-config (×1)
  booking-api / worker /        booking-api / worker /            compose 와 이미지 태그 일치 확인
  mock-forwarder                mock-forwarder                    promtool check config  ─┐ prom/prometheus:v3.5.0
  ───────────────               ───────────────                   promtool check rules   ─┘ (compose 와 같은 이미지)
  checkout                      checkout                          amtool check-config      prom/alertmanager:v0.28.1
  setup-go (go.mod 버전,        setup-buildx                      Grafana 대시보드 JSON 파싱 (jq)
            go.sum 키 캐시)     build-push-action                 Grafana 프로비저닝 YAML 파싱 (yq)
  gofmt (출력 비어야 통과)        push: false
  go vet                        캐시 type=gha, scope=서비스별
  go test -race -count=1
  go build
```

- 잡 3개(러너 7대)는 서로 `needs` 가 없어 **동시에** 돈다. 하나라도 빨간색이면 PR 체크가 실패한다.
- PR 과 main push 의 차이는 "언제" 뿐이다. PR 은 **병합 전 관문**, main push 는 **병합된 결과물** 확인.
- 밖으로 나가는 것(푸시·배포)이 없으므로 토큰 권한은 `contents: read` 하나로 끝난다.
- 예상 소요: 캐시 적중 시 2~3분, 첫 실행(캐시 없음) 5분 안팎. 실측은 첫 실행 후 README 에 적는다.

## 2. 워크플로 파일 한 줄씩

### 2.1 머리 — name / on / permissions / concurrency

```yaml
name: CI
```
Actions 탭과 PR 체크 목록에 보이는 이름. README 뱃지 URL(`.../actions/workflows/ci.yml/badge.svg`)은 파일명을 쓰므로 이름을 바꿔도 뱃지는 안 깨진다.

```yaml
on:
  pull_request:
  push:
    branches: [main]
```
- `pull_request:` 뒤에 값이 없다 = 기본 이벤트(opened / synchronize / reopened), 브랜치 필터 없음. **어디로 가는 PR 이든** 검사한다.
  PR 이벤트에서 checkout 이 받는 것은 내 브랜치가 아니라 **"내 브랜치 + 대상 브랜치를 합친 가상 커밋"**(`refs/pull/N/merge`)이다. 즉 "병합하면 어떻게 되는가" 를 검사한다.
- `push: branches: [main]` — main 에만. 모든 브랜치 push 에 걸면 PR 과 같은 커밋을 두 번 돌린다.
  main push 를 따로 두는 이유: (1) PR 없이 직접 push 된 커밋도 검사, (2) 3단계 CD 가 "main 에서 CI 성공" 을 배포 조건으로 삼는다.
- 빠지면: `pull_request` 만 있으면 병합 후 상태를 안 보고, `push` 만 있으면 병합 전에 못 막는다.

```yaml
permissions:
  contents: read
```
워크플로 전체의 `GITHUB_TOKEN` 권한. 적지 않으면 **저장소 설정의 기본값**을 따르는데, 오래된 저장소는 기본이 "read and write" 다.
이 워크플로는 코드를 읽고 검사만 하므로 읽기면 충분하다. 토큰이 새거나 악성 액션이 섞여도 코드 수정·릴리스·패키지 푸시가 **불가능**하다(최소 권한).
3단계 `cd.yml` 은 GHCR 푸시에 `packages: write`, Azure OIDC 에 `id-token: write` 가 필요하지만 **그 잡에만** 준다.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```
- `${{ }}` 는 Actions 표현식. `github.workflow` = "CI", `github.ref` = PR 이면 `refs/pull/N/merge`, main push 면 `refs/heads/main`.
  → 같은 워크플로 + 같은 브랜치가 한 그룹.
- `cancel-in-progress: true` — 같은 그룹에 새 실행이 오면 **돌고 있던 이전 실행을 취소**한다. 커밋을 연달아 push 하면 마지막 것만 의미가 있다.
- 빠지면: 오래된 커밋 검사까지 끝까지 돌아 러너 시간을 쓰고, 체크 결과가 어느 커밋 것인지 헷갈린다.
- 주의: **배포 워크플로에는 이 설정을 그대로 쓰면 안 된다.** 배포 도중 취소되면 반쯤 바뀐 상태가 남는다. 3단계에서는 `cancel-in-progress: false`(줄 세우기)로 둔다.

### 2.2 `go` 잡 — 포맷 → 정적 검사 → 테스트 → 빌드

```yaml
jobs:
  go:
    name: go (${{ matrix.service }})
    runs-on: ubuntu-24.04
    timeout-minutes: 10
```
- `jobs:` 아래 키 `go` / `docker` / `monitoring-config` 가 잡 ID. 다른 잡의 `needs:` 에서 이 ID 로 참조한다.
- `name:` 체크 목록에 `go (worker)` 처럼 보이게. 매트릭스 값이 이름에 들어가야 어느 서비스가 실패했는지 한눈에 보인다.
- `runs-on: ubuntu-24.04` — `ubuntu-latest` 가 아니라 **버전 고정**. latest 는 GitHub 이 어느 날 바꾸고(22.04→24.04 때 도구 버전이 다 바뀜) 그날 CI 가 이유 없이 빨개진다. 이 문서에 적은 러너 내장 도구(jq 1.7, yq 4.54.1, Docker 28, Python 3.12, gcc)는 이 이미지 기준이다.
- `timeout-minutes: 10` — **기본값은 360분**이다. 데드락 난 테스트 하나가 러너를 6시간 잡는 것을 막는다. 근거: setup-go + 캐시 복원 30초, vet/test/build 1~2분.

```yaml
    strategy:
      fail-fast: false
      matrix:
        service: [booking-api, worker, mock-forwarder]
```
- `matrix.service` — 같은 스텝을 서비스마다 **별도 러너에서 병렬로** 돌린다. 서비스마다 `go.mod` 가 따로라 어차피 디렉터리별로 실행해야 한다. 새 서비스는 이 배열에 한 줄.
- `fail-fast: false` — 기본값 `true` 는 하나가 실패하면 **나머지를 취소**한다. 셋 다 끝까지 돌려야 "worker 테스트 실패 + booking-api gofmt 실패" 를 한 번에 본다. 빠지면 한 번에 하나씩만 알게 되어 고치고-밀고를 반복한다.

```yaml
    defaults:
      run:
        working-directory: services/${{ matrix.service }}
```
- 이 잡의 **모든 `run` 스텝**의 작업 디렉터리. `go vet ./...` 는 그 디렉터리의 `go.mod` 를 찾아야 하므로 필수. 빠지면 루트에서 실행되어 `go: go.mod file not found`.
- 함정: **`uses` 스텝에는 적용되지 않는다.** 아래 `setup-go` 의 `with:` 경로는 저장소 루트 기준으로 따로 적는다.

```yaml
      - name: 소스 체크아웃
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```
러너는 빈 VM 이다. 저장소를 내려받아야 뭐든 할 수 있다. 기본 `fetch-depth: 1`(최신 커밋만) 이라 빠르다. `@<40자>` 는 커밋 SHA 고정 — 2.5절.

```yaml
      - name: Go 설치 + 모듈 캐시
        uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with:
          go-version-file: services/${{ matrix.service }}/go.mod
          cache-dependency-path: services/${{ matrix.service }}/go.sum
```
- `go-version-file` — `go.mod` 의 `go 1.27.2` 줄을 읽어 **그 버전**을 설치한다. 러너에 미리 깔린 Go 와 다를 수 있다. 버전을 워크플로에 또 적으면 두 곳을 관리하게 된다(Dockerfile 의 `golang:1.27-alpine` 까지 세 곳 — 이건 Dependabot `docker` 생태계로 묶는 게 개선 과제).
- `cache-dependency-path` — 모듈 캐시(`GOMODCACHE`)와 빌드 캐시(`GOCACHE`)를 **이 파일의 해시**를 키로 저장/복원한다. `go.sum` 이 안 바뀌면 다운로드·재컴파일을 건너뛴다. 기본값은 루트의 `go.sum` 을 찾는데 루트에는 없으므로 지정하지 않으면 "캐시 못 찾음" 경고와 함께 매번 받는다. 캐싱 자체(`cache: true`)는 기본값.
- 두 경로 모두 **루트 기준**인 이유: `with:` 는 `working-directory` 의 영향을 받지 않는다(위 함정).

```yaml
      - name: gofmt
        run: |
          unformatted="$(gofmt -l .)"
          test -z "$unformatted" || {
            echo "::error::gofmt 미준수 파일 — 로컬에서 'make fmt' 후 다시 커밋하세요"
            echo "$unformatted"
            gofmt -d .
            exit 1
          }
```
- `gofmt -l .` 은 고쳐야 할 파일 **이름만 출력하고 종료 코드는 언제나 0** 이다. 그래서 "출력이 비었는가"(`test -z`)로 판정한다. 이 프로젝트에서 `gofmt -l . && echo fmt-dirty` 로 잘못 판정한 적이 있다(`docs/ai-usage.md` 10-17).
- 실패하면 (1) `::error::` — GitHub **워크플로 명령**. 로그에 빨간 줄로 찍히고 PR 의 Files/Checks 탭에 annotation 으로 뜬다. (2) 파일 목록, (3) `gofmt -d .` 로 **고쳐야 할 diff** 까지 로그에 남긴다 — 로그만 보고 뭘 고칠지 안다. (4) `exit 1` 로 스텝 실패.
- `run: |` — YAML 블록 스칼라(여러 줄 그대로). 기본 셸은 `bash -e`: 한 줄이 실패하면 거기서 멈춘다.
- 실제로 이 CI 를 만들며 로컬 검사에서 `services/worker/main.go` 가 걸렸다(주석 정렬 2줄). 이전 작업의 "gofmt 고정 절차" 를 사람이 빠뜨린 것 — CI 가 있어야 하는 이유 그 자체.

```yaml
      - name: go vet
        run: go vet ./...
```
컴파일은 되지만 의심스러운 코드를 잡는다: Printf 인자 수 불일치, 쓰지 않는 결과값, 구조체 복사된 락, 도달 불가 코드 등. 이 프로젝트에서 안 쓰는 import 를 vet 이 잡은 적이 있다(`docs/ai-usage.md` 10-17). `./...` = 현재 디렉터리 아래 모든 패키지.

```yaml
      - name: go test
        run: go test -race -count=1 ./...
```
- `-race` — **데이터 경쟁 감지기**를 켜고 테스트. worker 는 폴러 1 + 처리기 4 goroutine 이 channel/atomic 으로 통신하므로 꼭 필요하다. CGO(C 컴파일러)가 필요하고 러너에는 gcc 가 있다. 2~10배 느려지지만 테스트가 작다. 로컬 WSL 에도 gcc 가 있어 같은 명령이 돈다.
- `-count=1` — **테스트 캐시 무시**. Go 는 코드·입력이 같으면 결과를 캐시해 `ok (cached)` 로 건너뛴다. CI 에서는 항상 실제로 돌린다.
- `[no test files]` 는 실패가 아니다. booking-api 와 mock-forwarder 는 아직 테스트가 없다(4절 개선 과제). 현재 테스트는 worker 의 상태 전이 표(`store_test.go`)뿐.

```yaml
      - name: go build
        run: go build ./...
```
테스트 없는 패키지도 **끝까지 컴파일·링크**되는지. vet 은 타입 검사까지만 한다. 각 서비스가 `main` 패키지 하나라 바이너리가 그 디렉터리에 생기지만 러너는 끝나면 버려진다. 로컬에서는 `.gitignore` 에 있고 `make clean` 으로 지운다.

### 2.3 `docker` 잡 — Dockerfile 이 실제로 빌드되는가

```yaml
  docker:
    name: docker (${{ matrix.service }})
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        service: [booking-api, worker, mock-forwarder]
```
go 잡과 같은 매트릭스. 타임아웃이 15분인 이유: 캐시가 없으면 `golang:1.27-alpine` 풀 + `go mod download` + 컴파일까지 2~3분/서비스가 걸린다.

**go 잡과 겹치지 않나?** Dockerfile 안에서도 `go build` 가 돈다. 그래도 둘 다 두는 이유 — go 잡은 **코드**를, docker 잡은 **Dockerfile·.dockerignore·베이스 이미지**를 검증한다. `COPY --from=builder` 경로 실수(`docs/ai-usage.md` 10-18 의 복제 실수)는 docker 잡만 잡는다. `needs: go` 를 안 건 이유: 독립이라 병렬이 빠르고 결과를 한 번에 본다. 러너 시간이 아까우면 `needs: go` 한 줄로 직렬화할 수 있다.

```yaml
      - name: Buildx 준비
        uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
```
러너의 기본 `docker build`(docker 드라이버)는 아래 `type=gha` 캐시를 **지원하지 않는다**. buildx 가 `docker-container` 드라이버의 BuildKit 빌더를 띄운다. 멀티스테이지 캐시도 BuildKit 이 다룬다. 입력 없이 기본값으로 충분하다.

```yaml
      - name: 이미지 빌드
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: services/${{ matrix.service }}
          push: false
          tags: ${{ matrix.service }}:ci
          cache-from: type=gha,scope=${{ matrix.service }}
          cache-to: type=gha,mode=max,scope=${{ matrix.service }}
```
- `context` — 빌드 컨텍스트 = Dockerfile 위치(`file` 생략 시 `<context>/Dockerfile`). 그 디렉터리의 `.dockerignore` 가 적용된다.
- `push: false` — 레지스트리에 올리지 않는다. CI 는 "빌드되는가" 만 본다. (`load` 도 기본 false 라 러너의 `docker images` 에도 안 나타난다. 결과는 캐시와 메타데이터뿐.)
- `tags: <svc>:ci` — 푸시하지 않으니 기록용 이름. 로컬 `make docker-build` 도 같은 태그를 쓴다. 3단계에서 `ghcr.io/<owner>/<svc>:<커밋 SHA>` 로 바뀐다.
- `cache-from: type=gha,...` — **GitHub Actions 캐시 서비스**에서 레이어를 복원. `cache-to: type=gha,mode=max,...` — 저장.
  - `mode=max` — 중간 스테이지(builder 의 `go mod download` 레이어, 수백 MB)까지 저장. 기본 `min` 은 **최종 이미지 레이어만** 저장하는데, 우리 최종 이미지는 바이너리 하나라 min 은 거의 쓸모없다.
  - `scope=<서비스>` — 캐시 키 네임스페이스. **기본값은 워크플로 공통 `buildkit`** 이라 세 매트릭스가 서로의 캐시를 덮어쓴다. 빠지면 캐시가 매번 미스 난다.
  - 캐시 한도는 저장소당 10GB, 오래된 것부터 지워진다. 브랜치 격리: PR 에서 만든 캐시는 그 PR 과 기본 브랜치만, **main 에서 만든 캐시는 모두가** 읽는다 → main 이 캐시를 데워 두면 PR 이 빠르다.
  - 3단계 CD 가 같은 `scope` 로 `cache-from` 하면 **CI 가 만든 레이어를 그대로 재사용**해 푸시만 하면 된다.
- 토큰 권한: gha 캐시는 러너의 `ACTIONS_RUNTIME_TOKEN` 을 쓰므로 `contents: read` 로도 동작한다.

### 2.4 `monitoring-config` 잡 — 설정 파일 문법 검사

```yaml
  monitoring-config:
    name: monitoring-config
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    env:
      PROMETHEUS_IMAGE: prom/prometheus:v3.5.0
      ALERTMANAGER_IMAGE: prom/alertmanager:v0.28.1
```
- 매트릭스 없음(파일 몇 개). `env:` 는 잡 수준 환경변수 — 모든 `run` 에서 `$PROMETHEUS_IMAGE` 로 쓴다. 태그를 한 곳에만 적기 위해.
- **왜 compose 와 같은 태그인가**: `promtool` 은 Prometheus 버전마다 받아들이는 설정이 다르다(예: v3 에서 바뀐 UTF-8 매처). "실제로 돌릴 바로 그 버전의 검사기" 로 검사해야 통과가 의미 있다.

```yaml
      - name: compose 와 이미지 태그가 같은지 확인
        run: |
          grep -q "image: $PROMETHEUS_IMAGE" docker-compose.yml || { echo "::error::PROMETHEUS_IMAGE 가 docker-compose.yml 과 다릅니다"; exit 1; }
          grep -q "image: $ALERTMANAGER_IMAGE" docker-compose.yml || { echo "::error::ALERTMANAGER_IMAGE 가 docker-compose.yml 과 다릅니다"; exit 1; }
```
위 `env` 와 `docker-compose.yml` 의 태그가 **조용히 어긋나는 것**을 막는다. compose 만 올리면 여기서 빨개져 둘을 같이 올리게 된다. `grep -q` 는 찾으면 0, 못 찾으면 1 — `||` 뒤가 실행된다.

```yaml
      - name: promtool check config
        run: >
          docker run --rm -v "$PWD/infra/monitoring:/etc/prometheus:ro"
          --entrypoint promtool "$PROMETHEUS_IMAGE"
          check config /etc/prometheus/prometheus.yml
```
- `run: >` — 접힌 블록 스칼라. 줄바꿈이 공백으로 합쳐져 **한 줄 명령**이 된다(읽기 좋게 나눈 것뿐).
- `docker run --rm` — 끝나면 컨테이너 삭제. `-v "$PWD/infra/monitoring:/etc/prometheus:ro"` — 저장소의 설정 디렉터리를 **읽기 전용**으로, **compose 가 쓰는 것과 같은 컨테이너 경로**에 마운트. `$PWD` 는 러너의 체크아웃 디렉터리.
- `--entrypoint promtool` — 이미지의 기본 ENTRYPOINT 는 Prometheus **서버**다. 검사 도구로 바꾼다.
- `check config` 가 하는 일: YAML/필드 검사, `scrape_configs` 검사, **`rule_files` 가 가리키는 파일이 있는지 + 그 규칙(PromQL) 검사**, 중복 규칙 lint.
- **왜 `/cfg` 가 아니라 `/etc/prometheus` 인가**: `prometheus.yml` 의 `rule_files` 가 절대 경로 `/etc/prometheus/alert-rules.yml` 이다. 처음에 `/cfg` 에 마운트했더니 실제로 이렇게 실패했다:
  `FAILED: "/etc/prometheus/alert-rules.yml" does not point to an existing file`.
  compose 와 같은 경로에 두면 "운영에서 읽는 경로 그대로" 검사하게 되어 오히려 더 정확하다.

```yaml
      - name: promtool check rules
        run: >
          docker run --rm -v "$PWD/infra/monitoring:/etc/prometheus:ro"
          --entrypoint promtool "$PROMETHEUS_IMAGE"
          check rules /etc/prometheus/alert-rules.yml
```
`check config` 가 규칙까지 보지만 따로 두는 이유: 실패했을 때 **어느 스텝이 빨간지**로 "서버 설정 문제" 와 "규칙 문제" 가 바로 갈린다. 규칙만 고친 PR 에서 로그 읽기도 쉽다. 통과 출력은 `SUCCESS: 11 rules found`(2026-10-22 기준 규칙 11개).

```yaml
      - name: amtool check-config
        run: >
          docker run --rm -v "$PWD/infra/monitoring/alertmanager:/etc/alertmanager:ro"
          --entrypoint amtool "$ALERTMANAGER_IMAGE"
          check-config /etc/alertmanager/alertmanager.yml
```
- 같은 패턴. 라우트·수신자·억제 규칙·템플릿 문법을 검사한다. 통과 출력: `4 inhibit rules, 2 receivers`.
- **`webhook_url_file` 문제와 선택**: 설정은 Discord 웹훅 URL 을 `/run/secrets/discord_webhook` 파일에서 읽는다(compose secret). CI 컨테이너에는 그 파일이 없다. 가짜 파일을 만들어야 하나 확인하려고 **파일 없이** 돌려 봤더니 `SUCCESS` 였다. Alertmanager 는 `*_file` 값을 설정을 **로드할 때가 아니라 수신자가 실제로 발송할 때** 읽기 때문에 `check-config` 는 구조만 본다.
  그래서 **가짜 파일을 만들지 않았다.** 만들면 "실제 설정이 비밀 파일 없이도 로드된다" 는 사실 자체를 가리고, 검사 명령도 운영 설정과 달라진다.
  한계: 파일 **경로 오타**(예: `discord_webhok`)는 CI 가 못 잡는다. 그건 기동 로그와 `alertmanager_notifications_failed_total` 지표, 3단계 `healthcheck.sh` 가 잡는다.

```yaml
      - name: Grafana 대시보드 JSON 파싱
        run: |
          for f in infra/monitoring/grafana/dashboards/*.json; do
            echo "check $f"
            jq empty "$f"
          done
```
- `jq empty` — 파싱만 하고 아무것도 출력하지 않는다. 깨진 JSON 이면 `parse error: ... at line N` 과 함께 종료 코드 ≠ 0. 패널 구조(데이터소스 uid 등)는 검사하지 않는다 — 4절 개선 과제.
- **반복문 안에서 실패할 명령을 단독 줄에 둔 이유**: `jq empty "$f" && echo ok` 처럼 쓰면 `bash -e` 는 `&&` 왼쪽의 실패를 **무시**한다(목록의 마지막 명령만 본다). 깨진 파일이 통과해 버린다. 이 프로젝트가 10-17 에 똑같이 밟은 함정(`gofmt -l . && echo fmt-dirty`)이라 echo 를 앞줄로 뺐다. 로컬에서 일부러 깨진 JSON 으로 돌려 실패(exit 1)하는 것을 확인했다.

```yaml
      - name: Grafana 프로비저닝 YAML 파싱
        run: |
          for f in infra/monitoring/grafana/provisioning/*/*.yml; do
            echo "check $f"
            yq . "$f" > /dev/null
          done
```
`yq`(mikefarah v4, 러너 이미지 내장)로 파싱만 하고 출력은 버린다. 깨지면 종료 코드 ≠ 0. 러너에 PyYAML 이 있다는 근거를 찾지 못해 python 대신 yq 를 썼다(러너 이미지 문서에 jq 1.7, yq 4.54.1 이 명시돼 있다). 로컬 WSL 에는 yq 가 없어 Makefile 은 python3+PyYAML 로 폴백한다(3절).

### 2.5 액션을 커밋 SHA 로 고정한 이유와 방법

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```
- `@v7` 같은 **태그는 움직일 수 있다.** 태그를 지우고 다른 커밋에 다시 붙이면 내 워크플로가 모르는 코드를 실행한다. 2025년 3월 `tj-actions/changed-files` 사건이 정확히 이것 — 태그가 악성 커밋으로 바뀌어 수많은 저장소의 CI 비밀값이 로그로 유출됐다.
- **커밋 SHA 는 내용의 해시**라 바꿀 수 없다. 뒤의 `# v7.0.1` 주석은 사람이 읽기 위한 것이고, Dependabot 도 이 주석을 보고 "새 버전 → 새 SHA" PR 을 만든다.
- 대가: 자동으로 올라가지 않는다. 그래서 `dependabot.yml`(2.6절)로 갱신 PR 을 받는다.
- **SHA 를 어떻게 구했나** (두 방법으로 교차 확인, 전부 일치):
  ```
  gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq '.object.type + " " + .object.sha'   # commit 3d3c42e5...
  gh api repos/actions/checkout/commits/v7.0.1 --jq .sha                                        # 3d3c42e5...
  ```
  `git/ref/tags` 의 `object.type` 이 `tag`(annotated tag)면 `git/tags/<sha>` 로 한 번 더 따라가야 커밋 SHA 가 나온다. 이번 4개는 모두 `commit`(lightweight tag)이었다.
  액션의 입력 이름(`go-version-file`, `cache-dependency-path`, `context`, `cache-to` …)도 해당 태그의 `action.yml` 을 받아 확인했다.

| 액션 | 태그 | 커밋 SHA |
|---|---|---|
| actions/checkout | v7.0.1 (2026-07-20) | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-go | v7.0.0 (2026-07-16) | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` |
| docker/setup-buildx-action | v4.4.1 (2026-09-16) | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| docker/build-push-action | v7.4.0 (2026-09-15) | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |

같은 원칙이 Docker 이미지에도 적용된다: compose 와 CI 가 `prom/prometheus:v3.5.0` 처럼 **버전 태그**를 쓰고 `latest` 를 쓰지 않는다(다음 단계: digest 고정).

### 2.6 `dependabot.yml` 한 줄씩

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: friday
      timezone: Asia/Seoul
  - package-ecosystem: gomod
    directories:
      - /services/booking-api
      - /services/worker
      - /services/mock-forwarder
    schedule:
      interval: weekly
      day: friday
      timezone: Asia/Seoul
```
- `version: 2` — 설정 형식 버전(현재 유일).
- `package-ecosystem: github-actions`, `directory: /` — `.github/workflows/` 의 `uses:` 를 본다. SHA 핀이면 **새 릴리스의 SHA 로 바꾸고 `# vX.Y.Z` 주석도 갱신**한 PR 을 연다.
- `package-ecosystem: gomod`, `directories: [...]` — `go.mod` 가 서비스마다 따로라 셋을 모두 지정. 각 디렉터리에서 `go get -u` 에 해당하는 PR.
- `schedule` — 주 1회, **금요일(서울 시각)**. 작업 요일이 금~일이라 그 주에 바로 처리할 수 있게.
- PR 이 오면 할 일: CI 가 초록인지 확인 → 변경 내용(릴리스 노트) 한 번 읽기 → 병합. Dependabot PR 도 이 CI 를 그대로 통과해야 한다.

## 3. 로컬에서 같은 검사 돌리기, 실패 읽기

### 3.1 Makefile

```
make check              # CI 전체와 같은 순서: fmt-check vet test build docker-build check-monitoring
make fmt                # gofmt -w 로 고친다 (CI 는 고치지 않고 실패만 시킨다)
make fmt-check          # gofmt -l 이 비어 있어야 통과
make vet / test / build # 서비스 3개를 순서대로
make docker-build       # docker build -t <svc>:ci services/<svc> ×3
make check-monitoring   # promtool / amtool / 대시보드 JSON / 프로비저닝 YAML
make clean              # go build 가 남긴 바이너리 삭제
```

- 세 서비스를 `SERVICES` 변수로 한 번에 돈다. 새 서비스는 Makefile 과 ci.yml 의 매트릭스 **두 곳**에 추가한다.
- `DOCKER ?= docker` — `?=` 는 "명령줄/환경에서 안 줬을 때만" 기본값. docker 가 Windows 쪽에만 있는 WSL 이라면:
  ```
  make check DOCKER=docker.exe MOUNT_ROOT="$(wslpath -w .)"
  ```
  `docker.exe` 는 Windows 프로세스라 **리눅스 경로(`/home/...`)를 마운트하면 빈 디렉터리가 붙는다**(에러 없이!). `wslpath -w` 로 `\\wsl.localhost\Ubuntu\home\...` 형식으로 바꿔 넘긴다. Makefile 이 마운트 인자를 작은따옴표로 감싼 이유도 이것 — 큰따옴표 안에서는 셸이 `\\` 를 `\` 로 줄여 "not a valid Windows path" 가 난다(이번 작업에서 실제로 한 번 틀렸다).
  참고: 2026-10-22 현재 이 WSL 의 `/usr/bin/docker` 도 Docker Desktop 데몬에 붙어 있어 **기본값 `make check` 로도 동작**함을 확인했다. 두 방식 모두 통과.
- `JSON_CHECK` / `YAML_CHECK` — `jq` / `yq` 가 있으면 CI 와 같은 명령, 없으면 python3 로 파싱만 한다. 판정 기준("문법이 맞는가")은 같다.
- 모든 반복문이 `set -e` 로 시작한다 — 한 서비스가 실패하면 거기서 멈추고 make 가 실패한다.

### 3.2 CI 와 로컬의 차이 (알고 쓰면 되는 것)

| 항목 | CI | 로컬 Makefile |
|---|---|---|
| Go 버전 | go.mod 의 1.27.2 를 setup-go 가 설치 | PATH 의 go (현재 1.27.2) |
| 이미지 빌드 | buildx + `type=gha` 캐시, 이미지는 로드 안 함 | 일반 `docker build`, 로컬 이미지 `<svc>:ci` 생성 |
| JSON / YAML 파싱 | jq / yq | jq / yq 있으면 동일, 없으면 python3 |
| `-race` | gcc 내장 | gcc 필요 (이 WSL 에 있음) |
| 바이너리 | 러너와 함께 사라짐 | `services/<svc>/<svc>` 에 남음 → `make clean` |

### 3.3 실패한 실행 읽는 법

1. PR 의 Checks 또는 저장소 Actions 탭 → 빨간 워크플로 → **잡 이름에 서비스가 있다**: `go (worker)` 면 worker 의 Go 검사.
2. 잡을 열면 스텝 목록. 빨간 스텝 하나를 펼친다. `::error::` 로 찍은 줄은 PR Files 탭에도 annotation 으로 보인다.
3. 스텝별로 볼 곳:

| 빨간 스텝 | 로그에서 찾을 것 | 고치는 법 |
|---|---|---|
| gofmt | 파일 목록 + `gofmt -d` diff | `make fmt` 후 커밋 |
| go vet | `파일.go:줄:열: 메시지` | 메시지 그대로 (unused import, Printf 인자 등) |
| go test | `--- FAIL: Test이름`, `-race` 면 `WARNING: DATA RACE` 와 **스택 2개**(쓴 곳 / 읽은 곳) | 로컬 `make test` 로 재현. 경쟁은 두 스택이 가리키는 변수에 락/atomic |
| go build | 컴파일 에러 `파일.go:줄` | 그 줄 |
| 이미지 빌드 | `#N ERROR` 가 붙은 Dockerfile 단계(`[builder 4/5] RUN go build …`) | 그 단계의 명령을 로컬 `make docker-build` 로 재현 |
| compose 와 태그 확인 | `PROMETHEUS_IMAGE 가 docker-compose.yml 과 다릅니다` | ci.yml `env` 와 compose 태그를 같이 올린다 |
| promtool check config | `FAILED: ...` + 필드명 또는 `rule file 없음` | 메시지의 필드/경로 |
| promtool check rules | `파일:줄 그룹 "worker", 규칙 N, "이름": 메시지` | 보통 PromQL 괄호·라벨 매처 오타 |
| amtool check-config | `yaml: line N` 또는 필드명(`unknown field`, `missing receiver`) | 그 줄 |
| JSON / YAML 파싱 | `check <파일>` 다음 줄의 `parse error ... line N` | 그 줄 |
| 잡 전체가 회색/취소 | `canceled` — concurrency 로 새 커밋이 와서 취소됨 | 실패 아님. 최신 실행을 본다 |
| `exceeded the maximum execution time` | timeout-minutes 초과 | 어느 스텝에서 멈췄는지 보고 데드락/네트워크 의심 |

4. 고친 뒤 push 하면 같은 브랜치의 이전 실행은 자동 취소된다. 러너 쪽 문제(네트워크 등)가 의심되면 "Re-run failed jobs".

### 3.4 2026-10-22 로컬 검증 기록

| 검사 | 결과 |
|---|---|
| `make fmt-check vet test build` | 통과 (worker `ok 1.02s`, 나머지 `[no test files]`). `make clean` 후 바이너리 없음 |
| `make docker-build DOCKER=docker.exe` | booking-api:ci 31.3MB / worker:ci 25.4MB / mock-forwarder:ci 19.4MB (운영 중 `:local` 과 동일) |
| `make check-monitoring` (WSL docker) 와 `DOCKER=docker.exe MOUNT_ROOT=…` | 둘 다 통과: config SUCCESS, 11 rules, amtool 4 inhibit / 2 receivers, JSON 1, YAML 2 |
| CI 의 `run` 스크립트를 `bash -e` 로 그대로 실행 | 통과. 깨진 JSON 을 넣은 음성 테스트는 exit 1 |
| actionlint 1.7.12 (shellcheck 포함) | 문제 0건 (stdin 방식, 바인드 마운트 방식 모두) |

## 4. 아직 CI 에 없는 것, 개선 과제

### 4.1 의도적으로 뺀 것 — 3단계 `cd.yml`

| 항목 | 왜 CI 에 없나 |
|---|---|
| GHCR 이미지 푸시 (`ghcr.io/<owner>/<svc>:<commit sha>`) | `packages: write` 권한이 필요. 검사 워크플로와 권한을 분리한다. main 에서 CI 성공 후에만 |
| VM 배포 (`docker compose pull && up -d`) | SSH 키/Azure 접근이 필요. PR 에서 돌면 안 된다 |
| `/healthz` 확인 → 실패 시 이전 태그로 롤백 | 배포와 한 몸. `concurrency.cancel-in-progress: false` 로 |
| Azure OIDC 인증 (`id-token: write`) | 장기 비밀키 대신. 배포 잡에만 |

CD 는 이 CI 의 `type=gha` 캐시를 같은 `scope` 로 읽어 **CI 가 만든 레이어를 재빌드 없이 푸시**하는 구조로 간다.

### 4.2 개선 후보 (효과 큰 순)

1. **테스트 없는 서비스에 테스트** — booking-api(멱등 저장, 파싱 폴백 분류), mock-forwarder(장애 주입 확률). 지금 `-race` 는 worker 에만 의미가 있다.
2. **`govulncheck`** — Go 공식 취약점 DB 로 실제 호출되는 취약 함수만 보고. `go install golang.org/x/vuln/cmd/govulncheck@<버전>` 후 서비스별 실행.
3. **`go mod tidy` 검사** — `go mod tidy && git diff --exit-code go.mod go.sum`. 불필요한 의존성이 go.sum 에 남는 것 방지. `go mod verify` 로 캐시된 모듈 해시 확인도.
4. **hadolint** — Dockerfile 린터(`ghcr.io/hadolint/hadolint`). 핀 안 된 베이스 이미지, `latest`, 불필요한 레이어 경고.
5. **actionlint 를 CI 에** — 지금은 로컬에서만 돌렸다. `.github/workflows/*.yml` 이 바뀔 때 워크플로 자체를 검사.
6. **대시보드 내용 검사** — `jq -e '.panels[].datasource.uid == "prometheus"'` 처럼 데이터소스 uid 가 프로비저닝과 맞는지. 지금은 "JSON 문법" 만 본다.
7. **`docker compose config`** — compose 파일 문법·변수 치환 검사. `.env` 없이 돌리려면 `--env-file .env.example`.
8. **이미지 스모크 테스트** — `load: true` 로 러너에 올린 뒤 mock-forwarder 를 띄워 `/healthz` 200 확인(DB 없이 되는 유일한 서비스).
9. **Dependabot `docker` 생태계** — `golang:1.27-alpine`, `distroless`, compose 의 Prometheus/Grafana 태그 갱신 PR. 현재 go.mod·Dockerfile·setup-go 의 Go 버전이 세 곳이다.
10. **golangci-lint** — vet 보다 넓은 린트 묶음(errcheck, staticcheck 등). 처음 켜면 지적이 많아 단계적으로.
11. **베이스 이미지 digest 고정** — `golang:1.27-alpine@sha256:…`. 태그보다 한 단계 더 재현성.

### 4.3 메모

- PyYAML 로 `ci.yml` 을 읽으면 `on` 키가 `True` 로 나온다(YAML 1.1 의 `on/off` 불리언). GitHub 은 문자열로 읽으므로 문제 없다. 워크플로의 정식 검사기는 actionlint 다.
- 러너 내장 도구 목록 근거: `actions/runner-images` 저장소의 `images/ubuntu/Ubuntu2404-Readme.md`(2026-10-22 조회: jq 1.7, yq 4.54.1, Docker 28.0.4, Buildx 0.38.0, Python 3.12.3, Go 는 setup-go 로 별도 설치).
