# AI 도구 활용 기록

이 프로젝트는 Claude Code를 보조 도구로 사용해 진행한다.
**AI가 틀리게 만든 부분과 고친 과정**을 빠짐없이 기록하는 것이 이 문서의 목적이다.

## 2026-10-17 — 1단계: Go 모듈 초기화 + `/healthz`

### 한 일
- `services/booking-api/go.mod` 생성 (`go mod init`)
- `main.go`: 표준 라이브러리만으로 HTTP 서버, `GET /healthz` → `{"status":"ok"}`
- `log/slog` JSON 로거를 기본 로거로 설정
- `http.Server`에 Read/Write/Idle 타임아웃 명시

### AI 실수와 수정
- **gofmt 미준수**: AI가 작성한 구조체 필드의 주석 정렬이 `gofmt` 기준과 달랐다.
  `gofmt -l .`로 감지 → `gofmt -w main.go`로 수정. 이후 CI에서 `gofmt -l` 결과가 비어 있지 않으면 실패시키는 규칙을 넣을 예정.
- **검증 스크립트 조건 오류**: `gofmt -l . && echo fmt-dirty`는 출력이 없어도(=정상) 성공 코드로 끝나 "fmt-dirty"를 찍었다.
  실제 상태는 정상이었고, 포맷 검사는 `test -z "$(gofmt -l .)"` 형태가 맞다.

### 검증 결과
- `GET /healthz` → 200, `{"status":"ok"}`
- `POST /healthz` → 405 (메서드 지정 라우팅 `"GET /healthz"` 동작 확인)
- 시작 로그가 한 줄 JSON으로 출력됨
