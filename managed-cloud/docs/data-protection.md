# Data protection and clinical boundaries

This document covers how the infrastructure stores, isolates, encrypts and controls access to personal health data. Application-level handling (what the Android app captures, consent, image processing) is documented in the application repositories.

---

## Clinical disclaimer

Aarogya Aarohan is an **assisted screening tool** for oral cancer and potentially malignant disorders. It supports trained health workers in capturing screening information and photographs, and routes cases to qualified specialists for remote review.

- It is **not an autonomous diagnostic device** and does not provide a diagnosis.
- Any AI-derived risk indicator shown in the system is decision support for a clinician. Clinical decisions, referrals and treatment remain the responsibility of qualified health professionals.
- The platform should be deployed under the clinical governance of the implementing health programme.

---

## What data the platform holds

| Data | Where | Personal data? |
|---|---|---|
| Patient demographics, screening questionnaires, encounters, observations, review tasks | FHIR resources in PostgreSQL, in the tenant's partition | Yes (PII and health data) |
| Oral cavity photographs | Tenant's object-storage bucket, referenced from FHIR `Binary` / `DocumentReference` / `Media` | Yes (health data) |
| User accounts of health workers, specialists and admins | Keycloak database, in the tenant's realm | Yes (staff PII) |
| Programme indicators | FHIR `MeasureReport` resources | Aggregated; no direct identifiers |
| Application and access logs | Cloud logging service | May contain user identifiers and resource ids |
| Metrics | Metrics backend | No patient data |

---

## Isolation between tenants

Each programme's data is separated by: a dedicated identity realm, a token claim (`partition_id`) checked against every FHIR request, partition-scoped queries in HAPI FHIR, and a dedicated storage bucket with its own access bindings. See [architecture.md § Multi-tenancy](architecture.md#6-multi-tenancy).

## Encryption

| Where | How |
|---|---|
| In transit, public | HTTPS terminated at the load balancer |
| In transit, application to database | TLS via the database proxy; the database rejects non-TLS connections |
| At rest, database and buckets | Encrypted by the cloud provider (provider-managed keys in the reference deployment). Customer-managed keys (CMEK / KMS) can be enabled per resource where a programme requires it. |
| At rest, Kubernetes Secrets | Provider-managed encryption of the cluster datastore; application-layer secrets encryption with a KMS key is recommended |
| Terraform variables in Git | SOPS-encrypted |

For on-premises deployments, enable disk encryption on hosts and Kubernetes secrets encryption; see [cloud-portability.md § On-premises](cloud-portability.md#4-worked-example-single-server-or-on-premises-deployment).

## Access control

- **No public data endpoints without authentication.** Every FHIR and API request requires a bearer token issued by the tenant's realm.
- **Private infrastructure.** Cluster nodes and APIs, and the database, have no public addresses. Administrative access is through a bastion behind an identity-aware proxy, granted to a named operator group.
- **No long-lived cloud credentials.** Workloads use workload identity; there are no service-account key files.
- **Least privilege on storage.** HAPI has write access to tenant buckets; the gateway has read access only.
- **Secrets never in Git.** Only references to secret names are committed.
- **Support access** to a tenant uses a dedicated `support` client in that tenant's realm, so actions are attributable.

## Data residency

The reference deployment runs in a single cloud region in India. Choose the region of your deployment to satisfy the data-residency requirements of your programme (for example, the Digital Personal Data Protection Act, 2023 in India).

## Retention and deletion

<!-- TODO (programme owners): state the retention period for clinical records, photographs, exports and logs, and who approves deletion. -->

- Bucket objects: non-current versions are deleted after 90 days.
- Database backups: 7 days (staging) / 30 days (production); transaction logs for point-in-time recovery: 7 days.
- Offboarding a tenant: see [tenant-onboarding.md § Offboarding](tenant-onboarding.md#offboarding-a-tenant).

## Anonymisation before export or central processing

<!-- TODO (application and data teams): document, with references to code, how data is de-identified before any export, research use or model training: EXIF/metadata stripping on photographs, removal or pseudonymisation of direct identifiers in FHIR resources, and any face detection or masking applied to images. The DPG guidelines require this section. -->

Operational data exports (for example tenant migration with FHIR `$export`) contain identifiable data. They are written only to the operator's working directory, which is excluded from version control, and must be deleted after use.

## Reporting a security issue

See [SECURITY.md](../SECURITY.md).
