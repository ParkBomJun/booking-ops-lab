# DB 백업 보관용 Storage 계정. backup.sh 가 pg_dump 결과를 "backups" 컨테이너에 올리고, 수명 주기 정책이 오래된 것을 지운다.
# 인증은 계정 키가 아니라 Entra ID(관리 ID·사용자)만. 키가 없으니 유출될 키도 없다.

resource "azurerm_storage_account" "backups" {
  name                = local.names.storage_account
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.common_tags

  account_kind             = "StorageV2" # 범용 v2. Blob 수명 주기 정책은 v2 에서만 된다.
  account_tier             = "Standard"  # HDD 기반. 백업 파일 쓰기/가끔 읽기에 충분.
  account_replication_type = "LRS"       # 한 데이터센터 안 3중 복제. 지역 복제(GRS)는 비용 2배인데 랩 백업엔 과하다.
  # 액세스 계층은 기본 Hot. Cool 이 저장 단가는 싸지만 "30일 안에 지우면 위약금" 이 있어 14일 보관 백업엔 오히려 Hot 이 싸다.

  # --- 전송·공개 범위 ---
  https_traffic_only_enabled = true     # http 거부
  min_tls_version            = "TLS1_2" # 1.0/1.1 거부

  # 컨테이너·블롭을 "익명 공개" 로 설정하는 것 자체를 계정 수준에서 금지. 실수로 백업을 공개하는 길을 없앤다.
  allow_nested_items_to_be_public = false

  # --- 인증 방식 ---
  # 공유 키(계정 키·SAS) 접근 끔. 이후 모든 데이터 접근은 Entra ID RBAC(아래 역할 할당)로만 된다.
  # 트레이드오프: az cli 로 블롭을 다룰 때 `--auth-mode login` 을 붙여야 하고, 역할이 없으면 Owner 라도 403 이다.
  # 그래서 아래에 VM 관리 ID 와 현재 사용자에게 데이터 평면 역할을 준다.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true # 포털에서 이 계정을 열면 기본 인증을 Entra ID 로 둔다(키 모드로 들어갔다가 403 보는 혼란 방지).

  # --- 네트워크 ---
  # 공인 엔드포인트는 켜 두되(사설 엔드포인트는 유료) 방화벽으로 좁힌다: VM 서브넷(서비스 엔드포인트) + 내 IP. 나머지 거부.
  public_network_access_enabled = true
  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"] # Azure 플랫폼 서비스(모니터링·백업 서비스 등)는 통과. 지금 쓰는 건 없지만 막아 두면 나중에 원인 찾기 어렵다.
    ip_rules                   = [local.my_ip]     # /32 없이 주소만 (Azure 규칙)
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  blob_properties {
    # 블롭 소프트 삭제 7일. prune 스크립트 버그나 실수로 지운 백업을 7일 안에 되살릴 수 있다. 수명 주기 정책으로 지운 것도 7일 더 남는다(소량이라 비용 무시).
    delete_retention_policy {
      days = 7
    }
    # 컨테이너 소프트 삭제도 같이.
    container_delete_retention_policy {
      days = 7
    }
  }

  lifecycle {
    # 이름 규칙이 24자를 넘기면 Azure 에서 거절당하기 전에 plan 에서 멈춘다.
    precondition {
      condition     = length(local.names.storage_account) <= 24
      error_message = "Storage 계정 이름 '${local.names.storage_account}' 이 24자를 넘는다. project/environment/unique_suffix 를 줄여라."
    }
  }
}

# 백업 파일이 들어갈 컨테이너. storage_account_id 를 쓰면 프로바이더가 데이터 평면이 아니라 Resource Manager API 로 만들어
# 공유 키를 꺼 둔 상태에서도 문제없다(storage_account_name 은 deprecated).
resource "azurerm_storage_container" "backups" {
  name                  = "backups"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private" # 익명 접근 없음(계정 수준에서도 이미 금지)
}

# 수명 주기 정책: backups/ 아래 블롭이 마지막 수정 후 N 일 지나면 삭제. backup.sh 의 "보관 기간 지난 백업 정리" 를 스크립트 대신 Azure 가 한다.
# 스크립트가 죽어도, VM 이 사라져도 정리는 계속된다.
resource "azurerm_storage_management_policy" "backups" {
  storage_account_id = azurerm_storage_account.backups.id

  rule {
    name    = "delete-old-backups"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${azurerm_storage_container.backups.name}/"] # "backups/" 로 시작하는 경로 = 그 컨테이너 전체
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.backup_retention_days
      }
    }
  }
}

# VM 관리 ID → 이 Storage 계정에 한해 블롭 읽기·쓰기·삭제. "Storage Blob Data Contributor" 는 데이터 평면 역할이라
# 계정 설정(방화벽·키)은 못 건드린다. 범위를 계정 하나로 좁혔으니 다른 Storage 에는 손댈 수 없다.
resource "azurerm_role_assignment" "vm_blob_contributor" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
  principal_type       = "ServicePrincipal" # 관리 ID 는 Entra 에서 서비스 주체로 취급. 명시하면 "방금 만든 ID 를 아직 못 찾음" 오류가 줄어든다.
}

# 현재 terraform 을 실행하는 사람(az login 사용자) → 같은 역할. 복구 훈련 때 백업을 내려받고, 테스트로 올린 파일을 지우기 위해.
# 구독 Owner 여도 데이터 평면 역할이 없으면 블롭을 볼 수 없다(공유 키를 껐기 때문).
resource "azurerm_role_assignment" "operator_blob_contributor" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = "User"
}
