# Notification channels + alert policies. Same stack as the dashboard
# (main.tf) so channels, policies and dashboard version together — a single
# `make apply ENV=monitoring` moves all three. See docs/monitoring.md
# for the rationale and a runbook per policy. A few metric names below are
# flagged UNVERIFIED: confirm each in Metrics Explorer before flipping
# var.alerts_enabled.

# ---------------------------------------------------------------------------
# Notification channels
# ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "devops_email" {
  project      = var.project_id
  display_name = "AA DevOps (email)"
  type         = "email"
  labels = {
    email_address = var.devops_email
  }
  # Email channels to a Google Workspace group in the same org do not
  # require the usual click-to-verify step. If var.devops_email is ever
  # pointed at an individual's address instead, someone has to click the
  # confirmation email before this channel actually delivers — see the
  # rollout section in docs/monitoring.md.
}

# The Slack webhook URL is a rotating credential (per docs/deployment-guide.md's
# SOPS-vs-Secret-Manager rule), so it lives in Secret Manager, not
# secrets.enc.json. This data source — and the channel below — are
# count-gated on var.enable_slack_channel (default false) specifically so
# the FIRST apply of this stack does not hard-fail on a secret nobody has
# created yet. Terraform does not create aa-monitoring-slack-webhook; see
# docs/monitoring.md for the one-time `gcloud secrets create` + `versions
# add` a human runs before flipping enable_slack_channel to true.
data "google_secret_manager_secret_version" "slack_webhook" {
  count   = var.enable_slack_channel ? 1 : 0
  secret  = var.slack_webhook_secret_name
  project = var.project_id
}

resource "google_monitoring_notification_channel" "slack" {
  count        = var.enable_slack_channel ? 1 : 0
  project      = var.project_id
  display_name = "AA DevOps (Slack)"
  type         = "webhook_tokenauth"
  labels = {
    url = data.google_secret_manager_secret_version.slack_webhook[0].secret_data
  }
}

locals {
  # Page-tier policies on production get Slack + email; every other
  # combination (staging page-tier, and both envs' warn-tier policies) gets
  # email only. This list is what "prod page tier" resolves to.
  all_channels = concat(
    [google_monitoring_notification_channel.devops_email.id],
    var.enable_slack_channel ? [google_monitoring_notification_channel.slack[0].id] : []
  )
  email_only = [google_monitoring_notification_channel.devops_email.id]
}

# ---------------------------------------------------------------------------
# Per-env thresholds and routing
# ---------------------------------------------------------------------------
#
# One policy per condition, both envs in scope — condition filters below do
# not pin `cluster`/`cluster_name` themselves, `for_each` over this map does,
# which is what makes each (policy, env) pair its own google_monitoring_alert_policy
# resource while keeping the condition body written once. `each.key` is the
# GKE cluster name (aa-stg / aa-prod), which is also the exact string GMP
# stamps as the `cluster` label on every Prometheus series and
# the value of `cluster_name` on k8s_container/k8s_pod/k8s_node resources —
# same literal string, two different resource label keys, so it plugs
# straight into both kinds of filter below with no translation.
#
# `tier` here is env-level, not policy-level: staging cannot hold
# production's alerting posture (see docs/monitoring.md), so even the page-CLASS
# conditions (ingress 5xx ratio, p95 latency, restart storm, no-ready-replicas,
# the three Cloud SQL policies) are routed and labelled as "warn" when they
# run against staging. The warn-CLASS conditions (node pressure, absence,
# JVM heap, cert expiry) are warn tier for both envs unconditionally — see
# the second locals block below their resources.
locals {
  envs = {
    "aa-stg" = {
      tier        = "warn" # staging never pages, even for page-class conditions
      err_ratio   = 0.10   # 10% — staging is a rolling test bed, loose on purpose
      p95_seconds = 8
      channels    = local.email_only
    }
    "aa-prod" = {
      tier        = "page"
      err_ratio   = 0.02 # 2%
      p95_seconds = 3
      channels    = local.all_channels
    }
  }
}

# ---------------------------------------------------------------------------
# Page tier — prod routes to Slack + email; staging (per local.envs above)
# routes to email only regardless of how "severe" the condition class is.
# ---------------------------------------------------------------------------

# 1. Ingress 5xx ratio
resource "google_monitoring_alert_policy" "ingress_5xx_ratio" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Ingress 5xx error ratio"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "5xx / total request ratio above threshold"

    condition_threshold {
      # Ratio via denominator_filter/denominator_aggregations rather than an
      # MQL query — keeps every condition in this file the same
      # condition_threshold shape. Neither `=~` nor
      # `monitoring.regex.full_match(...)` works here — confirmed via two
      # separate real apply errors, and confirmed via a live
      # metricDescriptors query that `status` is a plain STRING label (not
      # a type mismatch). alert_policy condition_threshold.filter uses a
      # more restricted grammar than the general Monitoring API filter
      # (the one starts_with()/regex work fine in elsewhere, e.g. metric
      # discovery) — no regex operators or functions, only plain
      # comparisons + AND/OR/parentheses. So: an explicit OR of every
      # IANA-registered 5xx code (500-511) instead of a pattern match.
      filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/nginx_ingress_controller_requests/counter" AND
        (metric.label.status = "500" OR metric.label.status = "501" OR
         metric.label.status = "502" OR metric.label.status = "503" OR
         metric.label.status = "504" OR metric.label.status = "505" OR
         metric.label.status = "506" OR metric.label.status = "507" OR
         metric.label.status = "508" OR metric.label.status = "509" OR
         metric.label.status = "510" OR metric.label.status = "511")
      EOT
      denominator_filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/nginx_ingress_controller_requests/counter"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = each.value.err_ratio
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster} · **ns:** $${resource.label.namespace}
      Runbook: `docs/monitoring.md#ingress-5xx-error-ratio`
    EOT
  }
}

# 2. Ingress p95 latency
resource "google_monitoring_alert_policy" "ingress_p95_latency" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Ingress p95 latency"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "p95 request duration above threshold"

    condition_threshold {
      # UNVERIFIED metric type: GMP folds a Prometheus histogram's
      # _bucket/_sum/_count into one DISTRIBUTION-typed metric named after
      # the base series with a /histogram suffix (confirmed pattern from
      # Google's own GMP docs), so ALIGN_PERCENTILE_95 should apply directly
      # to nginx_ingress_controller_request_duration_seconds/histogram — but
      # this specific metric name was not curl-verified against a live
      # /metrics scrape (ingress-nginx's own PodMonitoring is itself
      # before use — see components/gmp/base/podmonitoring-ingress-nginx.yaml).
      filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/nginx_ingress_controller_request_duration_seconds/histogram"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = each.value.p95_seconds
      duration        = "600s"

      aggregations {
        # ALIGN_PERCENTILE_95 cannot apply directly to a CUMULATIVE
        # DISTRIBUTION metric (GMP's fold of the histogram _bucket series) —
        # confirmed via a real apply error 2026-09-03: "The aligner cannot
        # be applied to metrics with kind CUMULATIVE and value type
        # DISTRIBUTION." ALIGN_DELTA converts it to a delta distribution per
        # alignment_period; REDUCE_PERCENTILE_95 then extracts p95 from that
        # distribution across series. This is Google's documented pattern
        # for percentile-alerting on cumulative Prometheus histograms.
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_PERCENTILE_95"
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster}
      Runbook: `docs/monitoring.md#ingress-p95-latency`
    EOT
  }
}

# 3. Container restart storm
resource "google_monitoring_alert_policy" "container_restart_storm" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Container restart storm"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "restart_count delta > 3 in 15m, per container"

    condition_threshold {
      filter = <<-EOT
        resource.type = "k8s_container" AND
        resource.label."cluster_name" = "${each.key}" AND
        metric.type = "kubernetes.io/container/restart_count"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 3
      # duration = 0 is deliberate: the 15m window is the alignment_period
      # itself (ALIGN_DELTA sums restarts within each 900s bucket), not an
      # additional "sustained for N seconds" requirement on top of it.
      duration = "0s"

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields = [
          "resource.label.namespace_name",
          "resource.label.pod_name",
          "resource.label.container_name",
        ]
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster_name} · **ns:** $${resource.label.namespace_name} · **pod:** $${resource.label.pod_name}
      Runbook: `docs/monitoring.md#container-restart-storm`
    EOT
  }
}

# 4. Deployment has no available replicas
resource "google_monitoring_alert_policy" "deployment_no_ready_replicas" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Deployment has no available replicas"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "available replicas == 0 for a deployment, 5m"

    condition_threshold {
      # Rewritten 2026-09-03: the original kubernetes.io/pod/status/ready
      # design was UNVERIFIED and turned out not to exist in this project
      # at all — confirmed via a live metricDescriptors query, no
      # kubernetes.io/pod/* metric has anything to do with readiness.
      # This project's kube-state-metrics IS scraped via GMP though
      # (prometheus.googleapis.com/kube_*), confirmed live with exactly
      # two labels: env, deployment. That gives a real per-Deployment
      # "available replicas" gauge directly, no need to infer deployment
      # ownership from pod-level metadata.system_labels the way the
      # original design did.
      #
      # CAVEAT (design decision, not a bug): this fires for ANY
      # deployment with 0 available replicas, including ones deliberately
      # scaled to 0 — fhir-gateway is permanently 0/0 in aa-stg
      # (fhir-gateway-cron serves its traffic instead; see
      # observability-plan.md). Add
      # `AND metric.label.deployment != "fhir-gateway"` to the filter
      # below if that false-positive isn't acceptable once this soaks.
      filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/kube_deployment_status_replicas_available/gauge"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
        group_by_fields    = ["metric.label.deployment"]
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster} · **deployment:** $${metric.label.deployment}
      Runbook: `docs/monitoring.md#deployment-has-no-ready-replicas`
    EOT
  }
}

# 5. Cloud SQL disk utilisation
resource "google_monitoring_alert_policy" "cloudsql_disk_utilization" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Cloud SQL disk utilisation"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "disk utilisation > 0.85 for 10m"

    condition_threshold {
      # database_id is "<project_id>:<instance_name>". Instance name is
      # "${local.cluster_name}-pg" in envs/{staging,production}/main.tf,
      # and local.cluster_name there is literally "aa-${env_short}" — i.e.
      # each.key here ("aa-stg" / "aa-prod") plus "-pg" IS the instance
      # name (see terraform/envs/staging/main.tf).
      filter = <<-EOT
        resource.type = "cloudsql_database" AND
        resource.label."database_id" = "${var.project_id}:${each.key}-pg" AND
        metric.type = "cloudsql.googleapis.com/database/disk/utilization"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.database_id}
      Runbook: `docs/monitoring.md#cloud-sql-disk-utilisation`
    EOT
  }
}

# 6. Cloud SQL CPU
resource "google_monitoring_alert_policy" "cloudsql_cpu" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Cloud SQL CPU utilisation"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "CPU utilisation > 0.90 for 15m"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database" AND
        resource.label."database_id" = "${var.project_id}:${each.key}-pg" AND
        metric.type = "cloudsql.googleapis.com/database/cpu/utilization"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.90
      duration        = "900s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.database_id}
      Runbook: `docs/monitoring.md#cloud-sql-cpu-utilisation`
    EOT
  }
}

# 7. Cloud SQL instance down
resource "google_monitoring_alert_policy" "cloudsql_instance_down" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Cloud SQL instance down"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "database/up == 0 for 5m"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database" AND
        resource.label."database_id" = "${var.project_id}:${each.key}-pg" AND
        metric.type = "cloudsql.googleapis.com/database/up"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  notification_channels = each.value.channels
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = each.value.tier
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.database_id}
      Runbook: `docs/monitoring.md#cloud-sql-instance-down`
    EOT
  }
}

# ---------------------------------------------------------------------------
# Warn tier — email only, both envs, regardless of each env's own `tier` in
# local.envs above (that field only shapes page-class routing). Also carries
# notification_rate_limit so a flapping condition (staging node pressure is
# the usual example) can't
# flood the inbox: one notification per policy per 30m.
# ---------------------------------------------------------------------------

# 8. Node pressure — CPU or memory > 90% committed for 30m, one policy with
# two OR'd conditions (not two policies) so a single incident represents
# "this node is under pressure" regardless of which resource tripped it —
# matches the "CPU or memory" phrasing for this one policy.
resource "google_monitoring_alert_policy" "node_pressure" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Node CPU/memory pressure"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "node CPU allocatable committed > 90%, 30m"

    condition_threshold {
      # kubernetes.io/node/cpu/allocatable_utilization is confirmed present
      # in GKE's own "Perform proactive monitoring with Cloud Monitoring"
      # doc (fetched before use) alongside
      # kubernetes.io/container/cpu/limit_utilization.
      filter = <<-EOT
        resource.type = "k8s_node" AND
        resource.label."cluster_name" = "${each.key}" AND
        metric.type = "kubernetes.io/node/cpu/allocatable_utilization"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.90
      duration        = "1800s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "node memory allocatable committed > 90%, 30m"

    condition_threshold {
      # UNVERIFIED metric name: follows the same cpu/memory pairing pattern
      # as the confirmed CPU metric above, but was not independently seen
      # in the fetched GKE doc excerpt. Verify against Metrics Explorer
      # before relying on this condition specifically.
      filter = <<-EOT
        resource.type = "k8s_node" AND
        resource.label."cluster_name" = "${each.key}" AND
        metric.type = "kubernetes.io/node/memory/allocatable_utilization"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.90
      duration        = "1800s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.email_only
  alert_strategy {
    # notification_rate_limit removed 2026-09-03: Cloud Monitoring rejects
    # it on non-log-based policies ("only log-based alert policies may
    # specify a notification rate limit") — confirmed via a real apply
    # error. auto_close is the only flap-control available to
    # condition_threshold/condition_absent policies.
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = "warn"
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster_name} · **node:** $${resource.label.node_name}
      Runbook: `docs/monitoring.md#node-cpu-memory-pressure`
    EOT
  }
}

# 9. Metrics collection stopped — an absence condition, not a threshold.
# Without this, every other Prometheus-sourced policy in this file fails
# silently open if the collector stops scraping — the most dangerous
# failure mode a monitoring stack can have, per the framing.
resource "google_monitoring_alert_policy" "metrics_collection_stopped" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] Prometheus scrape target down"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "no sample from a scrape job for 15m"

    condition_absent {
      # UNVERIFIED: this assumes GMP's collector synthesizes a per-target
      # `up` gauge the way self-hosted Prometheus does (GMP's collector is a
      # modified Prometheus binary, so this is plausible, but it was not
      # confirmed against a live Metrics Explorer query). If
      # prometheus.googleapis.com/up/gauge does not exist, the safer
      # fallback is a condition_absent per confirmed-live metric instead
      # (e.g. nginx_ingress_controller_requests/counter for the ingress-nginx
      # job specifically) — that only detects that ONE job going silent
      # rather than any job, which is a materially weaker guarantee this
      # policy exists specifically to provide. Verify before relying on it.
      filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/up/gauge"
      EOT

      duration = "900s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields = [
          "resource.label.namespace",
          "resource.label.job",
        ]
      }
    }
  }

  notification_channels = local.email_only
  alert_strategy {
    # notification_rate_limit removed 2026-09-03: Cloud Monitoring rejects
    # it on non-log-based policies ("only log-based alert policies may
    # specify a notification rate limit") — confirmed via a real apply
    # error. auto_close is the only flap-control available to
    # condition_threshold/condition_absent policies.
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = "warn"
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster} · **job:** $${resource.label.job}
      Runbook: `docs/monitoring.md#prometheus-scrape-target-down`
    EOT
  }
}

# 10. JVM heap pressure (HAPI + Keycloak)
#
# HAPI exposes metrics at /actuator/prometheus
# (components/hapi-fhir/overlays/staging/podmonitoring.yaml) and Keycloak at
# /auth/realms/master/metrics (components/keycloak/values-staging.yaml
# extraDeploy:). jvm_memory_used_bytes / jvm_memory_max_bytes with an
# `area="heap"` label are standard Micrometer JVM binder metrics; confirm
# they appear in both scrape outputs before enabling. Not
filtered to a specific job on purpose — it covers whichever of the two
# (or both) are actually exporting these metric names.
resource "google_monitoring_alert_policy" "jvm_heap_pressure" {
  for_each = local.envs

  project      = var.project_id
  display_name = "[${each.key}] JVM heap pressure"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "heap used / heap max > 0.85, 15m"

    condition_threshold {
      filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/jvm_memory_used_bytes/gauge" AND
        metric.label."area" = "heap"
      EOT
      denominator_filter = <<-EOT
        resource.type = "prometheus_target" AND
        resource.label."cluster" = "${each.key}" AND
        metric.type = "prometheus.googleapis.com/jvm_memory_max_bytes/gauge" AND
        metric.label."area" = "heap"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "900s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.namespace", "resource.label.job"]
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.namespace", "resource.label.job"]
      }
    }
  }

  notification_channels = local.email_only
  alert_strategy {
    # notification_rate_limit removed 2026-09-03: Cloud Monitoring rejects
    # it on non-log-based policies ("only log-based alert policies may
    # specify a notification rate limit") — confirmed via a real apply
    # error. auto_close is the only flap-control available to
    # condition_threshold/condition_absent policies.
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = "warn"
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      **env:** $${resource.label.cluster} · **job:** $${resource.label.job}
      Runbook: `docs/monitoring.md#jvm-heap-pressure`
    EOT
  }
}

# 11. Certificate expiry < 14 days, via uptime-check SSL validation.
# Google-managed certs on this LB auto-renew and have no "days until expiry"
# metric of their own, but an uptime check with validate_ssl=true populates
# monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires (a
# gauge, in days) for whatever cert it sees.
#
# UNVERIFIED: before enabling, confirm in Metrics Explorer that
# resource.type="uptime_url" AND metric.type="monitoring.googleapis.com/
# uptime_check/time_until_ssl_cert_expires", filtered to each check's
# check_id, returns a real value. If DNS for a hostname does not yet point at
# the load balancer, its check reports the endpoint unreachable instead.

locals {
  # env key here doubles as the alert's env label; "platform" for argocd
  # since it isn't part of the aa-stg/aa-prod app-tier split local.envs
  # models above — argocd is its own shared-platform hostname, not scoped
  # to either app environment.
  uptime_hosts = {
    "aa-stg"   = "staging.example.org"
    "aa-prod"  = "production.example.org"
    "platform" = "argocd.example.org"
  }
}

resource "google_monitoring_uptime_check_config" "public_hostname" {
  for_each = local.uptime_hosts

  project      = var.project_id
  display_name = "Public hostname TLS — ${each.value}"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = "443"
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = each.value
    }
  }
}

resource "google_monitoring_alert_policy" "cert_expiry" {
  for_each = local.uptime_hosts

  project      = var.project_id
  display_name = "[${each.key}] ${each.value} — certificate expiry < 14 days"
  combiner     = "OR"
  enabled      = var.alerts_enabled

  conditions {
    display_name = "time_until_ssl_cert_expires < 14 days"

    condition_threshold {
      filter = <<-EOT
        resource.type = "uptime_url" AND
        metric.type = "monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires" AND
        metric.label."check_id" = "${google_monitoring_uptime_check_config.public_hostname[each.key].uptime_check_id}"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 14
      duration        = "0s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.email_only
  alert_strategy {
    auto_close = "1800s"
  }
  user_labels = {
    env        = each.key
    tier       = "warn"
    managed_by = "terraform"
  }
  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Certificate for **${each.value}** expires in under 14 days.
      Google-managed certs on the platform LB auto-renew — this firing usually means renewal has stalled, not that manual action is needed first. Check the LB's managed-certificate status before assuming otherwise.
      Runbook: `docs/monitoring.md` > "Certificate expiry"
    EOT
  }
}
