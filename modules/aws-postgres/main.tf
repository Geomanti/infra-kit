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

# Managed Postgres (RDS): instance, subnet group and parameter group.
#
# Decisions worth naming:
# - Storage is encrypted and `storage_encrypted` cannot be turned off after
#   creation, so it is set unconditionally rather than left to a per-env flag.
# - Backups are retained in every environment. A dev database that cannot be
#   restored is not a database, it is a bet.
# - Multi-AZ is driven by the environment, because it doubles the bill and is
#   the single setting that decides whether an AZ failure is an outage.

variable "project" { type = string }
variable "environment" { type = string }
variable "component" {
  type    = string
  default = "db"
}

variable "vpc_id" { type = string }
variable "subnet_ids" {
  description = "Private subnets for the DB subnet group."
  type        = list(string)
}
variable "allowed_security_group_ids" {
  description = "Security groups permitted to reach Postgres. Nothing else is."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  description = "Postgres major.minor. Pin it; the default moves under you."
  type        = string
  default     = "16.3"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling. 0 disables autoscaling."
  type        = number
  default     = 100
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = "app"
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"
  tags = merge({ Project = var.project, Environment = var.environment, Component = var.component, ManagedBy = "terraform" }, var.extra_tags)
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = local.tags
}

resource "aws_security_group" "db" {
  name        = local.name
  description = "Postgres access for ${local.name}"
  vpc_id      = var.vpc_id

  # Sources are security groups, never CIDRs — so the rule survives a subnet
  # renumber and cannot accidentally expose the database to a whole block.
  dynamic "ingress" {
    for_each = var.allowed_security_group_ids
    content {
      description     = "Postgres from an authorised application security group"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  tags = merge(local.tags, { Name = local.name })
}

resource "aws_db_parameter_group" "this" {
  name   = local.name
  family = "postgres${split(".", var.engine_version)[0]}"

  # Log slow queries; without this a performance incident has no evidence trail.
  parameter {
    name  = "log_min_duration_statement"
    value = var.environment == "prod" ? "1000" : "500"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  tags = local.tags
}

resource "aws_db_instance" "this" {
  identifier = local.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username
  # No password argument: RDS manages it in Secrets Manager, so no credential
  # is ever written into Terraform state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az            = var.multi_az
  publicly_accessible = false

  backup_retention_period   = var.backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name}-final" : null
  deletion_protection       = var.deletion_protection

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.backup_retention_days >= 1
      error_message = "backup_retention_days must be at least 1; a database with no backups is not recoverable."
    }

    precondition {
      condition     = var.environment == "prod" ? var.multi_az : true
      error_message = "multi_az must be true in prod — a single-AZ production database makes an AZ failure a full outage."
    }
  }
}
