# Terraform 자체와 프로바이더 버전을 고정한다.
# 설명 문서: docs/infra.md (파일·블록·인자 단위로 전부 설명)
#
# 왜 고정하나: 버전이 떠다니면 "어제는 되던 apply 가 오늘 깨지는" 일이 생긴다.
# 특히 azurerm 은 메이저가 바뀔 때 인자 이름이 바뀐다(3.x → 4.x 에서 여러 개, 5.x 도 이미 나와 있음).

terraform {
  # 1.9 이상, 2.0 미만. 1.9 에서 variable validation 이 다른 변수·데이터를 참조할 수 있게 됐다.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    # Azure 리소스(리소스 그룹, VM, 네트워크, Storage, Key Vault, 예산, 역할 할당).
    # "~> 4.81" = 4.81 이상 5.0 미만. 2026-10 기준 4.x 의 마지막 마이너가 4.81.0 이고 5.x 는 메이저 변경이 있어 따로 올린다.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    # Microsoft Entra ID(구 Azure AD) 리소스. GitHub Actions 용 앱 등록 + 페더레이션 자격 증명(OIDC)에만 쓴다.
    # 3.x 에서 application_id → client_id 등 이름이 바뀌었으므로 3.x 로 고정한다.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }

  # backend 블록이 없으면 상태(terraform.tfstate)는 이 디렉터리에 로컬 파일로 남는다.
  # 1인 랩이라 당장은 이걸로 가고, 원격 상태(azurerm backend)는 docs/infra.md "다음 단계" 에 적어 두었다.
}
