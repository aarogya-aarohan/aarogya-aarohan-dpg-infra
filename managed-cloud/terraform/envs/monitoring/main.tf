# terraform/envs/monitoring — one project-scoped Cloud Monitoring dashboard,
# plus (in alerts.tf) the notification channels and alert policies. See
# docs/monitoring.md for why this is a single dashboard covering
# both environments rather than one dashboard per env stack: dashboards are
# project-scoped, not env-scoped, so instantiating the same dashboard from
# both envs/staging and envs/production would produce two drifting copies.
#
# Every tile plots aa-stg and aa-prod side by side as separate series rather
# than using a dashboard-wide environment picker. An earlier version used a
# ${env} template variable for this; Cloud Monitoring's substitution didn't
# work reliably across every tile shape, so it was replaced with explicit
# per-env dataSets in each tile (see dashboards/platform.json).
#
# This stack has no `module` blocks and touches no other stack's state via
# terraform_remote_state — it only needs var.project_id, which is why it can
# be planned/applied from a laptop (see providers.tf).

resource "google_monitoring_dashboard" "platform" {
  project = var.project_id

  # Kept as a separate JSON file rather than jsonencode()-ing an HCL object.
  # Dashboard JSON is verbose and almost entirely mosaicLayout/tile
  # positioning — jsonencode() output for that would be a wall of
  # unreadable, unstable-ordered key-value pairs in every `terraform plan`
  # diff. A hand-authored JSON file gives normal line-based diffs when a
  # tile changes.
  dashboard_json = file("${path.module}/dashboards/platform.json")
}
