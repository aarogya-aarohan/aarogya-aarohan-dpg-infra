locals {
  secrets = {
    keycloak_client_secret   = "aa-${var.env}-${var.tenant_id}-keycloak-client-secret"
    api_client_secret        = "aa-${var.env}-${var.tenant_id}-api-client-secret"
    support_client_secret    = "aa-${var.env}-${var.tenant_id}-support-client-secret"
    bootstrap_admin_password = "aa-${var.env}-${var.tenant_id}-bootstrap-admin-password"
  }

  # Placeholder content so ESO can fetch a non-empty version on first deploy.
  # Operators replace via `gcloud secrets versions add` during tenant onboarding
  # (see docs/tenant-onboarding.md); TF ignore_changes keeps it from being
  # clobbered on subsequent applies. Tenant FHIR/export client credentials now
  # live in the per-env bundled secret aa-{env}-arogyam-tenant-credentials, not
  # in this module — see terraform/envs/{staging,production}/main.tf. The
  # platform FHIR bundle seeder uses a single env-wide service-account
  # credential `aa-{env}-fhir-bootstrap-secret`, also defined in the env stack.
  # bootstrap_admin_password is read by onboard-tenant-runtime.sh's
  # step_bootstrap_admin_user; if its content matches the placeholder prefix
  # the step is skipped so the dummy value never lands as a real KC password.
  placeholders = {
    keycloak_client_secret   = "placeholder-replace-via-onboard-tenant-runtime.sh"
    api_client_secret        = "placeholder-replace-via-onboard-tenant-runtime.sh"
    support_client_secret    = "placeholder-replace-via-onboard-tenant-runtime.sh"
    bootstrap_admin_password = "placeholder-set-via-gcloud-secrets-versions-add"
  }
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.secrets
  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    tenant = var.tenant_id
    env    = var.env
    app    = "arogyam"
  }
}

resource "google_secret_manager_secret_version" "placeholder" {
  for_each    = local.secrets
  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = local.placeholders[each.key]

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each  = google_secret_manager_secret.this
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = var.accessor_principal
}
