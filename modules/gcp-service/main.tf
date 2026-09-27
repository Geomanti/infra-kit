# Cloud Run v2 service with a least-privilege runtime identity, autoscaling
# bounds and a startup probe.
#
# Three decisions worth naming:
# 1. The service runs as a dedicated service account with no roles attached by
#    default. The default compute identity is broad; this one starts at zero
#    permissions and the caller grants exactly what the workload needs.
# 2. min_instance_count is an input. Scale-to-zero is cheap but a cold start on
#    a latency-sensitive path is a user-visible stall, so that trade is explicit.
# 3. Startup and liveness probes are separate: a slow migration should delay
#    readiness, not trigger a restart loop.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "component" { type = string }

variable "container_image" {
  description = "Artifact Registry image reference, tag or digest."
  type        = string

  validation {
    condition     = length(trimspace(var.container_image)) > 0
    error_message = "container_image must not be empty."
  }
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  description = "CPU limit, e.g. \"1\" or \"1000m\"."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory limit, e.g. \"512Mi\"."
  type        = string
  default     = "512Mi"
}

variable "min_instance_count" {
  description = "0 = scale to zero (cold starts); >=1 keeps a warm instance."
  type        = number
  default     = 0
}

variable "max_instance_count" {
  description = "Hard concurrency ceiling. Unbounded autoscaling on a shared database is how a traffic spike becomes an outage."
  type        = number
  default     = 10

  validation {
    condition     = var.max_instance_count >= 1
    error_message = "max_instance_count must be at least 1."
  }
}

variable "container_concurrency" {
  description = "Concurrent requests per instance."
  type        = number
  default     = 80
}

variable "environment_variables" {
  description = "Plain environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_environment_variables" {
  description = "Secret env vars as NAME -> Secret Manager secret id. Mounted by reference, never as a literal."
  type        = map(string)
  default     = {}
}

variable "ingress" {
  description = "Ingress policy. INGRESS_TRAFFIC_INTERNAL_ONLY for private services."
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.ingress)
    error_message = "ingress must be a valid Cloud Run ingress policy."
  }
}

variable "vpc_connector_id" {
  description = "Serverless VPC Access connector for private egress. Empty = no connector (public egress only)."
  type        = string
  default     = ""
}

variable "allow_unauthenticated" {
  description = "Grant allUsers the invoker role. False keeps the service private (IAM-authenticated calls only)."
  type        = bool
  default     = false
}

variable "extra_labels" {
  type    = map(string)
  default = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"
  # Cloud Run service names must be lowercase alphanumeric or hyphen, max 49.
  service_name = substr(lower(replace(local.name, "/[^a-z0-9-]/", "-")), 0, 49)
  labels       = merge({ project = var.project, environment = var.environment, component = replace(var.component, "-", "_"), managed_by = "terraform" }, var.extra_labels)
}

resource "google_service_account" "runtime" {
  account_id   = substr("${local.service_name}-run", 0, 30)
  display_name = "Cloud Run runtime identity for ${local.service_name}"
  description  = "Runtime identity for ${local.service_name}; receives no roles by default."
}

resource "google_cloud_run_v2_service" "this" {
  name     = local.service_name
  location = var.region
  ingress  = var.ingress

  labels = local.labels

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = var.min_instance_count
      max_instance_count = var.max_instance_count
    }

    max_instance_request_concurrency = var.container_concurrency

    dynamic "vpc_access" {
      for_each = var.vpc_connector_id != "" ? [1] : []
      content {
        connector = var.vpc_connector_id
        # Private-ranges-only keeps public internet calls direct and routes only
        # internal addresses through the connector — sending all egress through
        # it is a throughput bottleneck and an unnecessary cost.
        egress = "PRIVATE_RANGES_ONLY"
      }
    }

    containers {
      image = var.container_image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      ports {
        container_port = var.container_port
      }

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_environment_variables
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        initial_delay_seconds = 5
        timeout_seconds       = 3
        period_seconds        = 10
        failure_threshold     = 3
        tcp_socket {
          port = var.container_port
        }
      }

      liveness_probe {
        timeout_seconds   = 3
        period_seconds    = 30
        failure_threshold = 3
        http_get {
          path = "/healthz"
          port = var.container_port
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.min_instance_count <= var.max_instance_count
      error_message = "min_instance_count must not exceed max_instance_count."
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.allow_unauthenticated ? 1 : 0

  name     = google_cloud_run_v2_service.this.name
  location = google_cloud_run_v2_service.this.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
