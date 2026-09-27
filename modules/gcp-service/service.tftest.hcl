# GCP service module behaviour.
#
# The three settings asserted here are the ones that decide whether a Cloud Run
# service is a private workload or a public one with a nice URL.

mock_provider "google" {}

variables {
  project         = "predcache"
  environment     = "prod"
  region          = "europe-west3"
  component       = "api"
  container_image = "europe-west3-docker.pkg.dev/predcache/app/api:1.0.0"
}

run "the_service_is_private_by_default" {
  command = plan

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 0
    error_message = "a service must not be publicly invokable unless explicitly asked for."
  }

  assert {
    condition     = google_cloud_run_v2_service.this.ingress == "INGRESS_TRAFFIC_ALL"
    error_message = "the default ingress is the Cloud Run default; callers opt into stricter policies."
  }
}

run "internal_only_ingress_is_honoured" {
  command = plan

  variables {
    ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  }

  assert {
    condition     = google_cloud_run_v2_service.this.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY"
    error_message = "the ingress policy must be passed through to the service."
  }

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 0
    error_message = "an internal-only service must not also grant allUsers the invoker role."
  }
}

run "public_invoker_is_granted_only_when_requested" {
  command = plan

  variables {
    allow_unauthenticated = true
  }

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 1
    error_message = "explicitly opting in must grant the invoker role."
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.public[0].member == "allUsers"
    error_message = "the public grant must be allUsers."
  }
}

run "the_runtime_identity_starts_with_no_roles" {
  command = plan

  # The service account is created here and no IAM binding attaches roles to it
  # in this module. If that ever changes, the workload silently gains the broad
  # default permissions this design exists to avoid.
  assert {
    condition     = google_service_account.runtime.account_id != ""
    error_message = "a dedicated runtime identity must be created."
  }

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 0 || !var.allow_unauthenticated
    error_message = "no role should be attached by default."
  }
}

run "autoscaling_has_a_hard_ceiling" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].scaling[0].max_instance_count == 10
    error_message = "unbounded autoscaling against a shared database is how a traffic spike becomes an outage."
  }

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].scaling[0].min_instance_count == 0
    error_message = "the default must scale to zero; keeping an instance warm is an explicit cost decision."
  }
}

run "secrets_are_mounted_by_reference" {
  command = plan

  variables {
    secret_environment_variables = {
      DATABASE_PASSWORD = "predcache-prod-db-password"
    }
  }

  # Look for the secret-backed env entry and assert it carries a secret_key_ref
  # rather than a literal value. A literal here would put a real credential in
  # the service definition and in state.
  assert {
    condition = anytrue([
      for e in google_cloud_run_v2_service.this.template[0].containers[0].env :
      e.name == "DATABASE_PASSWORD" && try(e.value_source[0].secret_key_ref[0].secret, "") == "predcache-prod-db-password"
    ])
    error_message = "secret env vars must be mounted as a Secret Manager reference, never as a literal value."
  }

  assert {
    condition = alltrue([
      for e in google_cloud_run_v2_service.this.template[0].containers[0].env :
      e.name == "DATABASE_PASSWORD" ? try(e.value == null || e.value == "", true) : true
    ])
    error_message = "a secret-backed variable must not also carry a plaintext value."
  }
}

run "vpc_connector_is_attached_only_when_supplied" {
  command = plan

  assert {
    condition     = length(google_cloud_run_v2_service.this.template[0].vpc_access) == 0
    error_message = "no connector was supplied, so none should be attached."
  }
}

run "vpc_connector_is_attached_with_private_ranges_only" {
  command = plan

  variables {
    vpc_connector_id = "projects/predcache/locations/europe-west3/connectors/predcache-prod-conn"
  }

  assert {
    condition     = length(google_cloud_run_v2_service.this.template[0].vpc_access) == 1
    error_message = "supplying a connector must attach it."
  }

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].vpc_access[0].egress == "PRIVATE_RANGES_ONLY"
    error_message = "only internal ranges should route through the connector; all-traffic egress is a bottleneck."
  }
}

run "probes_are_configured_for_readiness_and_liveness" {
  command = plan

  assert {
    condition     = length(google_cloud_run_v2_service.this.template[0].containers[0].startup_probe) == 1
    error_message = "a startup probe is required so a slow migration delays readiness instead of causing a restart loop."
  }

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].containers[0].liveness_probe[0].http_get[0].path == "/healthz"
    error_message = "the liveness probe must hit the health endpoint."
  }
}

run "rejects_an_invalid_ingress_policy" {
  command = plan

  variables {
    ingress = "INGRESS_TRAFFIC_FROM_MARS"
  }

  expect_failures = [var.ingress]
}

run "rejects_min_above_max_instances" {
  command = plan

  variables {
    min_instance_count = 5
    max_instance_count = 2
  }

  expect_failures = [google_cloud_run_v2_service.this]
}

run "rejects_an_empty_container_image" {
  command = plan

  variables {
    container_image = ""
  }

  expect_failures = [var.container_image]
}
