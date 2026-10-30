# Deployment guide: self-hosted sites on k3s

This guide sets up a management cluster and one or more site clusters, each running a full Aarogya Aarohan stack. It works on any Linux virtual machine or bare-metal server, on-premises or on any cloud. For cloud-specific notes see [cloud-providers.md](cloud-providers.md).

---

## 1. Plan

| Server | Runs |
|---|---|
| Management | ArgoCD (and optionally Uptime Kuma) |
| Each site | ingress-nginx, HAPI FHIR, FHIR gateway, Keycloak, dashboard, CloudNativePG PostgreSQL, MinIO |

Size each site for the JVM-based HAPI FHIR and Keycloak plus PostgreSQL, and give it enough disk for screening images, which grow with use. Keep the HAPI liveness probe generous (see §9).

Networking:
- The management server must reach each site's Kubernetes API (TCP 6443) on the private network.
- Users must reach each site on HTTPS (443), directly or through an institutional reverse proxy.
- Each site needs a DNS name and a TLS certificate.
- Sites need outbound HTTPS to an S3-compatible bucket for backups and to the container registry.

## 2. Install k3s

`script/k3s/cluster-init.sh` does the full install. Set its variables at the top first:

| Variable | Meaning |
|---|---|
| `PRIVATE_IP` | The server's private address; k3s binds and advertises only on it, so the API is not exposed publicly |
| `INFRA_BUCKET` | S3 bucket for cluster-state backups |
| `CLUSTER_NAME` | Name used for the backup path |
| `DOCKER_USERNAME` (+ token) | Registry credentials, written to `/etc/rancher/k3s/registries.yaml` to avoid pull rate limits |

What it does, in order:
1. Writes `/etc/litestream.yml` to replicate `/var/lib/rancher/k3s/server/db/state.db` to `s3://$INFRA_BUCKET/backups/k3s/$CLUSTER_NAME`.
2. Installs Litestream (v0.3.13) and k3s with `--disable=traefik --bind-address $PRIVATE_IP --advertise-address $PRIVATE_IP --node-ip $PRIVATE_IP`, without starting it.
3. Restores the datastore from S3 if a replica exists, so the same script rebuilds a failed server.
4. Starts k3s and Litestream.

The script reads the S3 credentials from `LITESTREAM_ACCESS_KEY_ID` and `LITESTREAM_SECRET_ACCESS_KEY` in your shell, so they never go into a committed file. It writes them to `/etc/litestream.yml` with mode 600.

Recommended hardening for servers holding patient data: full-disk encryption on the host, and k3s `--secrets-encryption` added to `INSTALL_K3S_EXEC`.

## 3. Management cluster: ArgoCD

Install ArgoCD on the management server (`script/k3s/management-init.sh` installs k3s for it), then:

```bash
# register each site, using that site's kubeconfig (/etc/rancher/k3s/k3s.yaml,
# with server: set to the site's private address)
argocd cluster add <site-context> --name arogyam-example-site

# bootstrap the root Applications
kubectl -n argocd apply -f apps/app_of_projects/
kubectl -n argocd apply -f apps/app_of_apps/
```

Change every `repoURL` in `apps/` from `YOUR_ORG` to your fork, and register the repository in ArgoCD with a read-only deploy key (`argocd repo add`). Keep that key out of Git.

ArgoCD then installs the shared platform pieces on the target clusters (cert-manager, ingress-nginx, CloudNativePG, MinIO) and the Arogyam services.

## 4. Site secrets

Each site overlay builds its Secrets with Kustomize `secretGenerator` from env files in `environment/<site>/resources/`. Each file has a `.env-*.example` next to it listing its keys; copy it to the `.secret` name and fill it in.

| File | Component | Holds |
|---|---|---|
| `.env-db.secret` | fhir, auth | S3 credentials for CloudNativePG backups |
| `.env-fhir.secret` | fhir | HAPI settings |
| `.env-fhir-integration.secret` | fhir | FHIR gateway: FHIR base URL, token URL, client id/secret, and the switches for its background jobs |
| `.env-auth.secret` | auth | Keycloak admin password |
| `.env-dashboard.secret` | dashboard | NextAuth secret and URL, Keycloak client and issuer |
| TLS Secrets | all | `arogyam-fhir-integration-tls`, `arogyam-dashboard-tls`, `arogyam-auth-tls`: certificate and key for the site hostname |
| `minio-root-credentials` | MinIO | Keys `root-user` and `root-password`, in the `minio` namespace |

`*.secret` is in `.gitignore`. **These files must never be committed.** To keep them in Git safely, use one of:

- **SOPS + KSOPS:** commit SOPS-encrypted env files; ArgoCD decrypts them at render time with a key only the management cluster holds.
- **Sealed Secrets:** replace the `secretGenerator` with committed `SealedSecret` objects.
- **Out-of-band:** create the Secrets with `kubectl create secret generic --from-env-file` on each site and remove the `secretGenerator` entries.

For TLS, prefer cert-manager with the Let's Encrypt `ClusterIssuer` in `components/certificates_issuer` where the site is reachable from the internet.

## 5. Add a site

1. Copy an existing site's overlays:
   ```bash
   for c in fhir auth dashboard; do
     cp -r components/arogyam/$c/environment/example-site components/arogyam/$c/environment/site-<n>
   done
   ```
2. In the new overlays (and `auth/environment/site-<n>/values/auth-values.yaml`), set the ingress hostnames, database patch (storage size, backup bucket path) and image tags.
3. Create the site's env files from `.env.example` (step 4).
4. Add an element for the site to each ApplicationSet in `apps/arogyam/` (`fhir.yaml`, `auth.yaml`, `dashboard.yaml`), and to `cnpg`, `minio`, `ingress-nginx` and `cert-manager`:
   ```yaml
   - cluster: arogyam-site-<n>        # name registered in ArgoCD
     namePrefix: arogyam-site-<n>
     project: arogyam-production
     environment: site-<n>            # folder under environment/
     namespace: production
   ```
5. Open a pull request. After merge, ArgoCD creates the site's Applications and deploys the stack.
6. Add an Uptime Kuma monitor for the site's public URL.

## 6. Verify

```bash
curl -s https://<site-host>/fhir/metadata | jq .fhirVersion
curl -s https://<site-host>/auth/realms/<realm>/.well-known/openid-configuration | jq .issuer
k3s kubectl -n production get pods,cluster
```

Log in to the dashboard with a user from the site's realm, and register a test patient from the Android app pointed at the site URL.

## 7. Backups and restore

| What | How | Restore |
|---|---|---|
| PostgreSQL | CloudNativePG barman backups to S3 (gzip + AES256), WAL archiving, nightly `ScheduledBackup`, 7-day retention | Bootstrap a new `Cluster` with `recovery` from the backup (template commented in `components/arogyam/fhir/base/fhir-db.yaml`) |
| k3s datastore | Litestream continuous replication | Re-run `cluster-init.sh`; it restores before starting k3s |
| Images in MinIO | Bucket replication or scheduled `mc mirror` to the offsite bucket | Mirror back |
| Configuration | Git | ArgoCD re-syncs |

Test a full rebuild of one site from backups before go-live.

## 8. Upgrades

Change the image tag in the base (all sites) or in one site's `images:` block, open a pull request and merge. ArgoCD rolls the change out to the targeted sites. Upgrade a pilot site first.

## 9. Monitoring and troubleshooting

- Uptime Kuma (`apps/uptime`) probes each site's public endpoints and posts to a chat channel. When several sites fail in the same minute, suspect the shared network path rather than the sites.
- Check HAPI restart counts first on a slow site: probes without `timeoutSeconds` use the 1-second default and can kill a busy HAPI. Set `timeoutSeconds: 10` and `failureThreshold: 5` on liveness, `timeoutSeconds: 5` on readiness.
- For metrics, install kube-prometheus-stack per site or remote-write to a central Prometheus.
