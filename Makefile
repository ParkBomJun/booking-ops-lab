# 로컬에서 CI(.github/workflows/ci.yml)와 같은 검사를 돌린다.      전체: make check
# 개별: make fmt-check / vet / test / build / docker-build / check-monitoring     고치기: make fmt
#
# docker 가 Windows 쪽(docker.exe)에만 있는 WSL 이라면 두 변수를 넘긴다.
# docker.exe 는 리눅스 경로(/home/...)를 마운트하지 못해(빈 디렉터리가 마운트됨) 저장소 경로를 Windows 형식으로 바꿔 줘야 한다.
#   make check DOCKER=docker.exe MOUNT_ROOT="$(wslpath -w .)"

SERVICES   := booking-api worker mock-forwarder
DOCKER     ?= docker
MOUNT_ROOT ?= $(CURDIR)

# docker-compose.yml 과 같은 태그를 유지한다. 다르면 check-monitoring 이 실패시킨다.
PROMETHEUS_IMAGE   := prom/prometheus:v3.5.0
ALERTMANAGER_IMAGE := prom/alertmanager:v0.28.1

# CI 러너에는 jq / yq 가 있고 이 WSL 에는 없다. 없으면 python3 로 대신 파싱한다. 둘 다 "문법이 맞는가" 만 본다.
PY_JSON    := python3 -c 'import sys, json; json.load(open(sys.argv[1]))'
PY_YAML    := python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))'
JSON_CHECK := $(if $(shell command -v jq 2>/dev/null),jq empty,$(PY_JSON))
YAML_CHECK := $(if $(shell command -v yq 2>/dev/null),yq .,$(PY_YAML))

.PHONY: check fmt fmt-check vet test build docker-build check-monitoring clean

# CI 와 같은 검사 전부. 순서는 빠른 것부터.
check: fmt-check vet test build docker-build check-monitoring

# gofmt 로 고친다 (CI 는 고치지 않고 실패만 시킨다)
fmt:
	@for s in $(SERVICES); do echo "== gofmt -w   $$s"; (cd services/$$s && gofmt -w .); done

# gofmt -l 출력이 비어 있어야 통과. CI 의 gofmt 스텝과 같은 판정.
fmt-check:
	@set -e; for s in $(SERVICES); do \
	  echo "== gofmt -l   $$s"; \
	  unformatted="$$(cd services/$$s && gofmt -l .)"; \
	  test -z "$$unformatted" || { echo "gofmt 미준수: $$unformatted  -> make fmt"; exit 1; }; \
	done

vet:
	@set -e; for s in $(SERVICES); do echo "== go vet     $$s"; (cd services/$$s && go vet ./...); done

test:
	@set -e; for s in $(SERVICES); do echo "== go test    $$s"; (cd services/$$s && go test -race -count=1 ./...); done

# 바이너리는 services/<svc>/<svc> 에 생긴다 (.gitignore 대상). make clean 으로 지운다.
build:
	@set -e; for s in $(SERVICES); do echo "== go build   $$s"; (cd services/$$s && go build ./...); done

# Dockerfile 이 빌드되는지만 본다. 태그 <svc>:ci 는 CI 와 같다.
docker-build:
	@set -e; for s in $(SERVICES); do echo "== docker build $$s"; $(DOCKER) build -t $$s:ci services/$$s; done

# promtool / amtool 은 compose 와 같은 이미지·같은 컨테이너 경로로 돌린다. 이어서 Grafana JSON / YAML 파싱.
# 마운트 경로는 작은따옴표: MOUNT_ROOT 가 Windows 경로(\\wsl.localhost\...)일 때 큰따옴표 안에서는 셸이 \\ 를 \ 로 줄여 버린다.
check-monitoring:
	@grep -q "image: $(PROMETHEUS_IMAGE)" docker-compose.yml || { echo "PROMETHEUS_IMAGE 가 docker-compose.yml 과 다름"; exit 1; }
	@grep -q "image: $(ALERTMANAGER_IMAGE)" docker-compose.yml || { echo "ALERTMANAGER_IMAGE 가 docker-compose.yml 과 다름"; exit 1; }
	$(DOCKER) run --rm -v '$(MOUNT_ROOT)/infra/monitoring:/etc/prometheus:ro' --entrypoint promtool $(PROMETHEUS_IMAGE) check config /etc/prometheus/prometheus.yml
	$(DOCKER) run --rm -v '$(MOUNT_ROOT)/infra/monitoring:/etc/prometheus:ro' --entrypoint promtool $(PROMETHEUS_IMAGE) check rules /etc/prometheus/alert-rules.yml
	$(DOCKER) run --rm -v '$(MOUNT_ROOT)/infra/monitoring/alertmanager:/etc/alertmanager:ro' --entrypoint amtool $(ALERTMANAGER_IMAGE) check-config /etc/alertmanager/alertmanager.yml
	@set -e; for f in infra/monitoring/grafana/dashboards/*.json; do echo "== json $$f"; $(JSON_CHECK) $$f > /dev/null; done
	@set -e; for f in infra/monitoring/grafana/provisioning/*/*.yml; do echo "== yaml $$f"; $(YAML_CHECK) $$f > /dev/null; done

# go build 가 남긴 바이너리 제거
clean:
	@for s in $(SERVICES); do rm -f services/$$s/$$s; done
