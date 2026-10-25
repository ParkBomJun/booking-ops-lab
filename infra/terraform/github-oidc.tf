# GitHub Actions 가 장기 비밀키 없이 Azure 에 로그인하는 구성(OIDC / 워크로드 ID 페더레이션).
# 흐름: 워크플로가 GitHub 에서 짧은 수명의 OIDC 토큰을 받는다 → Entra ID 가 토큰의 발급자(issuer)와 subject 를
# 아래 페더레이션 자격 증명과 대조 → 맞으면 이 앱(서비스 주체)의 Azure 토큰을 준다. GitHub Secrets 에 저장할 비밀키가 없다.
# 권한은 "VM 하나에 대한 Virtual Machine Contributor" 뿐이라, 워크플로가 탈취돼도 VM 밖은 못 건드린다.

# 앱 등록. 테넌트 안의 "애플리케이션" 정의. client_id 가 GitHub Secrets 의 AZURE_CLIENT_ID 가 된다.
resource "azuread_application" "cd" {
  display_name = local.names.github_app
  description  = "GitHub Actions CD for ${var.github_repository} (OIDC, no client secret)"
}

# 서비스 주체. 앱 등록을 "이 테넌트에서 권한을 받을 수 있는 주체" 로 만든다. 역할 할당은 이 object_id 에 건다.
resource "azuread_service_principal" "cd" {
  client_id   = azuread_application.cd.client_id
  description = "Service principal for GitHub Actions CD (${var.github_repository})"
}

# 페더레이션 자격 증명 1: main 브랜치에서 실행된 워크플로.
# subject 형식은 GitHub 가 정한다. 환경(environment) 을 쓰지 않는 job 은 "repo:<owner/repo>:ref:refs/heads/<branch>" 로 온다.
# 다른 브랜치·PR·포크에서 온 토큰은 subject 가 달라 거부된다.
resource "azuread_application_federated_identity_credential" "main_branch" {
  application_id = azuread_application.cd.id
  display_name   = "github-main-branch"
  description    = "Workflows running on refs/heads/main of ${var.github_repository}"
  audiences      = ["api://AzureADTokenExchange"] # Entra 가 요구하는 고정 audience
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.github_oidc_repo}:ref:refs/heads/main"
}

# 페더레이션 자격 증명 2: GitHub Environment "production" 을 쓰는 job.
# job 에 `environment: production` 이 붙으면 subject 가 브랜치가 아니라 "repo:<owner/repo>:environment:<name>" 으로 바뀐다.
# 둘 다 등록해 두어야 "배포 job 만 환경 보호 규칙(승인 대기 등)을 붙였더니 로그인이 깨짐" 을 피한다.
resource "azuread_application_federated_identity_credential" "production_environment" {
  application_id = azuread_application.cd.id
  display_name   = "github-environment-${var.github_environment}"
  description    = "Jobs using GitHub environment '${var.github_environment}' in ${var.github_repository}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.github_oidc_repo}:environment:${var.github_environment}"
}

# 역할: VM 리소스 하나에만 Virtual Machine Contributor.
# CD 는 `az vm run-command invoke` 로 VM 안에서 배포 스크립트를 실행한다. 이 명령은 VM 에이전트를 통해 가므로
# GitHub 러너에 SSH 포트를 열 필요가 없다(NSG 의 22 는 내 IP 만 유지). 범위가 VM 이라 리소스 그룹의 다른 것(Storage, Key Vault)은 보이지도 않는다.
# 더 좁히려면 runCommand/action 만 가진 사용자 지정 역할을 만들 수 있다(docs/infra.md "아직 안 한 것").
resource "azurerm_role_assignment" "cd_vm_contributor" {
  scope                = azurerm_linux_virtual_machine.app.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azuread_service_principal.cd.object_id
  principal_type       = "ServicePrincipal"
}
