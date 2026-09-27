output "name" {
  description = "Canonical resource name: <project>-<environment>-<component>."
  value       = local.name
}

output "tags" {
  description = "AWS tag map (Name, Project, Environment, Component, Region, ManagedBy) with caller overrides applied."
  value       = local.tags
}

output "labels" {
  description = "GCP label map derived from the same inputs, lowercased and normalised to GCP's legal character set."
  value       = local.labels
}

output "log_group_name" {
  description = "Log destination convention shared by CloudWatch and Cloud Logging."
  value       = local.log_group_name
}
