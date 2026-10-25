# 네트워크: 리소스 그룹 → VNet → 서브넷 → NSG(규칙 3개) → 서브넷에 NSG 연결.
# 원칙: 인바운드는 내 IP 에서 오는 22(SSH)·3000(Grafana) 두 개만. 나머지(앱 8080~8082, DB 5432, Prometheus 9090, Alertmanager 9093)는
# 공인망에 열지 않는다. 필요하면 SSH 터널(ssh -L 9090:localhost:9090)로 본다.

# 모든 리소스를 담는 그룹. destroy 하면 이 그룹째 사라진다(예산과 Entra 앱 등록은 그룹 밖).
resource "azurerm_resource_group" "lab" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "lab" {
  name                = local.names.vnet
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

resource "azurerm_subnet" "app" {
  name                 = local.names.subnet
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_cidr]

  # 서비스 엔드포인트: 이 서브넷에서 Storage·Key Vault 로 가는 트래픽이 공인망이 아니라 Azure 백본으로 가고,
  # Storage·Key Vault 방화벽이 "이 서브넷에서 온 요청" 을 식별할 수 있게 된다(storage.tf·keyvault.tf 의 virtual_network_subnet_ids).
  # 무료. 사설 엔드포인트(Private Endpoint)는 월 과금이 있어 랩에서는 쓰지 않는다.
  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

# NSG 는 규칙을 담는 그릇. 규칙은 아래 azurerm_network_security_rule 로 하나씩 따로 둔다(한 블록에 몰아넣는 것보다 diff 가 읽기 쉽다).
resource "azurerm_network_security_group" "app" {
  name                = local.names.nsg
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.common_tags
}

# 규칙 1: SSH 는 내 IP(/32) 에서만. priority 숫자가 작을수록 먼저 평가된다.
resource "azurerm_network_security_rule" "allow_ssh_from_my_ip" {
  name                        = "AllowSshFromMyIp"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.app.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*" # 클라이언트 쪽 포트는 임의라 * 가 맞다. 목적지 포트만 제한한다.
  destination_port_range      = "22"
  source_address_prefix       = var.my_ip_cidr
  destination_address_prefix  = "*"
}

# 규칙 2: Grafana(운영 화면) 도 내 IP 에서만. Grafana 는 로그인이 있지만 공인망에 열어 둘 이유가 없다.
resource "azurerm_network_security_rule" "allow_grafana_from_my_ip" {
  name                        = "AllowGrafanaFromMyIp"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.app.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3000"
  source_address_prefix       = var.my_ip_cidr
  destination_address_prefix  = "*"
}

# 규칙 3: 나머지 인바운드 전부 거부. Azure 기본 규칙(65500 DenyAllInBound)이 이미 있지만,
# 기본 규칙 65000(VirtualNetwork 허용)·65001(AzureLoadBalancer 허용)보다 앞선 4096 에 명시해 두면
# "열린 건 위 두 개뿐" 이 포털·코드 어디서 봐도 분명하다. VM 이 한 대라 VNet 내부 허용도 필요 없다.
# 아웃바운드는 건드리지 않는다(기본 허용). apt·GHCR·Anthropic API·Blob 업로드가 모두 아웃바운드다.
resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "DenyAllInbound"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.app.name
  priority                    = 4096 # 사용자 규칙의 최댓값
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# NSG 를 NIC 가 아니라 서브넷에 건다. 나중에 VM 이 늘어도 같은 규칙을 받고, "NIC 에 NSG 붙이는 걸 잊음" 이 없다.
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}
