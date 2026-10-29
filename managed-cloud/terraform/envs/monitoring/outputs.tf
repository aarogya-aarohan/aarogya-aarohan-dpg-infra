output "dashboard_id" {
  description = "Resource id of the platform dashboard, e.g. for building a direct console URL (https://console.cloud.google.com/monitoring/dashboards/builder/<id>?project=<project_id>)."
  value       = google_monitoring_dashboard.platform.id
}

output "notification_channel_ids" {
  description = "IDs of the notification channels this stack manages, for reference when debugging why a policy did or didn't notify."
  value = {
    email = google_monitoring_notification_channel.devops_email.id
    slack = var.enable_slack_channel ? google_monitoring_notification_channel.slack[0].id : null
  }
}

output "alerts_enabled" {
  description = "Echoes var.alerts_enabled so `terraform output` after an apply is a fast way to confirm whether this apply left every policy disabled or enabled, without opening the console."
  value       = var.alerts_enabled
}
