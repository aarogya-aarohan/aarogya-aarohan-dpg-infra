<!-- DRAFT: this guide depends on components/*/overlays/local and apps/local/, which must be added to the repo before publishing. See dpg-readiness-gaps.md. -->

# Local development

Run the complete Aarogya Aarohan backend stack on a laptop, with no cloud account and no credentials from the project team. Useful for evaluating the platform, developing manifests, and testing onboarding scripts.

The local setup uses the same Kustomize bases and Helm values as staging and production. A `local` overlay for each component swaps the managed cloud services for in-cluster equivalents:

| Cloud service | Local replacement |
|---|---|
| Managed PostgreSQL + DB proxy sidecar | Single PostgreSQL 16 pod (Bitnami chart), no sidecar |
| Object storage buckets | MinIO, one bucket per tenant |
| Secret store + External Secrets Operator | ESO with the `kubernetes` provider reading Secrets in a `local-secrets` namespace |
| Cloud load balancer | `kind` port mapping to ingress-nginx on `localhost:8443` |
| Managed Prometheus | Optional kube-prometheus-stack |

---

## 1. Prerequisites

| Tool | Version |
|---|---|
| Docker (or Podman) | 24+ with at least 4 CPUs and 8 GB RAM available |
| kind | 0.22+ |
| kubectl | 1.29+ |
| helm | 3.14+ |
| kustomize | 5.x |
| jq, curl, openssl | any |

HAPI FHIR is a JVM service and needs about 2 GB of memory on its own.

## 2. Create the cluster

```bash
cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30443
        hostPort: 8443
EOF
kind create cluster --name aarogya --config kind-config.yaml
```

## 3. Install ArgoCD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --version <pinned version, see terraform/modules/argocd>
kubectl -n argocd rollout status deploy/argocd-server
```

## 4. Create local secrets

```bash
./scripts/local/create-secrets.sh        # generates random passwords into the local-secrets namespace
```

The script creates the same secret names that the ExternalSecrets in `components/external-secrets` expect (database credentials, Keycloak admin, tenant credential bundle, dashboard tenant map), so the applications see exactly the same Kubernetes Secrets as in the cloud.

## 5. Point ArgoCD at your fork and deploy

```bash
# Register your fork (public forks need no credentials)
kubectl apply -n argocd -f apps/local/root.yaml   # app-of-apps for the local overlays
kubectl -n argocd get applications -w
```

Wait until all Applications report `Synced` and `Healthy`. Order of start-up: External Secrets Operator, PostgreSQL, MinIO, ingress-nginx, Keycloak, HAPI FHIR, FHIR gateway, dashboard.

Alternatively, without ArgoCD:

```bash
for c in external-secrets hapi-fhir fhir-gateway arogyam-dashboard; do
  kustomize build components/$c/overlays/local | kubectl apply --server-side -f -
done
helm install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak --version <pinned> \
  -n arogyam -f components/keycloak/values-base.yaml -f components/keycloak/values-local.yaml
```

## 6. Onboard a test tenant

```bash
export LOCAL_BASE_URL=https://localhost:8443
scripts/onboard-tenant-runtime.sh --env local --tenant demo
```

This creates the `demo` Keycloak realm and clients, the `demo` FHIR partition, the `partition_id` claim mapper and a test user.

## 7. Try it

```bash
BASE=https://localhost:8443
curl -sk $BASE/fhir/metadata | jq .fhirVersion
TOKEN=$(scripts/get-jwt.sh --env local --tenant demo --user <test-user> --password <password>)
curl -sk -H "Authorization: Bearer $TOKEN" "$BASE/fhir/demo/Patient?_count=0" | jq .total
```

Open `https://localhost:8443/dashboard` (accept the self-signed certificate), pick `demo`, and log in with the test user printed by the onboarding script.

To connect the Android app, build it with the base URL of your machine's LAN address and port 8443; see the fhir-app repository README.

## 8. Clean up

```bash
kind delete cluster --name aarogya
```

## Troubleshooting

| Symptom | Check |
|---|---|
| HAPI pod `OOMKilled` | Give Docker more memory, or lower the JVM heap in the local overlay |
| ExternalSecret `SecretSyncedError` | `kubectl -n local-secrets get secrets`; re-run `create-secrets.sh` |
| Keycloak login redirects to the wrong URL | Hostname in `values-local.yaml` must be `localhost:8443` |
| FHIR returns 403 | The token's `partition_id` must equal the tenant in the URL |
