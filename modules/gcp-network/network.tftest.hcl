# GCP network module behaviour.
#
# The private-services peering is the load-bearing part: Cloud SQL's private IP
# cannot be allocated without it, and without a private IP the only option left
# is a public database.

mock_provider "google" {}

variables {
  project     = "predcache"
  environment = "prod"
  region      = "europe-west3"
}

run "subnets_are_created_explicitly_not_automatically" {
  command = plan

  # auto_create_subnetworks would mint a subnet per region with permissive
  # defaults; a custom-mode VPC is the only way to know what exists.
  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "the VPC must be created in custom mode; auto-created subnets cannot be reasoned about."
  }
}

run "subnet_is_regional_and_logged" {
  command = plan

  assert {
    condition     = google_compute_subnetwork.this.region == "europe-west3"
    error_message = "the subnet must be created in the stack's region."
  }

  assert {
    condition     = length(google_compute_subnetwork.this.log_config) == 1
    error_message = "VPC flow logs must be enabled, or a network incident has no evidence trail."
  }

  assert {
    condition     = google_compute_subnetwork.this.log_config[0].flow_sampling > 0
    error_message = "flow sampling must be above zero for logs to be produced at all."
  }
}

run "private_services_range_is_reserved_for_peering" {
  command = plan

  assert {
    condition     = google_compute_global_address.private_services.purpose == "VPC_PEERING"
    error_message = "the reserved range must be earmarked for VPC peering."
  }

  assert {
    condition     = google_compute_global_address.private_services.address_type == "INTERNAL"
    error_message = "the peering range must be internal; a public range would expose the data tier."
  }

  assert {
    condition     = google_service_networking_connection.private_services.service == "servicenetworking.googleapis.com"
    error_message = "the service networking connection must target the service networking API."
  }
}

run "the_connector_does_not_overlap_the_subnet" {
  command = plan

  # This is the check that is expensive to get wrong: an overlapping connector
  # range fails at apply time with a message that does not name the conflict.
  assert {
    condition     = !can(cidrhost(var.connector_cidr, 0)) || !can(cidrhost(var.subnet_cidr, 0)) || cidrsubnet(var.subnet_cidr, 28 - 20, 0) != var.connector_cidr
    error_message = "the connector CIDR must be a dedicated range that does not overlap the primary subnet."
  }

  assert {
    condition     = google_vpc_access_connector.this.max_instances >= google_vpc_access_connector.this.min_instances
    error_message = "connector min_instances must not exceed max_instances."
  }
}

run "internal_traffic_is_allowed_on_the_data_ports_only" {
  command = plan

  assert {
    condition     = google_compute_firewall.allow_internal.direction == "INGRESS"
    error_message = "the internal rule must be an ingress rule."
  }

  # Postgres, Redis and the app port. An unrestricted allow-all protocol here
  # would make the firewall decorative.
  assert {
    condition = alltrue([
      for a in google_compute_firewall.allow_internal.allow :
      a.protocol == "tcp" && length(a.ports) > 0
    ])
    error_message = "the internal firewall rule must name TCP ports; an all-protocol allow makes the rule meaningless."
  }

  assert {
    condition = alltrue([
      for a in google_compute_firewall.allow_internal.allow :
      !contains(a.ports, "0") && !contains(a.ports, "*")
    ])
    error_message = "the rule must not open every port."
  }
}
