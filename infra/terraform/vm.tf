# VM 한 대: 공인 IP → NIC → Linux VM(Ubuntu 24.04, cloud-init 으로 Docker 설치) → 자동 종료 스케줄.

# 고정 공인 IP. Standard SKU 는 기본이 "인바운드 전부 차단, NSG 로만 열기" 라 우리 설계와 맞고,
# Basic SKU 는 2025-09 에 단종 예고가 나 새로 만들면 안 된다. Static: VM 을 껐다 켜도 IP 가 바뀌지 않아 NSG·DNS·SSH 설정이 안 깨진다.
resource "azurerm_public_ip" "vm" {
  name                = local.names.public_ip
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Standard"
  allocation_method   = "Static"
  ip_version          = "IPv4"
  # <label>.koreacentral.cloudapp.azure.com 으로 접속할 수 있는 DNS 이름. IP 를 외울 필요가 없다. 무료.
  domain_name_label = "${local.prefix}-${var.unique_suffix}"
  tags              = local.common_tags
}

resource "azurerm_network_interface" "vm" {
  name                = local.names.nic
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic" # 사설 IP 는 Azure 가 서브넷에서 하나 준다. VM 이 하나라 고정할 이유가 없다.
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                = local.names.vm
  computer_name       = local.names.vm # OS 안의 hostname. 로그·프롬프트에 보이는 이름.
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.vm_size
  tags                = local.common_tags

  network_interface_ids = [azurerm_network_interface.vm.id]

  # 인증은 SSH 키만. 비밀번호 로그인은 끈다(무차별 대입 공격 대상 자체를 없앤다).
  admin_username                  = var.admin_username
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = trimspace(var.ssh_public_key) # 복사할 때 딸려온 줄바꿈 제거
  }

  os_disk {
    name                 = local.names.os_disk
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS" # Premium 은 랩에 과하고 Standard HDD 는 DB·Prometheus 가 체감되게 느리다. LRS = 한 데이터센터 안 3중 복제.
    disk_size_gb         = var.os_disk_size_gb
  }

  # Ubuntu 24.04 LTS (Noble). URN Canonical:ubuntu-24_04-lts:server:latest — Canonical 공식 문서로 확인한 값.
  # sku "server" 는 Gen2 이미지. version "latest" 는 만들 때 최신 패치 이미지를 고르고, 이후 새 이미지가 나와도 VM 을 재생성하지 않는다.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Trusted Launch(보안 부팅 + 가상 TPM). Gen2 이미지와 B 시리즈에서 지원되고 추가 비용 없음. 부트킷·루트킷류 변조를 부팅 단계에서 막는다.
  secure_boot_enabled = true
  vtpm_enabled        = true

  # 시스템 할당 관리 ID. 이 VM 이 "자기 자신" 으로 Key Vault 비밀을 읽고 Blob 에 백업을 올린다.
  # 비밀번호·키 파일이 VM 안에 없고, VM 을 지우면 ID 도 같이 사라진다.
  identity {
    type = "SystemAssigned"
  }

  # cloud-init: 첫 부팅 때 한 번 실행. Docker·compose 플러그인·az cli·chrony 설치, 저장소 clone. 내용은 cloud-init.yaml.
  # templatefile 로 변수를 끼워 넣고 base64 로 인코딩해 넘긴다(Azure 가 요구하는 형식).
  # 주의: 이 값을 바꾸면 VM 이 재생성된다(디스크 포함). 바꾸기 전에 backup.sh 로 DB 백업부터.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    admin_username    = var.admin_username
    github_repository = var.github_repository
  }))

  # 부팅 진단: 빈 블록 = Azure 관리 스토리지 사용(별도 계정 불필요, 사실상 무료).
  # SSH 가 안 될 때 포털의 "직렬 콘솔"·"부팅 진단 스크린샷" 으로 cloud-init 실패를 볼 수 있다.
  boot_diagnostics {}

  # cloud-init 이 끝나야 쓸 수 있는 리소스가 아니라도, 역할 할당이 VM identity 를 참조하므로 VM 이 먼저다(암묵 의존성).
}

# 매일 정해진 시각에 VM 을 할당 해제(deallocate). 컴퓨팅 과금이 멈춘다(디스크·공인 IP 는 계속 과금).
# "안 쓸 때 destroy" 규칙의 안전망. 다음날 작업할 땐 `az vm start` 로 켠다. 끄고 싶으면 auto_shutdown_enabled=false.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "app" {
  virtual_machine_id    = azurerm_linux_virtual_machine.app.id
  location              = azurerm_resource_group.lab.location
  enabled               = var.auto_shutdown_enabled
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "Korea Standard Time" # Windows 시간대 이름 형식을 쓴다.
  tags                  = local.common_tags

  # 종료 30분 전 이메일. 훈련 중이면 메일의 링크로 그날만 미룰 수 있다. 프로바이더 문서상 주소 하나만 받으므로 목록의 첫 번째를 쓴다.
  notification_settings {
    enabled         = true
    time_in_minutes = 30
    email           = var.alert_emails[0]
  }
}
