# ---------- 1단계: 빌드 ----------
# 멀티스테이지 빌드. 컴파일러가 든 큰 이미지에서 빌드만 하고,
# 결과 바이너리만 작은 이미지로 옮긴다. 최종 이미지 크기와 공격 표면이 줄어든다.
FROM golang:1.27-alpine AS builder

WORKDIR /src

# go.mod / go.sum 을 먼저 복사해 의존성만 받는다.
# 소스가 바뀌어도 이 레이어는 캐시되므로 재빌드가 빨라진다.
COPY go.mod go.sum ./
RUN go mod download

# 나머지 소스 복사 후 빌드.
# CGO_ENABLED=0 : C 라이브러리 의존 없는 정적 바이너리 -> 어떤 리눅스 이미지에서도 실행 가능
# -trimpath     : 바이너리에 빌드 머신의 경로가 남지 않게 한다
# -ldflags "-s -w" : 디버그 심볼 제거로 크기 축소
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mock-forwarder .

# ---------- 2단계: 실행 ----------
# distroless/static: 셸도 패키지 매니저도 없는 최소 이미지. 침입해도 할 수 있는 게 거의 없다.
# nonroot 태그: 기본 사용자가 root 가 아니다 (최소 권한 원칙).
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/mock-forwarder /mock-forwarder

# 문서용 선언. 실제 포트 공개는 compose 의 ports 가 한다.
EXPOSE 8082

# ENTRYPOINT 는 컨테이너 시작 시 실행할 명령.
# 셸이 없는 이미지이므로 반드시 JSON 배열(exec) 형식으로 쓴다.
ENTRYPOINT ["/mock-forwarder"]
