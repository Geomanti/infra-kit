# Local apply example — a real `terraform apply` with no cloud account.
#
# Every test suite in this repo runs in plan mode against a mock provider, which
# proves the configuration is *valid* and *correctly wired*. This example goes
# one step further: it performs a genuine apply, writes real files and produces a
# real state file, using the `local` provider. No credentials, no cloud, no cost.
#
# The point is to have one artifact in the repo that demonstrates the whole
# pipeline end to end — init, plan, apply, state, outputs, destroy — rather than
# only asserting about it. Run with:
#
#   cd examples/local && terraform init && terraform apply -auto-approve
#
# What it does: reads the same naming contract the cloud stacks use and renders
# the deployment manifest those stacks would produce, so the derived names, tags
# and labels can be inspected without provisioning anything.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "project" {
  type    = string
  default = "predcache"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "components" {
  description = "Logical components to render into the manifest."
  type        = list(string)
  default     = ["api", "worker", "cache", "db"]
}

variable "output_dir" {
  description = "Directory the manifest is written into."
  type        = string
  default     = "./out"
}

# The same naming module the AWS and GCP stacks consume. Deriving names here
# rather than in the example is the point: one contract, every consumer.
module "naming" {
  for_each = toset(var.components)

  source = "../../modules/naming"

  project     = var.project
  environment = var.environment
  component   = each.value
  region      = var.region
}

locals {
  # What each cloud stack would actually be told to create, expressed as data.
  manifest = {
    for component in var.components : component => {
      name           = module.naming[component].name
      log_group_name = module.naming[component].log_group_name
      aws_tags       = module.naming[component].tags
      gcp_labels     = module.naming[component].labels
    }
  }
}

resource "local_file" "manifest" {
  filename = "${var.output_dir}/deployment-manifest.json"
  content  = jsonencode(local.manifest)
}

resource "local_file" "naming_contract" {
  filename = "${var.output_dir}/naming-contract.txt"
  content = join("\n", [
    for component in var.components :
    "${component}\t${module.naming[component].name}\t${module.naming[component].log_group_name}"
  ])
}

output "manifest" {
  description = "The rendered deployment manifest."
  value       = local.manifest
}

output "manifest_path" {
  description = "Absolute path of the written manifest."
  value       = local_file.manifest.filename
}

output "resource_count" {
  description = "Number of logical components rendered."
  value       = length(var.components)
}
