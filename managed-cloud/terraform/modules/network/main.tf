module "vpc" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 9.3"
  project_id   = var.project_id
  network_name = var.vpc_name
  routing_mode = "REGIONAL"

  subnets = [
    for s in var.subnets : {
      subnet_name           = "aa-${s.short_name}-subnet"
      subnet_ip             = s.primary_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
    }
  ]

  secondary_ranges = {
    for s in var.subnets : "aa-${s.short_name}-subnet" => [
      { range_name = "pods", ip_cidr_range = s.pods_cidr },
      { range_name = "services", ip_cidr_range = s.services_cidr },
    ]
  }
}

resource "google_compute_router" "nat" {
  name    = "aa-nat-router"
  project = var.project_id
  region  = var.region
  network = module.vpc.network_self_link
}

resource "google_compute_router_nat" "nat" {
  name                               = "aa-nat"
  project                            = var.project_id
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "iap" {
  name      = "aa-allow-iap"
  project   = var.project_id
  network   = module.vpc.network_self_link
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["aa-iap"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }
}

resource "google_compute_firewall" "internal" {
  name      = "aa-allow-internal"
  project   = var.project_id
  network   = module.vpc.network_self_link
  direction = "INGRESS"
  priority  = 1000

  source_ranges = [for s in var.subnets : s.primary_cidr]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}
