# Same provider shape as every other env stack in this repo (see
# terraform/envs/staging/providers.tf) — one `google` provider, GCS backend
# with the prefix supplied at `init` time by the repo-root Makefile.
#
# No `google-beta` provider here: google_monitoring_dashboard,
# google_monitoring_notification_channel and google_monitoring_alert_policy
# are all GA resources in `hashicorp/google` and none of the other env
# stacks in this repo declare google-beta directly either (it only shows up
# transitively, pulled in by the vendored cloud-sql / gke-cluster registry
# modules — see their .terraform.lock.hcl). This stack has no Kubernetes,
# Helm or kubectl provider either, unlike envs/argocd — it never talks to a
# cluster API, only to the Cloud Monitoring API, which is why it's the one stack in this repo that can be
# planned and applied from a laptop with no bastion/VPN hop.
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
