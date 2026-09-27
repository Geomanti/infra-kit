output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.id
}

output "endpoint" {
  description = "Connection endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port."
  value       = aws_db_instance.this.port
}

output "security_group_id" {
  description = "Security group to grant to any additional client."
  value       = aws_security_group.db.id
}

output "allowed_client_security_group_ids" {
  description = "Security groups authorised to connect. The complete ingress list — nothing outside it can reach the database."
  value       = var.allowed_security_group_ids
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the managed master password."
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
  # Terraform treats the managed-secret block as sensitive because it is a
  # credential reference. The ARN itself is an identifier, not a secret, so this
  # flag exists to let the value flow through module boundaries (a stack passes
  # it into the container's secrets list) rather than to protect the string.
  sensitive = true
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

# --- safety surface ---------------------------------------------------------
# Exposed so a stack can assert its own posture, and so an operator can read the
# current settings without opening the console.

output "password_is_unset" {
  description = "True when no inline password is configured, i.e. RDS owns the credential. Should always be true."
  value       = aws_db_instance.this.password == null
  # Reading the password attribute taints anything derived from it, even a null
  # comparison. The flag is here to let the value cross a module boundary, not to
  # hide it — the result is a boolean and carries no credential.
  sensitive = true
}

output "storage_encrypted" {
  description = "Whether storage encryption is on. Cannot be changed after creation."
  value       = aws_db_instance.this.storage_encrypted
}

output "multi_az" {
  description = "Whether a synchronous standby is deployed."
  value       = aws_db_instance.this.multi_az
}

output "backup_retention_days" {
  description = "Backup retention period in days."
  value       = aws_db_instance.this.backup_retention_period
}

output "deletion_protection" {
  description = "Whether the instance is protected against accidental deletion."
  value       = aws_db_instance.this.deletion_protection
}

output "tags" {
  description = "Tags applied to the database resources."
  value       = local.tags
}
