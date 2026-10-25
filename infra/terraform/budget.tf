# 예산 알림. CLAUDE.md 규칙 "예산 알림을 가장 먼저 설정한다".
# 리소스 그룹이 아니라 구독 범위에 건다. 이유:
#   - 리소스 그룹 예산은 그 그룹 밖(포털에서 실수로 만든 것, Azure 가 자동 생성하는 NetworkWatcherRG 등)을 못 본다.
#   - 구독 예산은 리소스 그룹에 의존하지 않아 `terraform apply -target=azurerm_consumption_budget_subscription.lab` 으로
#     다른 리소스보다 먼저, 단독으로 만들 수 있다.
# 예산은 "알림" 이지 "차단" 이 아니다. 100% 를 넘어도 Azure 는 리소스를 멈추지 않는다. 멈추는 건 사람(terraform destroy).

# 현재 구독 정보(ID 를 /subscriptions/... 형식으로 얻기 위해).
data "azurerm_subscription" "current" {}

resource "azurerm_consumption_budget_subscription" "lab" {
  name            = local.names.budget
  subscription_id = data.azurerm_subscription.current.id

  # 금액 단위는 구독의 청구 통화. 코드로 통화를 지정할 수 없어 변수 설명에 확인 절차를 적어 두었다.
  amount     = var.budget_amount
  time_grain = "Monthly" # 매달 1일에 집계가 0 으로 돌아간다.

  time_period {
    # 반드시 어떤 달의 1일. end_date 를 생략하면 시작일 + 10년.
    start_date = var.budget_start_date
  }

  # 알림 4단계. 실제 사용액 50 → 80 → 100%, 그리고 "이대로 가면 월말에 100% 넘음" 예측 1개.
  # operator GreaterThan: 사용액이 threshold% 를 넘는 순간 1회 발송(같은 단계는 다시 안 옴).
  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted" # 월초라도 추세상 넘을 것 같으면 미리 알려준다. 50% 알림보다 먼저 올 수 있다.
    contact_emails = var.alert_emails
  }
}
