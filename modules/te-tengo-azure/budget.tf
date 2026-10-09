# Optional monthly cost alert on the whole subscription (budget_alert_email; off by default).
# Microsoft's Cost Management documentation lists Azure for Students (MS-AZR-0170P) among the offers
# Cost Management does not support, so on that subscription the create call may be rejected; the
# credit itself is the spending cap there (docs/terraform.md, "Cost").

data "azurerm_subscription" "current" {
  count = var.budget_alert_email != "" ? 1 : 0
}

resource "azurerm_consumption_budget_subscription" "monthly" {
  count = var.budget_alert_email != "" ? 1 : 0

  name            = "${local.name}-monthly"
  subscription_id = data.azurerm_subscription.current[0].id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = coalesce(var.budget_start_date, formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp()))
  }

  notification {
    enabled        = true
    operator       = "GreaterThanOrEqualTo"
    threshold      = 80
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  notification {
    enabled        = true
    operator       = "GreaterThanOrEqualTo"
    threshold      = 100
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  lifecycle {
    # The default start date follows the plan's clock: keep the one of the first apply.
    ignore_changes = [time_period]
  }
}
