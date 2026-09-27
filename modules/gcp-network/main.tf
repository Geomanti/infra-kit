# Provider versions are pinned here as well as in the stacks.
# Without this, running `terraform init` inside a module resolves the latest
# major version, so a module tested standalone would exercise a different
# provider than the stack that consumes it in production.
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# GCP network: a custom VPC, regional subnet, Private Service Access for
# Cloud SQL, and a Serverless VPC Access connector so Cloud Run can reach
# private resources without a public egress path.
#
# The design note: Cloud Run is private by default in the sense that its egress
# is public unless a connector is attached. Attaching the connector is what
# makes the database reachable without ever exposing it, and that is why the
# connector is part of the network module rather than the service module.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }

variable "subnet_cidr" {
  description = "Primary subnet CIDR."
  type        = string
  default     = "10.10.0.0/20"
}

variable "connector_cidr" {
  description = "Dedicated /28 for the Serverless VPC Access connector. Must not overlap the subnet."
  type        = string
  default     = "10.10.15.0/28"
}

variable "extra_labels" {
  type    = map(string)
  default = {}
}

locals {
  name   = "${var.project}-${var.environment}"
  labels = merge({ project = var.project, environment = var.environment, managed_by = "terraform" }, var.extra_labels)
}

resource "google_compute_network" "this" {
  name                    = local.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name          = "${local.name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id

  # VPC flow logs are what make a network incident diagnosable after the fact.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_global_address" "private_services" {
  name          = "${local.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.this.id
}

# Cloud SQL private IP requires the service networking connection; without it
# the instance has no private address and the only option left is a public one.
resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

resource "google_vpc_access_connector" "this" {
  name          = substr("${local.name}-conn", 0, 25)
  region        = var.region
  ip_cidr_range = var.connector_cidr
  network       = google_compute_network.this.name

  min_instances = 2
  max_instances = 3

  depends_on = [google_compute_subnetwork.this]
}

resource "google_compute_firewall" "allow_internal" {
  name      = "${local.name}-allow-internal"
  network   = google_compute_network.this.name
  direction = "INGRESS"

  source_ranges = [var.subnet_cidr, var.connector_cidr]

  allow {
    protocol = "tcp"
    ports    = ["5432", "6379", "8080"]
  }
}
