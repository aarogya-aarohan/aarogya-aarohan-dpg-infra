# Monitoring

Google Managed Prometheus (GMP) + one env-switchable Cloud Monitoring
dashboard + alert policies. This is the operator guide: what is scraped,
how to add a target, how to read the dashboard, and — because every alert
policy's `documentation.content` links into an anchor on this page — what to
do when each one fires.

## What's scraped, and what isn't

Managed collection (`monitoring_enable_managed_prometheus`) is on for both
workload clusters (`aa-stg`, `aa-prod`) via the `gke-cluster` module.
Three things carry `PodMonitoring` CRs:

| Target | Status | Source | Notes |
|---|---|---|---|
| **HAPI FHIR** | Live | `components/hapi-fhir/overlays/staging/podmonitoring.yaml` | `/actuator/prometheus` on port `http`. Enabled via `management.metrics.export.prometheus.enabled: true` in `components/hapi-fhir/overlays/staging/patch-configmap.yaml`. |
| **Keycloak** | Live | `components/keycloak/values-staging.yaml` (`extraDeploy:`) | Path `/auth/realms/master/metrics` on the HTTP port (not the management port 9000). |
| **ingress-nginx** | Live | `components/gmp/base/podmonitoring-ingress-nginx.yaml` | Targets the container port named `metrics` (chart default whenever `controller.metrics.enabled: true`, already set). |

**Not scraped, and why:**

- **fhir-gateway / arogyam-dashboard** — Node apps with no
  metrics endpoint yet. Covered indirectly by GKE system metrics (restarts, CPU,
  memory, readiness) and by nginx-side request metrics for their ingress
  paths.
- **`uri` label on HAPI's `http_server_requests_seconds_*`** — present but
  **do not group or filter by it**. HAPI's `RestfulServer` is a raw Servlet,
  not a Spring MVC `DispatcherServlet` with `@RequestMapping` controllers, so
  Micrometer's URI auto-tagging comes back `UNKNOWN` for almost every real
  request (confirmed live against `/actuator/prometheus` before this was
  written — see the comment in `components/hapi-fhir/overlays/staging/patch-configmap.yaml`).
  Staging has a **staging-only** custom `FhirEndpointMetricsInterceptor`
  giving a real per-FHIR-resource-type breakdown instead; it does not exist
  in the production overlay, so nothing in this stack's dashboard or alerts
  depends on it — an env-switchable dashboard has to work in both envs.

## How to add a new scrape target

1. Confirm the endpoint actually serves Prometheus text format from inside
   the cluster: `kubectl --context aa-stg -n <ns> exec deploy/<name> --
   curl -s localhost:<port>/<path> | head`. Don't write a `PodMonitoring`
   CR against an endpoint you haven't curled — an unreachable target reports
   scrape failures forever and (once alert #9 below is confirmed working)
   pages nobody usefully.
2. Add a `PodMonitoring` CR **in the target's own namespace** — the CRD only
   selects pods in its own namespace, so a CR in `gmp-public` will not find
   pods in `arogyam`. Follow the shape in
   `components/gmp/base/podmonitoring-ingress-nginx.yaml` (component with its
   own namespace + kustomization) or `components/hapi-fhir/overlays/staging/podmonitoring.yaml`
   / `components/keycloak/values-staging.yaml` (`extraDeploy:` inside an
   existing component, when it doesn't have its own Kustomize base/overlay
   split).
3. Interval `30s`, not `15s` — see Cost below. No alert in this stack needs
   a tighter window than 5m.
4. If the workload is new to ArgoCD (not just a new CR on an existing one),
   make sure its `AppProject` destinations include the target namespace —
   see `projects/platform.yaml`'s `gmp-public`/`gmp-system`/`ingress-nginx`
   entries for the pattern. **Never** add `CreateNamespace=true` on a GMP
   Application; `gmp-public`/`gmp-system` are addon-managed, and ArgoCD
   claiming them fights the GMP operator's own reconciler.
5. Add the tile(s) to `terraform/envs/monitoring/dashboards/platform.json`
   and, if it's alert-worthy, a policy to `terraform/envs/monitoring/alerts.tf`
   — both keyed off `resource.label."cluster"` (Prometheus-sourced metrics)
   or `resource.label."cluster_name"` (GKE system metrics), never a
   hardcoded env string, so the new tile/policy works in both envs for free.
6. Update the scrape-target table above.

## Reading the dashboard / switching envs

**Arogyam Platform** (`terraform/envs/monitoring/dashboards/platform.json`,
applied as the single `google_monitoring_dashboard.platform` resource) has
one dropdown at the top, backed by a `dashboardFilters` entry with
`templateVariable: "env"` and `labelKey: "cluster"`. Every tile's query
string embeds `${env}` — switching the dropdown between `aa-stg` and
`aa-prod` repoints every Prometheus-sourced and GKE-system-metric tile at
once. Cloud SQL and GCS tiles don't carry a `cluster` label at all (they're
not Kubernetes resources), so those filter on `database_id` / `bucket_name`
instead, string-matched against `${env}` by the naming convention those
resources already follow (`aa-{env}-pg`, `aa-{env}-{tenant}-fhir-media`) —
same dropdown, same substitution, different label key per tile. See the
"Data" row's header tile in the dashboard JSON for the exact caveat.

`gcloud monitoring dashboards list --project your-gcp-project-id` should
return **exactly one** Arogyam dashboard. Two would mean someone
instantiated a per-env copy — the mistake this whole single-dashboard design
exists to avoid (dashboards are
project-scoped, not env-scoped, so a copy per env stack just drifts).

A dashboard whose filter is set to an env that has no data yet renders
**empty, not broken**. Expected during any staging-first rollout window.

**Rows, top to bottom:** Traffic (ingress-nginx cluster-wide) → Per-tenant
(same metrics, split by `host` — each tenant is its own hostname, so this is
free per-tenant visibility) → Workloads (GKE container/pod system metrics) →
HAPI FHIR (JVM + HTTP, from the actuator) → Keycloak (JVM heap, request rate
by outcome, error ratio, latency p50/p95/p99 — from the aerogear
keycloak-metrics-spi's per-realm endpoint, see the scrape-target table
above) → Nodes (allocatable vs committed, permanent watch on the staging
single-node squeeze) → Data (Cloud SQL + GCS) → Alerts (see note below —
this is a text tile with links, not a live incident list; see its own
content in the dashboard for why).

## Cost

GMP bills per sample ingested (`series × 60/interval_seconds` per minute).
Controls already in place, in order of impact:

- **Explicit `PodMonitoring` per workload, never `ClusterPodMonitoring`.** A
  cluster-wide scrape picks up `kube-system` and ArgoCD's own components for
  near-zero added value.
- **30s interval everywhere.** 15s doubles the bill for resolution nothing
  here needs (tightest alert window is 5m).
- **`monitoring_enabled_components = ["SYSTEM_COMPONENTS"]`, not
  `WORKLOADS`** on the `gke-cluster` module.
- nginx metrics (per-ingress-per-status-per-method) are the largest single
  contributor once ingress-nginx scraping is confirmed live. If the bill
  needs trimming after a month, `metricRelabeling` to drop the request
  duration histogram's long tail is the first cut, not reducing scrape
  scope.

Order-of-magnitude expectation: low tens of USD/month for this cluster
shape. **Not yet measured against a real billing week** — re-check after the
first full week now that ingress-nginx scraping is confirmed live and
record the actual figure here.

## Creating the Slack webhook secret

Not done by Terraform (see `var.enable_slack_channel`, default `false`, and
the `count`-gated `data.google_secret_manager_secret_version.slack_webhook`
in `alerts.tf`). One-time, out-of-band, by a human with a real Slack
incoming-webhook URL:

```bash
gcloud secrets create aa-monitoring-slack-webhook \
  --project=your-gcp-project-id \
  --replication-policy=automatic

echo -n "https://hooks.slack.com/services/XXX/YYY/ZZZ" | \
  gcloud secrets versions add aa-monitoring-slack-webhook \
  --project=your-gcp-project-id --data-file=-
```

Then set `enable_slack_channel = true` (either as a `TF_VAR_` override or by
adding it to `terraform/envs/monitoring/secrets.enc.json` — it isn't
sensitive itself, so a plain `.auto.tfvars` also works) and re-apply.

## Rollout — exact sequence

The design is deliberately conservative: alert thresholds in this stack are
**opening bids from the shape of the system, not measurements from it**.
Shipping them enabled on the first apply would produce a noisy first week
and teach people to mute the channel, which is worse than no alerts.

1. **Create `secrets.enc.json`**:
   ```bash
   sops terraform/envs/monitoring/secrets.enc.json
   # paste: {"project_id": "your-gcp-project-id", "region": "your-region"}
   ```
2. **Init + plan with alerts still fully disabled** (the variable defaults
   are already `alerts_enabled = false`, `enable_slack_channel = false` —
   no flags needed for this first pass):
   ```bash
   make init ENV=monitoring
   make plan ENV=monitoring
   ```
   Expect: one `google_monitoring_dashboard`, one email
   `google_monitoring_notification_channel`, and 10 real
   `google_monitoring_alert_policy` resources (the `for_each` over
   `local.envs` × 10 conceptual policies = 20 policy resources, since
   `cert_expiry` is a deliberate `for_each = {}` stub that creates nothing —
   see its comment in `alerts.tf`) — **all with `enabled = false`**.
3. **Apply.** Confirm in the console that the dashboard renders (it will
   look empty for an environment that has no workloads or traffic yet).
4. **Send a test notification** on the email channel (console: the channel's
   "Send test notification", or `gcloud beta monitoring channels verify`)
   and confirm it lands. Do the same for Slack once that channel exists.
5. **Soak the dashboard for about a week** against real traffic. Every
   threshold in `alerts.tf` is a guess — the err_ratio/p95_seconds pairs in
   `local.envs`, the `0.85`/`0.90` Cloud SQL and node thresholds, all of it.
   Adjust them from what the dashboard actually shows before enabling
   anything.
6. **Enable warn tier first**, via a targeted apply so page tier stays off:
   ```bash
   # after setting alerts_enabled = true in secrets.enc.json or a TF_VAR_ override
   sops exec-file --filename secrets.tfvars.json terraform/envs/monitoring/secrets.enc.json \
     'cd terraform/envs/monitoring && terraform apply -var-file={} \
       -target=google_monitoring_alert_policy.node_pressure \
       -target=google_monitoring_alert_policy.metrics_collection_stopped \
       -target=google_monitoring_alert_policy.jvm_heap_pressure'
   ```
   (skip `cert_expiry` — it has nothing to target, it's an empty `for_each`.)
7. **Watch it for a few days.** If nothing pages spuriously, run the full
   `make plan ENV=monitoring` / `make apply ENV=monitoring` with
   `alerts_enabled = true` and no `-target` — this brings the page-tier
   policies (ingress 5xx/latency, restart storm, no-ready-replicas, the
   three Cloud SQL policies) up to `enabled = true` as well.
8. **To roll back** at any point: set `alerts_enabled = false` and
   `make apply ENV=monitoring` — every policy flips back to disabled in one
   apply, no need to hunt down which ones were on.

## Alert policies

Every policy below is defined in `terraform/envs/monitoring/alerts.tf`,
`for_each`-instantiated once per env (`aa-stg`, `aa-prod`), `combiner = "OR"`,
`alert_strategy.auto_close = "1800s"`, `enabled = var.alerts_enabled`
(warn-tier policies additionally carry `notification_rate_limit` at 30m).
Renaming a condition's `display_name` replaces the policy and re-fires its
incidents — don't do it during a live incident, only at authoring time.

**To silence any policy** without touching Terraform state: open it in the
console (Monitoring → Alerting → Policies) and use "Snooze" for a temporary
window, or edit the incident directly. To silence it permanently, set
`alerts_enabled = false` for everything, or comment out that one
`resource` block and `terraform apply` (which deletes it — prefer Snooze for
anything short-term).

### Ingress 5xx error ratio

**Fires when:** the ratio of `nginx_ingress_controller_requests` with
`status` matching `^5` to total requests, cluster-wide, exceeds 10%
(staging) / 2% (production) for 5 minutes.

**First three things to check:**
1. Is it one tenant or all of them? Split the "Per-tenant" row's error-rate
   tile by host — a single hostname spiking points at that tenant's HAPI
   partition or the fhir-gateway pod serving it; every hostname spiking
   together points at something cluster-wide (Cloud SQL, Keycloak, the
   ingress controller itself).
2. `kubectl --context <cluster> -n arogyam get pods` — is anything
   crash-looping or pending? Cross-check the restart-storm and
   no-ready-replicas policies below; they often fire together with this one.
3. `kubectl --context <cluster> -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200`
   for upstream connection errors (`connect() failed`, `upstream timed out`)
   vs. application-level 5xx (those show up in the app pod's own logs
   instead).

**Silence:** Snooze in the console if it's a known deploy in progress; the
ratio should self-clear once the rollout finishes (auto-close is 30m).

### Ingress p95 latency

**Fires when:** p95 of `nginx_ingress_controller_request_duration_seconds`
exceeds 8s (staging) / 3s (production) for 10 minutes.

**First three things to check:**
1. Check the "Traffic" row's latency tile for p50 vs p95/p99 — a p95-only
   spike with flat p50 usually means a slow tail (a few big FHIR searches or
   `$export` runs), not a general degradation.
2. Cloud SQL CPU/disk tiles in the "Data" row — Postgres contention is the
   most common real cause on this platform (shared instance, multiple
   tenants).
3. Staging specifically: check whether the single node is CPU-throttled —
   see the Nodes row and alert #8 below; staging's node-capacity constraint
   (see the tenant-onboarding runbook) makes this the most common staging
   explanation.

**Silence:** Snooze during a known bulk import/export or migration run —
those are expected to be slow.

### Container restart storm

**Fires when:** any container's `restart_count` increases by more than 3
within a 15-minute window.

**First three things to check:**
1. `kubectl --context <cluster> -n <ns> describe pod <pod>` — check the
   `Last State` section for the previous container's exit code and reason
   (OOMKilled vs Error vs CrashLoopBackOff for a different underlying cause).
2. `kubectl --context <cluster> -n <ns> logs <pod> --previous` — the crashed
   container's own last output, not the current (already-restarted) one.
3. Recent deploys/config changes to that component — for example a gateway
   crash-loop caused by a tenant missing from the app configuration.

**Silence:** Snooze while actively debugging; don't leave it snoozed past
the incident, restart storms are never expected steady-state.

### Deployment has no ready replicas

**Fires when:** a Deployment's fraction of ready pods drops to 0 for 5
minutes. **Verify the metric/label pairing behind this policy before relying on it** — see
the big comment on `deployment_no_ready_replicas` in `alerts.tf` before
trusting it; it may simply never fire if the metric name or the
`metadata.system_labels` keys it filters on turn out to be wrong, and unlike
most policies in this file it has no absence-based safety net (that's
alert #9, and it only covers Prometheus-sourced metrics, not GKE system
metrics).

**First three things to check:**
1. Same as restart storm — `describe pod` / `logs --previous` on any pod
   belonging to that deployment.
2. Is it stuck `Pending`? `kubectl describe pod` events will show scheduling
   failures — on staging, most likely the single-node capacity constraint.
3. Is it a bad rollout that never became ready (failing readiness probe,
   not crashing)? `kubectl rollout status deploy/<name>` and check the probe
   config against what the app actually needs to boot (DB migrations, cache
   warmup, etc).

**Silence:** Snooze only if this is a deliberate scale-to-zero (e.g. the
documented staging HAPI restart dance) — otherwise this should never be
silenced, it means user-facing downtime for that component.

### Cloud SQL disk utilisation

**Fires when:** `cloudsql.googleapis.com/database/disk/utilization` exceeds
85% for 10 minutes.

**First three things to check:**
1. `gcloud sql instances describe aa-{stg,prod}-pg --project your-gcp-project-id`
   — current disk size and whether autoresize is on.
2. Recent bulk imports/migrations — those are the most likely cause of a
   sudden jump (large NDJSON imports, binary storage growth if
   `binary_storage_gcs` accounting drifted).
3. `pg_stat_activity` / table bloat if this is a slow creep rather than a
   sudden jump — a shared Postgres instance across every tenant in the env
   makes bloat from one noisy tenant everyone's problem.

**Silence:** Never — a full disk on a shared Postgres instance takes down
every tenant in the env simultaneously. Fix the disk, don't snooze this one.

### Cloud SQL CPU utilisation

**Fires when:** `cloudsql.googleapis.com/database/cpu/utilization` exceeds
90% for 15 minutes.

**First three things to check:**
1. `pg_stat_activity` for long-running or blocked queries.
2. Which tenant(s) are driving load right now — cross-reference the
   "Per-tenant" row's request-rate tile for a correlated spike.
3. Whether a `measure-evaluator` CronJob run overlaps (see `docs/operations.md`
   / the README's Metrics section) — the daily evaluator run is a known
   legitimate CPU spike source, distinct from a real problem.

**Silence:** Snooze if it's a known, time-boxed batch job (evaluator run,
migration); investigate otherwise.

### Cloud SQL instance down

**Fires when:** `cloudsql.googleapis.com/database/up` reads 0 for 5 minutes.

**First three things to check:**
1. `gcloud sql instances describe aa-{stg,prod}-pg` — check `state` for
   `MAINTENANCE` (scheduled) vs something unexpected.
2. GCP status dashboard for a regional Cloud SQL incident.
3. Whether this coincides with a Terraform apply that touched the `cloud-sql`
   module (`deletion_protection`, tier changes) — those can trigger a
   restart.

**Silence:** Never — every workload in the env is down while this fires.

### Node CPU-memory pressure

**Fires when:** either `kubernetes.io/node/cpu/allocatable_utilization` or
the (unverified) memory equivalent exceeds 90% committed for 30 minutes —
one policy, two OR'd conditions, so one incident covers either cause.

**First three things to check:**
1. Staging: this is the **expected, permanent, named operational
   constraint** (see the tenant-onboarding runbook's node-capacity note) —
   check whether it's above the *usual* baseline or just confirming the
   known squeeze.
2. `kubectl --context <cluster> top nodes` / `top pods -A --sort-by=memory`
   for the actual current offender.
3. Production: this is the early warning before autoscaling stops helping —
   check `node_max_count` in the relevant `envs/{staging,production}/main.tf`
   `module "cluster"` block against current node count.

**Silence:** On staging, this is close to always-on given the known
constraint — consider whether the threshold itself needs raising (via the
`local.envs` map in `alerts.tf`) rather than repeatedly snoozing an alert
that's telling you something true every time.

### Prometheus scrape target down

**Fires when:** no sample is seen for 15 minutes from any Prometheus scrape
job in the given cluster. **The metric this relies on
(`prometheus.googleapis.com/up/gauge`) is unverified** — see the comment on
`metrics_collection_stopped` in `alerts.tf`. This is the most important
policy to actually verify before trusting the rest: without it, every other
Prometheus-sourced policy in this file (1, 2, 9's own siblings via other
jobs, 10) fails **silently open** if the collector stops scraping — the
single most dangerous failure mode a monitoring stack can have.

**First three things to check:**
1. `kubectl --context <cluster> -n gmp-system get ds collector` — is the
   DaemonSet's pod count matched to node count, and are pods Ready?
2. `kubectl --context <cluster> -n gmp-system logs ds/collector` for scrape
   failures against the specific job named in the incident.
3. `kubectl --context <cluster> -n <target-ns> get podmonitoring` — status
   conditions on the CR itself (endpoint errors show up here).

**Silence:** Never — treat this as page-tier in practice even though it's
routed as warn tier; a silent monitoring gap is worse than most of what it
would have caught.

### JVM heap pressure

**Fires when:** `jvm_memory_used_bytes{area="heap"} /
jvm_memory_max_bytes{area="heap"}` exceeds 85% for 15 minutes, for whichever
of HAPI or Keycloak is exporting these metric names (standard Micrometer JVM binder names; confirm they appear in your
scrape output, see the comment on `jvm_heap_pressure` in `alerts.tf`).

**First three things to check:**
1. Which job (HAPI vs Keycloak) — the incident's `job` label in the
   documentation content.
2. GC pause rate tile in the HAPI row — frequent long pauses alongside high
   heap usage points at genuine memory pressure, not just a normal sawtooth.
3. Container memory-vs-limit tile (Workloads row) for the same pod — if the
   container is near its memory *limit* too, this is heading toward an
   OOMKill, not just heap tuning.

**Silence:** Snooze briefly around a known load test; otherwise this is an
early warning for a restart/OOM that alert #3 (restart storm) will catch
anyway if it actually happens.

### Certificate expiry

There is no dedicated metric for this: no Cloud Monitoring metric gives "days until expiry" for a
Google-managed LB certificate directly, so this uses a
`google_monitoring_uptime_check_config` per public hostname (`staging.` /
`production.` / `argocd.example.org`) with `validate_ssl = true`, which
Cloud Monitoring automatically populates as
`monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires` (a
gauge, in days). One `google_monitoring_alert_policy.cert_expiry` per
hostname fires when that value drops below 14 days.

**Before relying on this,** confirm in Metrics Explorer
that `resource.type="uptime_url" AND metric.type="monitoring.googleapis.com/
uptime_check/time_until_ssl_cert_expires"` returns real data for each
`check_id`, not "no data".

**First three things to check:**
1. Which hostname — the incident's `env` user label (`aa-stg`/`aa-prod`/
   `platform`) and the alert's display name both carry the actual hostname.
2. Whether this is a genuine stalled renewal or a DNS/reachability problem —
   check that DNS for these hostnames points at the load balancer
   (see the deployment guide's prerequisites). An unreachable uptime check reports
   the same as "no data", not a false "cert is fine".
3. The LB's own managed-certificate status in the GCP console — Google-managed
   certs auto-renew automatically, so a firing alert usually means renewal
   has stalled, not that manual action is needed first.

**Silence:** Don't snooze this one — a stalled cert renewal that isn't caught
here fails open (site goes down with `ERR_CERT_DATE_INVALID`), so false
positives should be fixed at the source (DNS/reachability) rather than
silenced.
