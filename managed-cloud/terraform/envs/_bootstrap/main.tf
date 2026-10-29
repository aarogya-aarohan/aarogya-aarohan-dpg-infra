# API enablement on the service project is owned by the platform team and
# managed out of band — see docs/required-apis.md for the canonical list.
# The KMS keyring `aa-tf-sops` and its per-env keys are similarly platform-owned —
# see docs/deployment-guide.md (prerequisites) and the architecture guide (docs/architecture.md). This
# stack manages the Terraform state bucket and the shared bastion host.

resource "google_storage_bucket" "tf_state" {
  name                        = var.state_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = 90
      with_state                 = "ARCHIVED"
    }
  }
}

# ---------------------------------------------------------------------------
# Bastion host
# ---------------------------------------------------------------------------
#
# The bastion sits on the Shared VPC (host project: your-shared-vpc-host-project).
# Its internal IP is pinned as a static address because GKE master
# authorised-networks in every cluster reference 10.0.0.10/32.  Changing
# the IP would break kubectl access from the bastion without a coordinated
# cluster update.
#
# To recreate from a machine-image backup (e.g. after a disk-full event):
#   1. gcloud compute machine-images create img-aa-bastion-$(date +%Y%m%d) \
#        --source-instance=vm-aa-bastion \
#        --source-instance-zone=asia-south1-c \
#        --project=your-gcp-project-id
#   2. gcloud compute images create img-aa-bastion-$(date +%Y%m%d) \
#        --source-machine-image=img-aa-bastion-$(date +%Y%m%d) \
#        --project=your-gcp-project-id
#   3. terraform destroy -target=google_compute_instance.bastion (stops billing)
#   4. Set bastion_boot_image = "projects/your-gcp-project-id/global/images/img-aa-bastion-YYYYMMDD"
#      and bastion_disk_size_gb = 100, then terraform apply.
#      The static IP reservation (google_compute_address.bastion) is left intact
#      throughout so the address is never released back to the pool.

locals {
  bastion_subnet_self_link = "projects/${var.host_project_id}/regions/${var.region}/subnetworks/${var.bastion_subnet}"
}

resource "google_compute_address" "bastion" {
  name         = "ip-aa-bastion"
  project      = var.project_id
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.bastion_subnet_self_link
  address      = var.bastion_ip
}

resource "google_compute_instance" "bastion" {
  name                      = "vm-aa-bastion"
  project                   = var.project_id
  zone                      = var.bastion_zone
  machine_type              = var.bastion_machine_type
  deletion_protection       = true
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.bastion_boot_image
      size  = var.bastion_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork         = local.bastion_subnet_self_link
    subnetwork_project = var.host_project_id
    network_ip         = google_compute_address.bastion.address
    # No access_config block — no external IP; access is via IAP tunnel.
  }

  service_account {
    email  = var.bastion_service_account
    scopes = ["cloud-platform"]
  }

  tags = ["net-vm-aa-bastion"]

  labels = {
    goog-ops-agent-policy = "v2-template-1-5-0"
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  lifecycle {
    # boot_disk.initialize_params reflects the image at creation time (full versioned URL);
    # ignoring prevents spurious ForceNew diffs when the image family resolves to a new version.
    # metadata and labels are managed by platform policies.
    ignore_changes = [boot_disk, metadata, labels]
  }
}
