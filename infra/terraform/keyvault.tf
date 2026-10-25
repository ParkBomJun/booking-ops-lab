# 비밀값 저장소. 값은 Terraform 에 넣지 않는다(상태 파일에 평문으로 남기 때문). apply 뒤 az cli 로 넣는다(docs/infra.md 적용 절차).
# 권한은 접근 정책(access policy) 대신 RBAC. 역할 할당이 Storage 와 같은 방식이라 한눈에 읽힌다.

# terraform 을 실행 중인 주체(사용자)의 tenant_id, object_id. 역할 할당과 Key Vault 테넌트 지정에 쓴다.
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "lab" {
  name                = local.names.key_vault
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard" # premium 은 HSM 보호 키용. 비밀값 몇 개엔 standard.
  tags                = local.common_tags

  # 접근 정책 대신 Azure RBAC 로 권한 관리. 아래 azurerm_role_assignment 두 개가 전부다.
  rbac_authorization_enabled = true

  # 삭제 후 복구 가능 기간. 최소값 7일. 길게 두면 destroy 뒤 같은 이름 재사용이 그만큼 막힌다(providers.tf 의 purge 옵션으로 보완).
  soft_delete_retention_days = 7

  # 퍼지 보호 끔. 켜면 soft-delete 된 볼트를 보존 기간 동안 아무도(Owner 도) 완전 삭제 못 한다.
  # 운영 환경이라면 켜야 맞다. 이 랩은 "안 쓸 때 destroy, 다음 주 다시 apply" 가 전제라 켜면 7일간 이름이 잠겨 재생성이 막힌다.
  # 보안 스캐너(tfsec azure-keyvault-no-purge)가 지적하는 항목이고, 알고 수용한 것이다.
  purge_protection_enabled = false

  # 네트워크: Storage 와 같은 모델. 공인 엔드포인트를 두고 방화벽으로 VM 서브넷 + 내 IP 만 허용.
  # 방화벽은 데이터 평면(비밀 읽기/쓰기)에만 걸린다. Terraform 의 볼트 생성·설정 변경은 Resource Manager 라 영향 없다.
  public_network_access_enabled = true
  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    ip_rules                   = [local.my_ip]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  lifecycle {
    precondition {
      condition     = length(local.names.key_vault) <= 24
      error_message = "Key Vault 이름 '${local.names.key_vault}' 이 24자를 넘는다. project/environment/unique_suffix 를 줄여라."
    }
  }
}

# VM 관리 ID → 비밀 "읽기" 만. 배포 스크립트가 .env 를 만들 때 쓴다. 쓰기·삭제·목록 변경은 못 한다.
resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# 현재 사용자 → 비밀 생성·수정·삭제. 구독 Owner 라도 RBAC 볼트의 비밀은 이 데이터 평면 역할 없이는 못 만든다.
# 역할 할당이 퍼지는 데 최대 10분쯤 걸릴 수 있다. apply 직후 `az keyvault secret set` 이 403 이면 잠시 뒤 다시.
resource "azurerm_role_assignment" "operator_kv_secrets_officer" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = "User"
}
