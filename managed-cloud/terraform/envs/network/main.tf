locals {
  vpc_self_link    = "https://www.googleapis.com/compute/v1/projects/${var.shared_vpc_host_project_id}/global/networks/${var.shared_vpc_name}"
  subnet_self_link = "https://www.googleapis.com/compute/v1/projects/${var.shared_vpc_host_project_id}/regions/${var.region}/subnetworks/${var.shared_subnet_name}"
}
