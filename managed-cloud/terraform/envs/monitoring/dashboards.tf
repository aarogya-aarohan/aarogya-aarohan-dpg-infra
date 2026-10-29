# Two dashboards that predate this stack: both were created directly in the
# Cloud Monitoring console (click-ops) by an earlier pass at this project,
# with no source file anywhere in this repo. Adopted into Terraform here via
# `terraform import` (see the import commands below) rather than recreated,
# so the import brings the *existing* GCP resource under management instead
# of standing up a duplicate. After importing, `terraform plan` should show
# no diff — if it does, the live dashboard has drifted from what's in the
# matching JSON file below and needs reconciling one way or the other.
#
# terraform import google_monitoring_dashboard.arogyam_dashboard_probe \
#   projects/your-gcp-project-id/dashboards/b6146e2b-abe7-4ca7-8f3e-cf93c8e48301
#
# terraform import google_monitoring_dashboard.hapi_fhir_jvm \
#   projects/your-gcp-project-id/dashboards/8f932e3e-5a3b-435a-93fc-216e40a12336
#
# If either ID has changed (e.g. the dashboard was deleted/recreated since
# this comment was written), find the current ID with:
#   gcloud monitoring dashboards list --project=your-gcp-project-id \
#     --format="table(name,displayName)"

resource "google_monitoring_dashboard" "arogyam_dashboard_probe" {
  project = var.project_id

  dashboard_json = file("${path.module}/dashboards/arogyam-dashboard-staging-probe.json")
}

resource "google_monitoring_dashboard" "hapi_fhir_jvm" {
  project = var.project_id

  dashboard_json = file("${path.module}/dashboards/hapi-fhir-jvm.json")
}
