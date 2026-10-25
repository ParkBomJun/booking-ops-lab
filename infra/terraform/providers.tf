# 프로바이더 설정. 인증 정보는 여기에 없다. `az login` 한 사용자 자격을 그대로 쓴다.

provider "azurerm" {
  # 4.x 부터 구독 ID 를 반드시 명시해야 한다(3.x 는 az cli 기본 구독을 썼다). 값은 커밋하지 않는 terraform.tfvars 에서 온다.
  subscription_id = var.subscription_id

  # Storage 데이터 평면(컨테이너·블롭 조작)에 계정 키 대신 Entra ID 토큰을 쓴다.
  # storage.tf 에서 공유 키 접근을 끄기 때문에 이 옵션이 없으면 프로바이더가 키를 요구하다 실패한다.
  storage_use_azuread = true

  # features 블록은 비어 있어도 반드시 있어야 한다. 안에서 삭제 동작을 랩 환경에 맞게 조정한다.
  features {
    resource_group {
      # 기본값 true 는 "Terraform 이 모르는 리소스가 그룹 안에 있으면 destroy 를 거부". 안전하지만
      # 이 랩은 "안 쓸 때 destroy" 가 규칙이라, 포털에서 실수로 만든 것이 있어도 그룹째 지워 비용을 끊는다.
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Key Vault 는 삭제해도 soft-delete 상태로 이름이 7일간 남는다. destroy 뒤 바로 다시 apply 하면 같은 이름으로
      # 못 만든다. 아래 두 줄로 destroy 때 완전 삭제(purge)하고, 남아 있으면 복구해서 재사용한다.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    virtual_machine {
      # VM 을 지울 때 OS 디스크도 같이 지운다. 기본값도 true 지만 "디스크가 남아 과금" 이 흔한 실수라 명시한다.
      delete_os_disk_on_deletion = true
    }
  }
}

# Entra ID 프로바이더. 테넌트는 az login 세션에서 가져오므로 설정할 것이 없다.
provider "azuread" {}
