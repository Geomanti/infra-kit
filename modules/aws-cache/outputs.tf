output "primary_endpoint" {
  description = "Primary endpoint for writes."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader endpoint for read scaling."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Redis port."
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "Security group to grant to any additional client."
  value       = aws_security_group.cache.id
}

output "allowed_client_security_group_ids" {
  description = "Security groups authorised to connect. The complete ingress list — nothing outside it can reach the cache."
  value       = var.allowed_security_group_ids
}

output "replication_group_id" {
  description = "Replication group identifier."
  value       = aws_elasticache_replication_group.this.id
}

output "maxmemory_policy" {
  description = "Configured eviction policy. noeviction turns a full cache into write errors."
  value       = var.maxmemory_policy
}

output "automatic_failover_enabled" {
  description = "Whether a replica is promoted automatically on primary failure."
  value       = aws_elasticache_replication_group.this.automatic_failover_enabled
}

output "tags" {
  description = "Tags applied to the cache resources."
  value       = local.tags
}
