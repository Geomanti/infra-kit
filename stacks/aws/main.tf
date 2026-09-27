# AWS stack: one deployable service, composed from the modules.
#
# This is the file a reviewer reads to understand the whole system in one pass.
# Every resource is created by a module; nothing is defined inline. The stack's
# job is to wire module outputs to module inputs and to hold the values that are
# genuinely deployment-specific.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # ECS/ALB metrics are keyed by ARN *suffixes*, not full ARNs — and the two
  # resource types want different shapes, which is the subtle part:
  #
  #   ALB ARN:          ...:loadbalancer/app/<name>/<hash>   ->  dimension "app/<name>/<hash>"
  #   Target group ARN: ...:targetgroup/<name>/<hash>        ->  dimension "targetgroup/<name>/<hash>"
  #
  # So the ALB suffix drops its "loadbalancer/" segment while the target group
  # keeps its "targetgroup/" one. Getting this wrong produces an alarm that
  # silently watches nothing, which is worse than having no alarm at all — the
  # integration test in stack.tftest.hcl asserts the resulting shape, and caught
  # exactly this bug on the first run.
  alb_arn_suffix = regex("^.*:loadbalancer/(.*)$", module.service.alb_arn)[0]
  target_group_arn_suffix = "targetgroup/${regex(
    "^.*:targetgroup/(.*)$", module.service.target_group_arn
  )[0]}"
}

module "network" {
  source = "../../modules/aws-network"

  project     = var.project
  environment = var.environment
  region      = var.region

  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  extra_tags         = local.tags
}

module "postgres" {
  source = "../../modules/aws-postgres"

  project     = var.project
  environment = var.environment
  component   = "db"

  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  engine_version             = var.postgres_engine_version
  instance_class             = var.postgres_instance_class
  allocated_storage          = var.postgres_allocated_storage
  multi_az                   = var.environment == "prod"
  backup_retention_days      = var.postgres_backup_retention_days
  deletion_protection        = var.environment == "prod"
  allowed_security_group_ids = [module.service.task_security_group_id]
  extra_tags                 = local.tags
}

module "cache" {
  source = "../../modules/aws-cache"

  project     = var.project
  environment = var.environment
  component   = "cache"

  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.private_subnet_ids
  node_type                  = var.cache_node_type
  num_cache_clusters         = var.cache_num_clusters
  automatic_failover         = var.cache_automatic_failover
  maxmemory_policy           = var.cache_maxmemory_policy
  snapshot_retention_days    = var.environment == "prod" ? 7 : 0
  allowed_security_group_ids = [module.service.task_security_group_id]
  extra_tags                 = local.tags
}

module "service" {
  source = "../../modules/aws-container-service"

  project     = var.project
  environment = var.environment
  region      = var.region
  component   = var.service_component

  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.private_subnet_ids
  load_balancer_subnet_ids = module.network.public_subnet_ids
  alb_internal             = var.alb_internal

  container_image = var.container_image
  container_port  = var.container_port
  desired_count   = var.service_desired_count
  cpu             = var.service_cpu
  memory          = var.service_memory

  # The wiring that matters: connection details are injected as environment
  # variables, while the database password is injected as a secret reference.
  # A password as a plain env var would be readable by anyone with
  # ecs:DescribeTaskDefinition, which is a far wider audience than the task.
  environment_variables = merge(
    {
      APP_ENV           = var.environment
      PORT              = tostring(var.container_port)
      DATABASE_HOST     = module.postgres.address
      DATABASE_PORT     = tostring(module.postgres.port)
      DATABASE_NAME     = module.postgres.database_name
      REDIS_HOST        = module.cache.primary_endpoint
      REDIS_PORT        = tostring(module.cache.port)
      OTEL_SERVICE_NAME = "${var.project}-${var.environment}-${var.service_component}"
    },
    var.extra_environment_variables,
  )

  secrets = merge(
    module.postgres.master_user_secret_arn != null ? {
      DATABASE_PASSWORD = module.postgres.master_user_secret_arn
    } : {},
    var.extra_secrets,
  )

  health_check_path  = var.health_check_path
  log_retention_days = var.log_retention_days
  extra_tags         = local.tags
}

module "observability" {
  source = "../../modules/aws-observability"

  project     = var.project
  environment = var.environment
  region      = var.region
  component   = var.service_component

  cluster_name             = module.service.cluster_name
  service_name             = module.service.service_name
  load_balancer_arn_suffix = local.alb_arn_suffix
  target_group_arn_suffix  = local.target_group_arn_suffix
  alarm_email              = var.alarm_email
  p95_latency_threshold_ms = var.p95_latency_threshold_ms
  error_rate_threshold     = var.error_rate_threshold
  extra_tags               = local.tags
}

# ---------------------------------------------------------------------------

output "service_url" {
  description = "Load balancer DNS name — the service's entry point."
  value       = module.service.alb_dns_name
}

output "database_endpoint" {
  description = "Postgres endpoint (host:port)."
  value       = module.postgres.endpoint
}

output "cache_endpoint" {
  description = "Redis primary endpoint."
  value       = module.cache.primary_endpoint
}

output "vpc_id" {
  description = "VPC id, for any out-of-band resource."
  value       = module.network.vpc_id
}

output "log_group_name" {
  description = "CloudWatch log group for the service."
  value       = module.service.log_group_name
}

output "alarm_topic_arn" {
  description = "SNS topic every alarm publishes to."
  value       = module.observability.alert_topic_arn
}

output "account_id" {
  description = "Account this stack is applied into — useful when the same stack runs in several."
  value       = data.aws_caller_identity.current.account_id
}
