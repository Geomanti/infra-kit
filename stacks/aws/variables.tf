variable "project" {
  description = "Product name; prefixes every resource."
  type        = string
  default     = "predcache"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_nat_gateway" {
  type    = bool
  default = false
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

# --- service ---

variable "service_component" {
  type    = string
  default = "api"
}

variable "container_image" {
  description = "Image to deploy. Required — there is no sensible default."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "service_desired_count" {
  type    = number
  default = 2
}

variable "service_cpu" {
  type    = number
  default = 512
}

variable "service_memory" {
  type    = number
  default = 1024
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}

variable "alb_internal" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "extra_environment_variables" {
  type    = map(string)
  default = {}
}

variable "extra_secrets" {
  description = "Additional secret env vars, NAME -> Secrets Manager ARN."
  type        = map(string)
  default     = {}
}

# --- postgres ---

variable "postgres_engine_version" {
  type    = string
  default = "16.3"
}

variable "postgres_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "postgres_allocated_storage" {
  type    = number
  default = 20
}

variable "postgres_backup_retention_days" {
  type    = number
  default = 7
}

# --- cache ---

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "cache_num_clusters" {
  type    = number
  default = 1
}

variable "cache_automatic_failover" {
  type    = bool
  default = false
}

variable "cache_maxmemory_policy" {
  type    = string
  default = "allkeys-lru"
}

# --- observability ---

variable "alarm_email" {
  type    = string
  default = ""
}

variable "p95_latency_threshold_ms" {
  type    = number
  default = 1000
}

variable "error_rate_threshold" {
  type    = number
  default = 5
}
