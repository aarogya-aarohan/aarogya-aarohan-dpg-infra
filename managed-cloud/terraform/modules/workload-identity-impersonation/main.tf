# Fallback module — only use when the target Google resource does not accept
# `principal://...` IAM members (currently: Cloud SQL IAM auth user names).
# For everything else, grant IAM directly to the KSA principal — see
# the architecture guide (docs/architecture.md).

resource "google_service_account_iam_member" "wi_user" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.ksa_namespace}/${var.ksa_name}]"
}
