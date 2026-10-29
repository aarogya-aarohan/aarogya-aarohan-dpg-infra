resource "google_storage_bucket" "this" {
  name                        = "aa-${var.env}-${var.tenant_id}-fhir-media"
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = 90
    }
  }

  cors {
    origin          = var.dashboard_origins
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  labels = {
    tenant = var.tenant_id
    env    = var.env
    app    = "arogyam"
  }
}

resource "google_storage_bucket_iam_member" "hapi" {
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectAdmin"
  member = var.hapi_principal
}

# Grants the impersonated GSA the same bucket access. The HAPI pod's KSA is
# annotated for GSA impersonation (because the cloud-sql-proxy sidecar shares
# the pod's KSA and needs roles/cloudsql.client, currently bound to the GSA),
# so ADC inside the pod hands out a token for the GSA — not the direct-WI
# KSA principal that the `hapi` binding above targets. Until the workload
# moves to direct-WI for the proxy as well, both grants must exist.
resource "google_storage_bucket_iam_member" "hapi_gsa" {
  count  = var.hapi_gsa_email == "" ? 0 : 1
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.hapi_gsa_email}"
}

resource "google_storage_bucket_iam_member" "gateway" {
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectViewer"
  member = var.gateway_principal
}
