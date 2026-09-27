# Cross-cloud naming contract.
#
# One derivation of names, tags and labels, consumed by every stack in this repo.
# The point is drift prevention: AWS tags and GCP labels are computed here rather
# than typed out per stack, so a resource found in a cloud console can be traced
# back to the stack that owns it, and the two clouds cannot disagree about what
# the same logical component is called.
#
# This module declares no provider. Everything below is pure logic, which is why
# its test suite runs in milliseconds and with no credentials at all.

variable "project" {
  description = "Product or system name, hyphen-separated. e.g. \"predcache\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be 2-21 characters, lowercase alphanumeric or hyphen, and start with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. A closed set, so a typo cannot silently create a fourth one."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "component" {
  description = "The part of the system this resource belongs to, e.g. \"api\", \"worker\", \"cache\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.component))
    error_message = "component must be 1-20 characters, lowercase alphanumeric or hyphen, and start with a letter."
  }
}

variable "region" {
  description = "Cloud region. Recorded in tags so the owning stack is discoverable from the resource."
  type        = string

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "region must not be empty."
  }
}

variable "extra_tags" {
  description = "Extra AWS tags merged over the derived set (owner, cost centre, compliance scope)."
  type        = map(string)
  default     = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"

  # AWS tags: case-preserving, free-form keys, mergeable.
  tags = merge(
    {
      Name        = local.name
      Project     = var.project
      Environment = var.environment
      Component   = var.component
      Region      = var.region
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  # GCP labels are a genuinely different type from AWS tags: lowercase only,
  # restricted to [a-z0-9_-], at most 63 characters, and a "." is illegal.
  # Deriving them here is what keeps the two clouds' metadata in lockstep.
  labels = {
    project     = lower(replace(var.project, "-", "_"))
    environment = var.environment
    component   = lower(replace(var.component, "-", "_"))
    managed_by  = "terraform"
  }

  # Log destination convention, shared by CloudWatch log groups and
  # Cloud Logging log IDs, so a log's origin is obvious in either console.
  log_group_name = "/${var.project}/${var.environment}/${var.component}"
}
