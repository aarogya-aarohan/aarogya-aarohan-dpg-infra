# Required GCP APIs

Service project: `your-gcp-project-id`. API enablement is owned by the platform team and managed out of band — Terraform does not assert these (the `_bootstrap` stack used to, but it required `roles/serviceusage.serviceUsageAdmin` for what is effectively a one-time-then-no-op operation).

If you find an API listed here is *not* enabled, file a ticket with the platform team rather than enabling it locally.

## Canonical list

| API | Used by |
|---|---|
| `compute.googleapis.com` | GKE clusters, Shared VPC subnetwork access, all VM-related resources |
| `container.googleapis.com` | GKE control plane and node management |
| `sqladmin.googleapis.com` | Cloud SQL Postgres instances |
| `secretmanager.googleapis.com` | Shared and per-tenant secrets, ESO source of truth |
| `iam.googleapis.com` | Service accounts, IAM bindings |
| `iamcredentials.googleapis.com` | Service account impersonation, Workload Identity tokens |
| `servicenetworking.googleapis.com` | Cloud SQL private services peering (legacy — superseded by PSC, kept for backward compat) |
| `storage.googleapis.com` | Terraform state bucket, per-tenant FHIR media buckets |
| `cloudresourcemanager.googleapis.com` | Project-level IAM and metadata |
| `iap.googleapis.com` | IAP TCP tunnel for bastion host access |

## Verification

```bash
gcloud services list --enabled --project=your-gcp-project-id \
  --format="value(NAME)" \
  | grep -E "^(compute|container|sqladmin|secretmanager|iam|iamcredentials|servicenetworking|storage|cloudresourcemanager|iap)\.googleapis\.com$" \
  | sort
```

Expected: 10 lines.

## Adding a new API

1. Ask whoever administers the cloud project to enable it, referencing this doc.
2. Once enabled, append to the table above and commit alongside the code change that needs it.
3. Do not re-introduce a `google_project_service` resource — APIs are enabled outside Terraform, by the project administrator.
