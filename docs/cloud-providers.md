# Running on a cloud provider

This repository runs the same way on-premises and in the cloud: each site is a Linux server running k3s, and a management server runs ArgoCD. This page covers what changes when those servers are on Google Cloud, AWS or another provider. The manifests themselves stay the same.

## What every site needs

| Need | On-premises | Google Cloud | AWS |
|---|---|---|---|
| Linux server for k3s (one per site, one for management) | Physical or virtual server | Compute Engine VM | EC2 instance |
| Persistent disk for PostgreSQL and MinIO | Local disk or SAN | Persistent Disk | EBS volume |
| Private network between management and sites (TCP 6443) | LAN or VPN | VPC, firewall rule limited to the management server | VPC, security group limited to the management server |
| Public HTTPS (443) to each site | Reverse proxy or port forward | External IP or load balancer | Elastic IP or load balancer |
| Offsite S3-compatible bucket for backups | Any S3-compatible store | Cloud Storage (S3-interoperable with HMAC keys) | S3 |
| DNS name and TLS certificate per site | Your DNS, cert-manager or purchased certificate | Cloud DNS or your DNS | Route 53 or your DNS |

## Option 1: virtual machines with k3s (recommended starting point)

Follow [deployment-guide.md](deployment-guide.md) unchanged, using cloud VMs as the servers.

- **Network.** Give each VM a private address and pass it as `PRIVATE_IP` to `script/k3s/cluster-init.sh`. k3s then listens only on the private network. Open 6443 only to the management server, and 443 to users.
- **Backups.** Point `INFRA_BUCKET` (Litestream) and the CloudNativePG `destinationPath` and `endpointURL` at the provider's bucket:
  - AWS S3: `s3://<bucket>/...`, endpoint `https://s3.<region>.amazonaws.com`.
  - Google Cloud Storage: `s3://<bucket>/...`, endpoint `https://storage.googleapis.com`, with HMAC keys created for a service account that can write only to that bucket.
- **Credentials.** Prefer the provider's instance identity (an EC2 instance role or a VM service account) where the tool supports it. Otherwise use a key scoped to the one bucket, and keep it out of Git (see deployment guide, section 4).
- **Disk encryption.** Cloud disks are encrypted at rest by default. Add k3s `--secrets-encryption` for Kubernetes Secrets.

## Option 2: managed Kubernetes

The ArgoCD applications and Kustomize overlays work on any conformant Kubernetes cluster, including GKE and EKS.

- Skip `cluster-init.sh`. Create the cluster with the provider's tools, then register it in ArgoCD with `argocd cluster add`, using the cluster name your ApplicationSets expect.
- Keep the `cert-manager`, `ingress-nginx` and `cnpg` applications, or replace ingress-nginx with the provider's ingress controller and update the ingress manifests to match.
- Set a StorageClass that provisions the provider's persistent disks. The PostgreSQL clusters and MinIO request volumes through it.

## Swapping in-cluster services for managed ones

The stack runs everything in the cluster by default, so it has no cloud dependency. On a cloud provider you can replace these pieces with managed services:

| In-cluster component | Managed alternative | What to change |
|---|---|---|
| PostgreSQL (CloudNativePG) | Cloud SQL for PostgreSQL, Amazon RDS for PostgreSQL | Remove the `Cluster` resource from the overlay and point HAPI and Keycloak at the managed database through their env files and Helm values |
| MinIO | Amazon S3, or any S3-compatible store | Set the FHIR server's MinIO settings (`hapi.fhir.binary_storage_minio.*` in `.env-fhir.secret`) to the S3 endpoint, bucket and keys |
| Let's Encrypt via cert-manager | The provider's managed certificates on its load balancer | Terminate TLS at the load balancer and remove the TLS section from the ingresses |
| Uptime Kuma | The provider's uptime checks | Create one check per site URL |

Keep each site's database, bucket and keys separate so one site's credentials can never read another site's data.

## Checklist before go-live

- [ ] 6443 is reachable only from the management server.
- [ ] Backups land in the bucket, and a test restore of one site works (deployment guide, section 7).
- [ ] No env file, key or certificate is committed to your fork.
- [ ] Each site's URL is monitored.
