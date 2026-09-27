# GCP stack: one deployable service, composed from the modules.
#
# This is the Supabase-relevant half of the repo: a Python service on Cloud Run
# with a private Cloud SQL Postgres, a dedicated least-privilege runtime
# identity, secrets by reference, and an autoscaling ceiling — all of it
# declared, none of it clicked together in a console.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
  }
}

module "network" {
  source = "../../modules/gcp-network"

  project     = var.project
  environment = var.environment
  region      = var.region

  subnet_cidr    = var.subnet_cidr
  connector_cidr = var.connector_cidr
  extra_labels   = local.labels
}

module "postgres" {
  source = "../../modules/gcp-postgres"

  project     = var.project
  environment = var.environment
  region      = var.region

  network_id                  = module.network.network_id
  private_services_connection = module.network.private_services_connection

  tier              = var.postgres_tier
  database_version  = var.postgres_version
  database_name     = var.postgres_database_name
  disk_size_gb      = var.postgres_disk_size_gb
  availability_type = var.environment == "prod" ? "REGIONAL" : "ZONAL"
  backup_enabled    = var.postgres_backup_enabled
  extra_labels      = local.labels
}

module "service" {
  source = "../../modules/gcp-service"

  project     = var.project
  environment = var.environment
  region      = var.region
  component   = var.service_component

  container_image = var.container_image
  container_port  = var.container_port
  cpu             = var.service_cpu
  memory          = var.service_memory

  min_instance_count = var.service_min_instances
  max_instance_count = var.service_max_instances

  # The wiring that matters: the database connection is by private IP, reached
  # through the connector, and the credential is mounted from Secret Manager by
  # reference. Nothing here is a literal.
  vpc_connector_id = module.network.connector_id

  environment_variables = merge(
    {
      APP_ENV                  = var.environment
      PORT                     = tostring(var.container_port)
      DATABASE_HOST            = module.postgres.private_ip_address
      DATABASE_NAME            = module.postgres.database_name
      DATABASE_USER            = module.postgres.database_user
      DATABASE_CONNECTION_NAME = module.postgres.connection_name
      OTEL_SERVICE_NAME        = "${var.project}-${var.environment}-${var.service_component}"
    },
    var.extra_environment_variables,
  )

  secret_environment_variables = merge(
    {
      DATABASE_PASSWORD = module.postgres.password_secret_id
    },
    var.extra_secret_environment_variables,
  )

  ingress               = var.ingress
  allow_unauthenticated = var.allow_unauthenticated
  extra_labels          = local.labels
}

# ---------------------------------------------------------------------------

output "service_url" {
  description = "Cloud Run service URL."
  value       = module.service.service_url
}

output "service_account_email" {
  description = "Runtime identity. Starts with no roles; grant only what the workload needs."
  value       = module.service.service_account_email
}

output "database_private_ip" {
  description = "Private IP of the database. There is no public address."
  value       = module.postgres.private_ip_address
}

output "database_connection_name" {
  description = "Cloud SQL connection name for the connector library."
  value       = module.postgres.connection_name
}

output "database_password_secret_id" {
  description = "Secret Manager secret holding the generated password."
  value       = module.postgres.password_secret_id
}

output "network_id" {
  description = "VPC network id."
  value       = module.network.network_id
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector used for private egress."
  value       = module.network.connector_id
}
