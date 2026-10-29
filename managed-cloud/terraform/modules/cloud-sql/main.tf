resource "random_password" "admin" {
  length  = 32
  special = true
}

resource "random_password" "hapi" {
  length  = 32
  special = false
}

resource "random_password" "keycloak" {
  length  = 32
  special = false
}

module "postgres" {
  source  = "terraform-google-modules/sql-db/google//modules/postgresql"
  version = "~> 20.0"

  project_id       = var.project_id
  name             = var.name
  database_version = "POSTGRES_16"
  region           = var.region
  tier             = var.tier

  availability_type           = var.availability_type
  deletion_protection         = var.deletion_protection
  deletion_protection_enabled = var.deletion_protection

  ip_configuration = {
    ipv4_enabled    = false
    private_network = var.vpc_self_link
    require_ssl     = true
  }

  database_flags = [
    { name = "cloudsql.enable_pgaudit", value = "on" },
    { name = "pgaudit.log", value = "ddl,role" },
  ]

  backup_configuration = {
    enabled                        = true
    point_in_time_recovery_enabled = true
    start_time                     = "02:00"
    location                       = var.region
    transaction_log_retention_days = 7
    retained_backups               = var.backup_retention_days
    retention_unit                 = "COUNT"
  }

  insights_config = {
    query_string_length     = 1024
    record_application_tags = true
    record_client_address   = true
  }

  maintenance_window_day          = 7
  maintenance_window_hour         = 18
  maintenance_window_update_track = "stable"

  enable_default_db   = true
  db_name             = var.database_name
  enable_default_user = true
  user_name           = var.admin_user_name
  user_password       = random_password.admin.result
}

resource "google_secret_manager_secret" "admin_password" {
  project   = var.project_id
  secret_id = "aa-${var.env}-pg-admin-password"

  replication {
    auto {}
  }

  labels = {
    env = var.env
    app = "arogyam"
  }
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = random_password.admin.result
}

resource "google_sql_user" "hapi" {
  project  = var.project_id
  instance = module.postgres.instance_name
  name     = var.hapi_user_name
  password = random_password.hapi.result
}

resource "google_sql_user" "keycloak" {
  project  = var.project_id
  instance = module.postgres.instance_name
  name     = var.keycloak_user_name
  password = random_password.keycloak.result
}

# The default database (var.database_name, "arogyam") is created by the
# `postgres` module above and is used by HAPI FHIR. Keycloak gets its own
# logical database on the same instance so the two apps don't share schemas.
resource "google_sql_database" "keycloak" {
  project  = var.project_id
  instance = module.postgres.instance_name
  name     = var.keycloak_database_name
}
