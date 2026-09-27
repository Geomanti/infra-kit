variable "project" {
  description = "Product name; prefixes every resource."
  type        = string
  default     = "predcache"
}

variable "project_id" {
  description = "GCP project id to deploy into."
  type        = string
}

variable "environment" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  type    = string
  default = "europe-west3"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "connector_cidr" {
  type    = string
  default = "10.10.15.0/28"
}

# --- service ---

variable "service_component" {
  type    = string
  default = "api"
}

variable "container_image" {
  type = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "service_cpu" {
  type    = string
  default = "1"
}

variable "service_memory" {
  type    = string
  default = "512Mi"
}

variable "service_min_instances" {
  type    = number
  default = 0
}

variable "service_max_instances" {
  type    = number
  default = 10
}

variable "ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_ALL"
}

variable "allow_unauthenticated" {
  type    = bool
  default = false
}

variable "extra_environment_variables" {
  type    = map(string)
  default = {}
}

variable "extra_secret_environment_variables" {
  description = "Additional secret env vars, NAME -> Secret Manager secret id."
  type        = map(string)
  default     = {}
}

# --- postgres ---

variable "postgres_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "postgres_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "postgres_database_name" {
  type    = string
  default = "app"
}

variable "postgres_disk_size_gb" {
  type    = number
  default = 20
}

variable "postgres_backup_enabled" {
  type    = bool
  default = true
}
