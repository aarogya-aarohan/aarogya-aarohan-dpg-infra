variable "project_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "network_project_id" {
  type        = string
  description = "Host project that owns the Shared VPC network."
}

variable "network_name" {
  type        = string
  description = "Name of the Shared VPC network."
}

variable "subnet_name" {
  type        = string
  description = "Name of the subnetwork to attach the cluster to."
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "master_ipv4_cidr" {
  type = string
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "enable_private_endpoint" {
  type    = bool
  default = true
}

variable "release_channel" {
  type    = string
  default = "REGULAR"
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "node_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 4
}

variable "node_service_account" {
  type        = string
  description = "account_id of the pre-created node SA shared across clusters."
}

variable "node_tags" {
  type        = list(string)
  default     = []
  description = "Network tags applied to all nodes. Used by Shared-VPC firewall rules that target tags (the host project disallows CIDR destinations in classic firewalls)."
}

variable "node_zones" {
  type        = list(string)
  default     = []
  description = "Zones for node placement within the region. Empty = spread across all zones in the region (regional default). Set to a single zone to pin nodes and avoid cross-zone egress costs; the control plane remains regional regardless."
}

# Google Managed Service for Prometheus (GMP) managed collection. This installs
# the gmp-system collector DaemonSet + PodMonitoring/ClusterPodMonitoring/
# OperatorConfig/Rules CRDs as a GKE addon — no Helm chart, no Prometheus
# server to run or patch. Defaults to true because both workload clusters
# should ship with it; the argocd hub stack passes this through unset (see
# terraform/envs/argocd/main.tf) since its system metrics are useful and
# cheap on a cluster that only runs ArgoCD itself.
variable "enable_managed_prometheus" {
  description = "Enable Google Managed Service for Prometheus managed collection (installs the gmp-system collector + PodMonitoring CRDs as a GKE addon)."
  type        = bool
  default     = true
}

# Must stay non-empty whenever enable_managed_prometheus is true. The upstream
# private-cluster module only renders monitoring_config at all when
# logmon_config_is_set = length(logging_enabled_components) > 0 ||
# length(monitoring_enabled_components) > 0 || monitoring_enable_managed_prometheus
# is true (.terraform/modules/cluster/main.tf) — so flipping managed
# Prometheus on while leaving this at its zero value would render the block
# with an empty enable_components list, which GKE reads as "turn off system
# metrics" and silently kills the kubernetes.io/* series several alert
# policies depend on. See the monitoring guide (docs/monitoring.md) for the full
# explanation. WORKLOADS is deliberately not in the default: it's the
# expensive GKE-native workload metrics pipeline, and Prometheus scraping via
# components/gmp/ covers the workloads we actually care about.
variable "monitoring_enabled_components" {
  description = "Cloud Monitoring components to collect. Must stay non-empty whenever enable_managed_prometheus is true — see the comment above."
  type        = list(string)
  # Corrected 2026-09-02: a live `terraform plan` against both aa-stg and
  # aa-prod showed the actual running clusters already have all 11 of these
  # components enabled (STORAGE/HPA/POD/DAEMONSET/DEPLOYMENT/STATEFULSET/
  # CADVISOR/KUBELET/DCGM/JOBSET on top of SYSTEM_COMPONENTS) — not just
  # SYSTEM_COMPONENTS as originally assumed here. That original default
  # would have *removed* real, already-flowing signal on apply, including
  # several kubernetes.io/{pod,container}/* metrics that
  # terraform/envs/monitoring/alerts.tf's restart-storm, no-ready-replicas,
  # and resource-pressure policies depend on. This is the exact live list,
  # so this variable now closes the Terraform/reality drift without
  # narrowing anything. If you deliberately want to trim collection later
  # (cost tradeoff), do it here deliberately and re-check which alert
  # policies would lose their data source first.
  default = [
    "SYSTEM_COMPONENTS",
    "STORAGE",
    "HPA",
    "POD",
    "DAEMONSET",
    "DEPLOYMENT",
    "STATEFULSET",
    "CADVISOR",
    "KUBELET",
    "DCGM",
    "JOBSET",
  ]
}
