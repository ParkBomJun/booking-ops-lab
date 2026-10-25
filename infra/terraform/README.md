# infra/terraform

Azure 운영 환경(리소스 그룹, VNet/NSG, VM, Storage, Key Vault, 예산, GitHub OIDC)을 만드는 Terraform 코드.

- **설명 문서(파일·블록·인자 단위, 적용 절차, 비용, 보안 검토)**: [docs/infra.md](../../docs/infra.md)
- 시작: `cp terraform.tfvars.example terraform.tfvars` 후 값 채우기 → `az login` → `terraform init` → `terraform apply -target=azurerm_consumption_budget_subscription.lab` → `terraform apply`
- 안 쓸 때: `terraform destroy`
