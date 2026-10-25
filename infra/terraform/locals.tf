# 이름 규칙과 공통 태그를 한 곳에 모은다. 리소스 파일에는 local.names.xxx 만 쓴다.
# 규칙: <종류 접두사>-<project>-<environment>[-<용도>]. Azure CAF(Cloud Adoption Framework) 권장 접두사를 따른다.

locals {
  prefix = "${var.project}-${var.environment}" # 예: bookingops-lab

  names = {
    resource_group = "rg-${local.prefix}"
    vnet           = "vnet-${local.prefix}"
    subnet         = "snet-${local.prefix}-app"
    nsg            = "nsg-${local.prefix}-app"
    public_ip      = "pip-${local.prefix}-vm"
    nic            = "nic-${local.prefix}-vm"
    vm             = "vm-${local.prefix}"
    os_disk        = "osdisk-${local.prefix}-vm"
    budget         = "budget-${local.prefix}"
    github_app     = "github-${local.prefix}-cd"
    # Storage 계정 이름: 소문자·숫자만, 3~24자, 전 세계 유일. 하이픈 불가라 접두사 규칙과 다르다.
    storage_account = "st${var.project}${var.environment}${var.unique_suffix}"
    # Key Vault 이름: 3~24자, 전 세계 유일.
    key_vault = "kv-${local.prefix}-${var.unique_suffix}"
  }

  # Storage·Key Vault 방화벽의 IP 규칙은 /32 접미사를 받지 않는다(단일 IP 는 그냥 주소로 적어야 함). NSG 는 /32 그대로 쓴다.
  my_ip = split("/", var.my_ip_cidr)[0]

  # 모든 리소스에 붙는 태그. 비용 분석과 "이거 누가 만들었지" 를 위해.
  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      managed_by  = "terraform"
      repository  = var.github_repository
    },
    var.tags,
  )
}

# GitHub OIDC subject 의 저장소 부분.
# GitHub 는 새 저장소에 "owner@<owner_id>/repo@<repo_id>" 강화 형식을 쓴다(2026-10 실배포에서 AADSTS700213 으로 발견).
# ID 두 개가 주어지면 강화 형식, 아니면 기존 "owner/repo" 형식으로 subject 를 만든다.
locals {
  github_oidc_repo = (
    var.github_owner_id != null && var.github_repository_id != null
    ? format("%s@%d/%s@%d", split("/", var.github_repository)[0], var.github_owner_id, split("/", var.github_repository)[1], var.github_repository_id)
    : var.github_repository
  )
}
