# Optional SNS mobile push (the API's 'sns' provider). The MVP pushes through Firebase Cloud
# Messaging directly ('fcm' provider), so this is off by default. When it is switched on, one
# GCM (FCM HTTP v1) platform application serves Android and iOS, because the app registers FCM
# tokens on both platforms (te-tengo-general-api docs/NOTIFICATIONS.md).
resource "aws_sns_platform_application" "fcm" {
  count = var.enable_sns ? 1 : 0

  name                = "${local.name}-fcm"
  platform            = "GCM"
  platform_credential = var.sns_fcm_service_account_json

  lifecycle {
    precondition {
      condition     = var.sns_fcm_service_account_json != null
      error_message = "enable_sns needs sns_fcm_service_account_json (the Firebase service-account JSON key)."
    }
  }
}
