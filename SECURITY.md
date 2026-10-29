# Security policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions or pull requests.**

Report them privately by either:

- emailing **[SECURITY CONTACT EMAIL, e.g. security@your-domain]**, or
- using GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repository ("Security" tab → "Report a vulnerability").

Please include:

- the affected file, component or deployment configuration;
- steps to reproduce, or a proof of concept;
- the impact you believe it has (for example, cross-tenant data access, credential exposure, privilege escalation);
- any suggested fix.

Do not access, modify or download data that does not belong to you, and do not test against production deployments. This platform processes personal health data.

## What to expect

| Stage | Target |
|---|---|
| Acknowledgement of your report | within 3 working days |
| Initial assessment and severity | within 10 working days |
| Fix or mitigation for critical and high severity issues | as soon as possible, typically within 30 days |
| Public disclosure | coordinated with you after a fix is available |

We will credit you in the advisory unless you prefer to remain anonymous.

## Scope

In scope: the code and configuration in this repository (both `managed-cloud/` and `self-hosted/`), including Terraform modules, Kubernetes manifests, Helm values and scripts.

Vulnerabilities in upstream projects (HAPI FHIR, Keycloak, ArgoCD, ingress-nginx, External Secrets Operator, CloudNativePG, MinIO, k3s, Kubernetes) should be reported to those projects. Tell us as well if the issue affects how this repository configures them.

## Supported versions

Only the latest commit on `main` is supported. Deployments should track the current release.

## Security practices in this repository

- No secrets are committed. In managed-cloud, Terraform variables are SOPS-encrypted and runtime secrets live in a cloud secret store; in self-hosted, per-site env files are git-ignored.
- Managed-cloud workloads authenticate to cloud APIs with workload identity; no service-account key files.
- Clusters and databases are private; managed-cloud administration goes through an identity-aware bastion, and self-hosted k3s binds only to the private network.
- Each tenant's data is isolated by identity realm, token claim, FHIR partition and storage bucket.
