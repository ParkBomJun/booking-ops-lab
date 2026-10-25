# apply 뒤 터미널에 찍히는 값. GitHub Secrets·스크립트 설정에 그대로 쓴다.
# 비밀값은 없다. 단, 구독·테넌트 ID 는 공개 저장소·스크린샷에 올리지 않는다(비밀은 아니지만 공격 표면 정보).

output "resource_group_name" {
  description = "모든 리소스가 든 리소스 그룹"
  value       = azurerm_resource_group.lab.name
}

output "vm_name" {
  description = "VM 이름. CD 의 az vm run-command 와 GitHub variable AZURE_VM_NAME 에 쓴다."
  value       = azurerm_linux_virtual_machine.app.name
}

output "public_ip" {
  description = "VM 고정 공인 IP"
  value       = azurerm_public_ip.vm.ip_address
}

output "public_fqdn" {
  description = "VM DNS 이름 (<label>.<region>.cloudapp.azure.com)"
  value       = azurerm_public_ip.vm.fqdn
}

output "ssh_command" {
  description = "접속 명령"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.vm.fqdn}"
}

output "grafana_url" {
  description = "Grafana (내 IP 에서만 열림)"
  value       = "http://${azurerm_public_ip.vm.fqdn}:3000"
}

output "storage_account_name" {
  description = "백업 Storage 계정. backup.sh 의 대상."
  value       = azurerm_storage_account.backups.name
}

output "backup_container_name" {
  description = "백업 컨테이너"
  value       = azurerm_storage_container.backups.name
}

output "key_vault_name" {
  description = "비밀값을 넣을 Key Vault 이름 (az keyvault secret set --vault-name ...)"
  value       = azurerm_key_vault.lab.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.lab.vault_uri
}

output "vm_identity_principal_id" {
  description = "VM 관리 ID 의 object id. 역할 전파 문제를 조사할 때 쓴다."
  value       = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

# --- GitHub Secrets 용. 이름을 그대로 맞춰 두었다 ---
output "github_secret_AZURE_CLIENT_ID" {
  description = "GitHub secret AZURE_CLIENT_ID 에 넣을 값 (앱 등록 client id)"
  value       = azuread_application.cd.client_id
}

output "github_secret_AZURE_TENANT_ID" {
  description = "GitHub secret AZURE_TENANT_ID 에 넣을 값"
  value       = data.azurerm_client_config.current.tenant_id
}

output "github_secret_AZURE_SUBSCRIPTION_ID" {
  description = "GitHub secret AZURE_SUBSCRIPTION_ID 에 넣을 값"
  value       = data.azurerm_client_config.current.subscription_id
}
