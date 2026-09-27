# Cloud SQL Postgres with private IP only.
#
# The decision worth stating: `ipv4_enabled = false` is the default here. A
# Cloud SQL instance with a public IPv4 address is reachable from the internet
# subject to IAM and network rules; with no public address, the attack surface
# is the VPC peering and nothing else. That is a one-line difference that
# changes the threat model, so it is the default rather than a flag.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "component" {
  type    = string
  default = "db"
}

variable "network_id" {
  description = "VPC network id to attach the private IP to."
  type        = string
}

variable "private_services_connection" {
  description = "The service networking connection id; Cloud SQL's private IP needs it to exist first."
  type        = string
}

variable "tier" {
  description = "Machine tier. db-f1-micro is the cheapest shared-core option, db-custom-* for real workloads."
  type        = string
  default     = "db-f1-micro"
}

variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "database_user" {
  type    = string
  default = "app"
}

variable "disk_size_gb" {
  type    = number
  default = 20

  validation {
    condition     = var.disk_size_gb >= 10
    error_message = "disk_size_gb must be at least 10."
  }
}

variable "availability_type" {
  description = "ZONAL or REGIONAL. REGIONAL is a synchronous standby and roughly doubles the cost."
  type        = string
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "backup_enabled" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "extra_labels" {
  type    = map(string)
  default = {}
}

locals {
  name   = "${var.project}-${var.environment}-${var.component}"
  labels = merge({ project = var.project, environment = var.environment, component = replace(var.component, "-", "_"), managed_by = "terraform" }, var.extra_labels)
}

resource "google_sql_database_instance" "this" {
  name             = local.name
  database_version = var.database_version
  region           = var.region

  # The instance cannot be created until the private-services peering exists,
  # or the private IP allocation has nothing to attach to.
  depends_on = [var.private_services_connection]

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_size         = var.disk_size_gb
    disk_autoresize   = true

    # Private IP only: no public address is allocated at all.
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id

      # Require TLS for every connection, including in-VPC ones.
      ssl_mode = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = var.backup_enabled
      point_in_time_recovery_enabled = var.backup_enabled
      start_time                     = "03:00"
      transaction_log_retention_days = var.backup_enabled ? 7 : null

      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = var.environment == "prod" ? "1000" : "500"
    }

    user_labels = local.labels
  }

  lifecycle {
    precondition {
      condition     = var.environment != "prod" || var.availability_type == "REGIONAL"
      error_message = "availability_type must be REGIONAL in prod — a zonal production database makes a zone failure a full outage."
    }
  }
}

resource "google_sql_database" "this" {
  name     = var.database_name
  instance = google_sql_database_instance.this.name
}

# The password is generated and written straight into Secret Manager. It is
# never an input variable and never appears in Terraform state in plaintext.
resource "random_password" "db" {
  length  = 32
  special = true
  # Postgres connection strings and some ORMs mishandle these; excluding them
  # removes a class of quoting bug at no cost to entropy.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${local.name}-password"

  labels = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_sql_user" "this" {
  name     = var.database_user
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}
