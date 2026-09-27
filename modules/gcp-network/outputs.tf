output "network_id" {
  description = "VPC network id."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "VPC network name, for resources that take a name rather than an id."
  value       = google_compute_network.this.name
}

output "subnet_id" {
  description = "Primary subnetwork id."
  value       = google_compute_subnetwork.this.id
}

output "connector_id" {
  description = "Serverless VPC Access connector id, for Cloud Run's vpc_access block."
  value       = google_vpc_access_connector.this.id
}

output "private_services_connection" {
  description = "Service networking peering connection id — Cloud SQL depends on this existing first."
  value       = google_service_networking_connection.private_services.id
}

output "labels" {
  description = "Labels applied to the network resources."
  value       = local.labels
}
