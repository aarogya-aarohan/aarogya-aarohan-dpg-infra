variable "project_id" {
  type = string
}

variable "region" {
  type        = string
  description = "GCP region. Supplied via SOPS-encrypted secrets.enc.json — see docs/deployment-guide.md. Not actually used to *place* anything (every resource in this stack — dashboard, channels, alert policies — is global/project-scoped, not regional), kept only so this stack takes the same {project_id, region} secrets.enc.json shape as staging/production and the Makefile's generic sops exec-file path needs no special-casing for a third shape."
}

# --- Notification channels -------------------------------------------------

variable "devops_email" {
  type        = string
  description = "Group alias that receives every email notification. Defaults to the operator group README.md:164 already names — group:devops-group@example.org holds monitoring.admin today, so no new distribution list or IAM grant is needed for this address to work."
  default     = "devops-group@example.org"
}

variable "enable_slack_channel" {
  type        = bool
  description = "Gate on the Slack notification channel. Defaults to false because it reads the webhook URL from a Secret Manager secret (see slack_webhook_secret_name) that does not exist yet — nobody has created aa-monitoring-slack-webhook. Flip to true only after that secret is populated out-of-band (Slack webhook URLs are a rotating credential, so per docs/deployment-guide.md's SOPS-vs-Secret-Manager rule they live in Secret Manager, not secrets.enc.json). The first apply with this still false must succeed without the secret existing — see alerts.tf."
  default     = false
}

variable "slack_webhook_secret_name" {
  type        = string
  description = "Secret Manager secret id (not full resource name) holding the Slack incoming-webhook URL. Only read when enable_slack_channel = true — the data source is count-gated on it, so this stack never fails to plan/apply just because the secret doesn't exist yet. Terraform does not create this secret; see docs/monitoring.md for the one-time gcloud commands a human runs out-of-band."
  default     = "aa-monitoring-slack-webhook"
}

# --- Alert rollout gate ------------------------------------------------------

variable "alerts_enabled" {
  type        = bool
  description = <<-EOT
    Single kill switch for every alert policy's `enabled` field (all 11
    policies, both env instances, both severity tiers — see alerts.tf).
    Defaults to false. Per the monitoring guide (docs/monitoring.md), the
    thresholds in this stack are opening bids from the shape of the system,
    not measurements from it — shipping them enabled on the first apply
    would produce a noisy first week and teach people to mute the channel,
    which is worse than having no alerts at all.

    The rollout is two-staged (warn tier first, page tier a few days
    later) but deliberately uses this ONE variable rather than a second
    knob — see docs/monitoring.md's rollout section for how that's done
    with a single boolean via a targeted `terraform apply` for the warn-tier
    resources first, then an untargeted apply once page tier is ready.
  EOT
  default     = false
}
