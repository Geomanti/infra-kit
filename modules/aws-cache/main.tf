# Provider versions are pinned here as well as in the stacks.
# Without this, running `terraform init` inside a module resolves the latest
# major version, so a module tested standalone would exercise a different
# provider than the stack that consumes it in production.
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Cache tier: ElastiCache Redis replication group with a subnet group and
# access-controlled security group.
#
# The design note: this module exists because a cache is the tier that is most
# often deployed without an eviction policy or a failover plan, and both are
# exactly the settings that decide whether a cache becomes a load source.
# `maxmemory-policy` is set explicitly for that reason, and Multi-AZ failover
# is an input rather than an afterthought.

variable "project" { type = string }
variable "environment" { type = string }
variable "component" {
  type    = string
  default = "cache"
}

variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "allowed_security_group_ids" {
  description = "Security groups permitted to reach Redis."
  type        = list(string)
  default     = []
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "Nodes in the replication group. 1 = no replica; a failover with no replica has nothing to promote."
  type        = number
  default     = 1

  validation {
    condition     = var.num_cache_clusters >= 1 && var.num_cache_clusters <= 6
    error_message = "num_cache_clusters must be between 1 and 6."
  }
}

variable "automatic_failover" {
  description = "Promote a replica automatically when the primary fails. Requires at least one replica."
  type        = bool
  default     = false
}

variable "maxmemory_policy" {
  description = "Eviction policy. allkeys-lru is the safe default for a pure cache; use noeviction only for a store you cannot lose."
  type        = string
  default     = "allkeys-lru"

  validation {
    condition = contains([
      "allkeys-lru", "allkeys-lfu", "allkeys-random",
      "volatile-lru", "volatile-lfu", "volatile-random", "volatile-ttl",
      "noeviction",
    ], var.maxmemory_policy)
    error_message = "maxmemory_policy must be a valid Redis eviction policy."
  }
}

variable "snapshot_retention_days" {
  type    = number
  default = 0
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"
  tags = merge({ Project = var.project, Environment = var.environment, Component = var.component, ManagedBy = "terraform" }, var.extra_tags)
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = local.tags
}

resource "aws_security_group" "cache" {
  name        = local.name
  description = "Redis access for ${local.name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.allowed_security_group_ids
    content {
      description     = "Redis from an authorised application security group"
      from_port       = 6379
      to_port         = 6379
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  tags = merge(local.tags, { Name = local.name })
}

resource "aws_elasticache_parameter_group" "this" {
  name   = local.name
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = var.maxmemory_policy
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "${local.name} Redis"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.automatic_failover && var.num_cache_clusters > 1
  multi_az_enabled           = var.automatic_failover && var.num_cache_clusters > 1

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.cache.id]
  parameter_group_name = aws_elasticache_parameter_group.this.name

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = var.snapshot_retention_days
  apply_immediately        = var.environment != "prod"

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !var.automatic_failover || var.num_cache_clusters > 1
      error_message = "automatic_failover requires num_cache_clusters > 1; there is no replica to promote otherwise."
    }
  }
}
