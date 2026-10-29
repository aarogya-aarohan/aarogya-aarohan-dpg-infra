locals {
  short_name = {
    argocd     = "argocd"
    staging    = "stg"
    production = "prod"
  }

  cluster_name = "aa-${local.short_name[var.env]}"
  env_short    = local.short_name[var.env]

  wi_pool = "${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog"
  wi_principals = {
    eso           = "principal://iam.googleapis.com/projects/${local.wi_pool}/subject/ns/external-secrets/sa/external-secrets"
    gateway       = "principal://iam.googleapis.com/projects/${local.wi_pool}/subject/ns/arogyam/sa/fhir-gateway"
    hapi          = "principal://iam.googleapis.com/projects/${local.wi_pool}/subject/ns/arogyam/sa/hapi-fhir"
    keycloak      = "principal://iam.googleapis.com/projects/${local.wi_pool}/subject/ns/arogyam/sa/keycloak"
  }
}

data "google_project" "this" {
  project_id = var.project_id
}

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "your-tf-state-bucket"
    prefix = "network"
  }
}

module "cluster" {
  source = "../../modules/gke-cluster"

  project_id          = var.project_id
  cluster_name        = local.cluster_name
  region              = var.region
  network_project_id  = data.terraform_remote_state.network.outputs.host_project_id
  network_name        = data.terraform_remote_state.network.outputs.vpc_name
  subnet_name         = data.terraform_remote_state.network.outputs.subnet_names[var.env]
  pods_range_name     = data.terraform_remote_state.network.outputs.pods_range_names[var.env]
  services_range_name = data.terraform_remote_state.network.outputs.services_range_names[var.env]
  master_ipv4_cidr    = var.master_ipv4_cidr

  master_authorized_networks = var.master_authorized_networks
  enable_private_endpoint    = var.enable_private_endpoint
  deletion_protection        = var.env == "production"
  node_max_count             = 1
  node_service_account       = var.node_service_account
  node_zones                 = ["${var.region}-c"]
  node_tags                  = ["aa-gke-stg-nodes"]

  enable_managed_prometheus = true
}

module "db" {
  source = "../../modules/cloud-sql"

  project_id            = var.project_id
  name                  = "${local.cluster_name}-pg"
  env                   = local.env_short
  region                = var.region
  vpc_self_link         = data.terraform_remote_state.network.outputs.vpc_self_link
  tier                  = "db-custom-4-15360"
  availability_type     = "ZONAL"
  backup_retention_days = 7
  deletion_protection   = false
}

resource "google_secret_manager_secret" "shared" {
  for_each = toset([
    "aa-${local.env_short}-pg-app-creds",
    "aa-${local.env_short}-keycloak-admin",
    "aa-${local.env_short}-arogyam-tenant-credentials",
    "aa-${local.env_short}-dashboard-keycloak-tenants",
    "aa-${local.env_short}-fhir-bootstrap-secret",
  ])

  project   = var.project_id
  secret_id = each.key

  replication {
    auto {}
  }

  labels = {
    env = local.env_short
    app = "arogyam"
  }
}

resource "google_secret_manager_secret_iam_member" "shared_accessor" {
  for_each = google_secret_manager_secret.shared

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.wi_principals.eso
}

resource "google_secret_manager_secret_version" "pg_app_creds" {
  secret = google_secret_manager_secret.shared["aa-${local.env_short}-pg-app-creds"].id
  secret_data = jsonencode({
    username          = module.db.hapi_user_name
    password          = module.db.hapi_password
    keycloak_username = module.db.keycloak_user_name
    keycloak_password = module.db.keycloak_password
  })
}

resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret_version" "keycloak_admin" {
  secret = google_secret_manager_secret.shared["aa-${local.env_short}-keycloak-admin"].id
  secret_data = jsonencode({
    username = "admin"
    password = random_password.keycloak_admin.result
  })
}

# Bundled per-tenant credentials consumed by arogyam-backend (fhir-gateway).
# Payload is a JSON object keyed by tenant code; operators populate via
# `gcloud secrets versions add aa-${env}-arogyam-tenant-credentials` during
# tenant onboarding (see docs/tenant-onboarding.md). TF seeds an empty object
# so ESO has a non-empty version to sync on first deploy.
resource "google_secret_manager_secret_version" "arogyam_tenant_credentials_seed" {
  secret      = google_secret_manager_secret.shared["aa-${local.env_short}-arogyam-tenant-credentials"].id
  secret_data = "{}"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Per-tenant Keycloak client config consumed by the arogyam-dashboard frontend
# as KEYCLOAK_TENANTS_JSON. Operators populate via `gcloud secrets versions add
# aa-${env}-dashboard-keycloak-tenants`. TF seeds an empty object so ESO has a
# non-empty version to sync on first deploy.
resource "google_secret_manager_secret_version" "dashboard_keycloak_tenants_seed" {
  secret      = google_secret_manager_secret.shared["aa-${local.env_short}-dashboard-keycloak-tenants"].id
  secret_data = "{}"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# cloud-sql-proxy in the hapi-fhir and keycloak pods authenticates to the
# Cloud SQL Admin API by impersonating a per-app GSA (traditional WI). The
# GSAs (aa-{env}-{hapi,keycloak}) and their cloudsql.client / workloadIdentityUser
# bindings are managed by the platform team — our identity does not have
# roles/resourcemanager.projectIamAdmin. Create them before applying this stack
# (see docs/deployment-guide.md).
locals {
  # Shared by hapi-fhir and keycloak in this env. Both apps need exactly
  # roles/cloudsql.client and live in the same namespace/cluster, so a single
  # per-env GSA is sufficient and fits inside the 30-char SA-id limit.
  cloudsql_gsa = "aa-cloudsql-${local.env_short}@${var.project_id}.iam.gserviceaccount.com"
}

module "tenant_gcs" {
  for_each = toset(var.tenants)
  source   = "../../modules/tenant-gcs"

  tenant_id         = each.key
  env               = local.env_short
  hapi_principal    = local.wi_principals.hapi
  hapi_gsa_email    = local.cloudsql_gsa
  gateway_principal = local.wi_principals.gateway
  dashboard_origins = ["https://${var.env}.${var.base_domain}"]
}

module "tenant_secrets" {
  for_each = toset(var.tenants)
  source   = "../../modules/tenant-secrets"

  project_id         = var.project_id
  tenant_id          = each.key
  env                = local.env_short
  accessor_principal = local.wi_principals.eso
}
