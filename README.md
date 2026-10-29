# Aarogya Aarohan infrastructure

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Deployment configuration for **Aarogya Aarohan**, an assisted screening platform built on FHIR. It deploys the same application images in two ways. Pick the one that fits your programme.

| Folder | Model | Use it when |
|---|---|---|
| [`managed-cloud/`](managed-cloud/README.md) | Multi-tenant. One shared Kubernetes cluster per environment, a managed PostgreSQL, one FHIR partition, identity realm and storage bucket per tenant. Terraform plus ArgoCD. | A cloud region meets your data-residency rules and you want to onboard many programmes without new infrastructure. |
| [`self-hosted/`](self-hosted/README.md) | Single-tenant. A complete stack per site on k3s, on ordinary servers or on-premises, kept in sync by a central ArgoCD. | Data must stay on your own hardware, or you cannot rely on a public cloud. |

Both run:

- **HAPI FHIR** (the [aarogya-aarohan-dpg-fhir-server](https://github.com/aarogya-aarohan/aarogya-aarohan-dpg-fhir-server) fork) for clinical data and images
- a **FHIR gateway** for integrations and background jobs
- **Keycloak** for identity
- **PostgreSQL** and S3-compatible object storage
- the **web dashboard** used by specialists and administrators

A self-hosted site can later move into a managed-cloud deployment as a tenant. See `managed-cloud/scripts/migrate-tenant.sh`.

> **Clinical disclaimer.** Aarogya Aarohan is an assisted screening tool. It is not an autonomous diagnostic device; clinical decisions remain with qualified professionals.

## Before you deploy

- Every value that identifies a real deployment (domains, project ids, buckets, repository URLs) is a placeholder such as `example.org`, `your-gcp-project-id` or `YOUR_ORG`. Replace them with your own.
- No secrets are in this repository. Each folder's guide explains where secrets go (SOPS, a cloud secret store, or git-ignored env files).
- FHIR canonical URLs in the configuration (for example terminology and profile URLs) are data identifiers used by existing records and questionnaires, not endpoints you need to run.

## Contributing and security

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- [SECURITY.md](SECURITY.md): report vulnerabilities privately, not in public issues.

## License

[Apache License 2.0](LICENSE).
