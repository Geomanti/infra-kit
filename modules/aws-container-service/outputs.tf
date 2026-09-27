output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "cluster_name" {
  description = "Cluster name, for metrics dimensions and autoscaling."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "Cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "task_definition_arn" {
  description = "The task definition revision currently targeted."
  value       = aws_ecs_task_definition.this.arn
}

output "task_security_group_id" {
  description = "Security group attached to tasks — grant it to the data tiers so only this service can reach them."
  value       = aws_security_group.task.id
}

output "alb_security_group_id" {
  description = "Security group attached to the load balancer. Must never be granted to a data tier."
  value       = aws_security_group.alb.id
}

output "alb_arn" {
  description = "Load balancer ARN (the observability module derives its metric suffix from this)."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Public (or internal) DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "alb_internal" {
  description = "Whether the load balancer is internal-only."
  value       = aws_lb.this.internal
}

output "target_group_arn" {
  description = "Target group backing the listener, for autoscaling attachment."
  value       = aws_lb_target_group.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving container logs."
  value       = aws_cloudwatch_log_group.this.name
}

# --- deployment surface -----------------------------------------------------
# The outputs below exist so a stack can verify its own composition without
# reading through to the underlying resources. They are also the values worth
# asserting in CI, which is why the stack's integration test reads them.

output "subnet_ids" {
  description = "Subnets the tasks are placed in."
  value       = var.subnet_ids
}

output "assign_public_ip" {
  description = "Whether tasks receive public IPs. Must be false for private-subnet placement."
  value       = aws_ecs_service.this.network_configuration[0].assign_public_ip
}

output "desired_count" {
  description = "Configured task count at creation (autoscaling owns it afterwards)."
  value       = var.desired_count
}

output "task_cpu" {
  description = "Fargate task CPU units."
  value       = aws_ecs_task_definition.this.cpu
}

output "task_memory" {
  description = "Fargate task memory in MiB."
  value       = aws_ecs_task_definition.this.memory
}

output "deployment_circuit_breaker" {
  description = "Rollout safety settings: whether the circuit breaker is enabled and whether it rolls back."
  value = {
    enabled  = aws_ecs_service.this.deployment_circuit_breaker[0].enable
    rollback = aws_ecs_service.this.deployment_circuit_breaker[0].rollback
  }
}

output "execute_command_enabled" {
  description = "Whether interactive execute-command is available in the container."
  value       = aws_ecs_service.this.enable_execute_command
}

output "deletion_protection" {
  description = "Whether the load balancer is protected against accidental deletion."
  value       = aws_lb.this.enable_deletion_protection
}

# --- what the container actually receives -----------------------------------
# These two are the composition contract. Reading them is how a caller verifies
# the service was handed the right endpoints, and — more importantly — that no
# credential was passed as a plain environment variable.

output "container_environment" {
  description = "Plain environment variables the container will receive."
  value       = var.environment_variables
}

output "container_secrets" {
  description = "Secret name -> Secrets Manager/SSM ARN. Never contains a literal value."
  value       = var.secrets
}

output "tags" {
  description = "Tags applied to the service's resources."
  value       = local.tags
}
