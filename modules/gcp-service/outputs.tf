output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.this.name
}

output "service_url" {
  description = "Service URL. Not invokable by the public unless allow_unauthenticated is set."
  value       = google_cloud_run_v2_service.this.uri
}

output "service_account_email" {
  description = "Runtime identity. It starts with no roles — grant only what the workload needs."
  value       = google_service_account.runtime.email
}

output "location" {
  description = "Region the service is deployed in."
  value       = google_cloud_run_v2_service.this.location
}

# --- composition surface ----------------------------------------------------
# Exposed so a stack can verify what the container will actually receive, and
# assert its own exposure posture, without reading through to the resources.

output "environment_variables" {
  description = "Plain environment variables the container will receive."
  value       = var.environment_variables
}

output "secret_environment_variables" {
  description = "Secret name -> Secret Manager secret id. Mounted by reference, never as a literal."
  value       = var.secret_environment_variables
}

output "ingress" {
  description = "Effective ingress policy."
  value       = google_cloud_run_v2_service.this.ingress
}

output "ingress_is_restrictive" {
  description = "True when ingress is limited to internal traffic only."
  value       = google_cloud_run_v2_service.this.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY"
}

output "allow_unauthenticated" {
  description = "Whether the service is publicly invokable. Should be false unless deliberately opened."
  value       = var.allow_unauthenticated
}

output "public_invoker_granted" {
  description = "Whether an allUsers invoker binding exists."
  value       = length(google_cloud_run_v2_service_iam_member.public) > 0
}

output "min_instance_count" {
  description = "Minimum instances. 0 means scale-to-zero."
  value       = google_cloud_run_v2_service.this.template[0].scaling[0].min_instance_count
}

output "max_instance_count" {
  description = "Maximum instances. The hard ceiling on autoscaling."
  value       = google_cloud_run_v2_service.this.template[0].scaling[0].max_instance_count
}

output "container_image" {
  description = "Image currently referenced by the service."
  value       = var.container_image
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector attached to the service, or an empty string."
  value       = var.vpc_connector_id
}

output "labels" {
  description = "Labels applied to the service."
  value       = local.labels
}

output "runtime_uses_default_identity" {
  description = "True if the runtime identity is the shared default compute account. Should always be false."
  value       = can(regex("-compute@developer.gserviceaccount.com", google_service_account.runtime.email))
}
