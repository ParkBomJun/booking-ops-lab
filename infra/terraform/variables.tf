# 입력 변수. 값은 terraform.tfvars(커밋 안 함) 에 적는다. 예시는 terraform.tfvars.example.
# 모든 변수에 validation 을 둔 이유: 잘못된 값은 apply 중간(리소스 절반 생성 후)이 아니라 plan 단계에서 걸려야 한다.

variable "subscription_id" {
  description = "리소스를 만들 Azure 구독 ID. azurerm 4.x 는 provider 블록에 구독을 명시해야 한다."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id 는 소문자 UUID 형식이어야 한다. 예: 00000000-0000-0000-0000-000000000000"
  }
}

variable "location" {
  description = "Azure 리전. 한국 사용자는 지연시간이 가장 짧은 koreacentral."
  type        = string
  default     = "koreacentral"
  validation {
    condition     = can(regex("^[a-z]+$", var.location))
    error_message = "location 은 공백 없는 소문자 리전 이름이어야 한다. 예: koreacentral"
  }
}

variable "project" {
  description = "리소스 이름 접두사에 들어가는 프로젝트 이름. Storage 계정 이름에도 쓰이므로 소문자·숫자만."
  type        = string
  default     = "bookingops"
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project))
    error_message = "project 는 소문자·숫자 3~12자."
  }
}

variable "environment" {
  description = "환경 이름(lab, dev 등). 이름 접두사와 태그에 쓴다."
  type        = string
  default     = "lab"
  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.environment))
    error_message = "environment 는 소문자·숫자 2~8자."
  }
}

variable "unique_suffix" {
  description = "Storage 계정과 Key Vault 이름은 전 세계에서 유일해야 한다. 충돌을 피하려고 붙이는 짧은 접미사(예: 4자리 난수)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,6}$", var.unique_suffix))
    error_message = "unique_suffix 는 소문자·숫자 3~6자."
  }
}

variable "admin_username" {
  description = "VM 관리자 계정. Azure 가 금지하는 흔한 이름(admin, root 등)은 거부한다."
  type        = string
  default     = "opsadmin"
  validation {
    condition = (
      can(regex("^[a-z][a-z0-9_-]{2,31}$", var.admin_username)) &&
      !contains(["admin", "administrator", "root", "user", "test", "guest", "owner", "backup", "sys", "console", "server", "sql", "support", "adm"], var.admin_username)
    )
    error_message = "admin_username 은 소문자로 시작하는 3~32자이고 admin/root/user 같은 금지어는 쓸 수 없다."
  }
}

variable "ssh_public_key" {
  description = "VM 에 넣을 SSH 공개키 내용(한 줄). 파일 경로가 아니라 내용이다. 비밀키는 절대 아니다. Azure 는 RSA 2048 이상과 Ed25519 를 지원한다."
  type        = string
  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519) [A-Za-z0-9+/=]+", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key 는 'ssh-rsa AAAA...' 또는 'ssh-ed25519 AAAA...' 로 시작하는 공개키 내용이어야 한다."
  }
}

variable "my_ip_cidr" {
  description = "SSH(22)와 Grafana(3000)를 허용할 내 공인 IP. 반드시 /32 하나. 집 IP 가 바뀌면 이 값을 고쳐 다시 apply 한다."
  type        = string
  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])/32$", var.my_ip_cidr))
    error_message = "my_ip_cidr 는 IPv4 주소 하나에 /32 를 붙인 형식이어야 한다. 예: 203.0.113.10/32"
  }
}

variable "vm_size" {
  description = "VM 크기. B 시리즈(버스트형)만 허용. 기본 Standard_B2s = 2 vCPU, 4 GiB. 스택 7개 컨테이너(Postgres·Prometheus·Grafana 포함)를 띄우기에 1 GiB 짜리는 부족하다."
  type        = string
  default     = "Standard_B2s"
  validation {
    condition     = can(regex("^Standard_B", var.vm_size))
    error_message = "vm_size 는 비용 상한을 위해 Standard_B 로 시작하는 B 시리즈만 허용한다."
  }
}

variable "os_disk_size_gb" {
  description = "OS 디스크 크기(GB). Ubuntu 이미지 기본 30. 도커 이미지·DB·Prometheus 7일치가 들어가고도 남는다."
  type        = number
  default     = 30
  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 128
    error_message = "os_disk_size_gb 는 30~128."
  }
}

variable "vnet_cidr" {
  description = "가상 네트워크 주소 범위."
  type        = string
  default     = "10.10.0.0/16"
  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr 는 CIDR 표기여야 한다. 예: 10.10.0.0/16"
  }
}

variable "subnet_cidr" {
  description = "VM 이 들어갈 서브넷. vnet_cidr 안에 있어야 한다."
  type        = string
  default     = "10.10.1.0/24"
  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr 는 CIDR 표기여야 한다. 예: 10.10.1.0/24"
  }
}

variable "budget_amount" {
  description = "월 예산 금액. 단위는 구독의 청구 통화(한국 계정은 보통 KRW, USD 구독도 있음)라 통화를 코드로 고를 수 없다. 포털 > 비용 관리에서 통화를 먼저 확인하고 적는다."
  type        = number
  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount 는 0 보다 커야 한다."
  }
}

variable "budget_start_date" {
  description = "예산 집계 시작일. Azure 규칙: 반드시 어떤 달의 1일, 현재 집계 기간(이번 달) 안이거나 미래 12개월 이내. 바꾸면 예산이 재생성된다."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{4}-(0[1-9]|1[0-2])-01T00:00:00Z$", var.budget_start_date))
    error_message = "budget_start_date 는 'YYYY-MM-01T00:00:00Z' 형식(달의 1일)이어야 한다. 예: 2026-11-01T00:00:00Z"
  }
}

variable "alert_emails" {
  description = "예산 알림과 자동 종료 예고를 받을 이메일 목록. 최소 1개."
  type        = list(string)
  validation {
    condition = (
      length(var.alert_emails) > 0 &&
      alltrue([for e in var.alert_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    )
    error_message = "alert_emails 는 이메일 주소 1개 이상의 목록이어야 한다. 예: [\"ops@example.com\"]"
  }
}

variable "github_repository" {
  description = "GitHub Actions OIDC 신뢰 대상 저장소(owner/repo). 이 저장소의 main 브랜치와 production 환경에서 온 토큰만 Azure 로그인을 허용한다."
  type        = string
  default     = "ParkBomJun/booking-ops-lab"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository 는 'owner/repo' 형식이어야 한다."
  }
}

variable "github_environment" {
  description = "배포 job 이 쓰는 GitHub Environment 이름. job 에 environment 가 붙으면 OIDC subject 가 브랜치 대신 환경 이름으로 바뀐다."
  type        = string
  default     = "production"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,64}$", var.github_environment))
    error_message = "github_environment 는 영문·숫자·._- 1~64자."
  }
}

variable "backup_retention_days" {
  description = "Blob 에 올린 DB 백업을 며칠 뒤 자동 삭제할지. 수명 주기 정책이 처리한다."
  type        = number
  default     = 14
  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 365
    error_message = "backup_retention_days 는 1~365."
  }
}

variable "auto_shutdown_enabled" {
  description = "매일 정해진 시각에 VM 을 자동 할당 해제(deallocate)할지. 끄는 걸 잊었을 때의 비용 안전망."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "자동 종료 시각(HHmm, 한국 표준시). 기본 02:00."
  type        = string
  default     = "0200"
  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time 은 HHmm 4자리. 예: 0200"
  }
}

variable "tags" {
  description = "모든 리소스에 추가로 붙일 태그. 기본 태그(project, environment, managed_by)는 locals.tf 에서 자동으로 붙는다."
  type        = map(string)
  default     = {}
}

variable "github_owner_id" {
  description = "GitHub 소유자(사용자/조직)의 숫자 ID. github_repository_id 와 함께 주면 OIDC subject 에 강화 형식(owner@id/repo@id)을 쓴다. 저장소 이름이 바뀌거나 삭제 후 같은 이름으로 재생성돼도 다른 신원으로 취급돼 안전하다. 값: GET https://api.github.com/users/<owner> 의 id."
  type        = number
  default     = null
}

variable "github_repository_id" {
  description = "GitHub 저장소의 숫자 ID. 값: GET https://api.github.com/repos/<owner>/<repo> 의 id."
  type        = number
  default     = null
}
