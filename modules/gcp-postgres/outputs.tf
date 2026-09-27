output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "Instance connection name (project:region:instance), used by the Cloud SQL connector."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  description = "Private IP. There is no public one; ipv4_enabled is false."
  value       = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  description = "Initial database name."
  value       = google_sql_database.this.name
}

output "database_user" {
  description = "Application database user."
  value       = google_sql_user.this.name
}

output "password_secret_id" {
  description = "Secret Manager secret id holding the generated password. Reference it; never read it into a variable."
  value       = google_secret_manager_secret.db_password.secret_id
}

# --- safety surface ---------------------------------------------------------
# Exposed so a stack can assert its own posture without reaching through to the
# resources, and so an operator can read the settings rather than checking the
# console.

output "has_public_ip" {
  description = "Whether the instance has a public IPv4 address. Should always be false."
  value       = google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled
}

output "ssl_mode" {
  description = "Effective TLS policy for connections."
  value       = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode
}

output "availability_type" {
  description = "ZONAL or REGIONAL availability."
  value       = google_sql_database_instance.this.settings[0].availability_type
}

output "backups_enabled" {
  description = "Whether automated backups are on."
  value       = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled
}

output "point_in_time_recovery_enabled" {
  description = "Whether PITR is on — this is what makes an accidental DELETE recoverable."
  value       = google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled
}

output "deletion_protection" {
  description = "Whether the instance is protected against accidental deletion."
  value       = google_sql_database_instance.this.deletion_protection
}

output "labels" {
  description = "Labels applied to the database resources."
  value       = local.labels
}
