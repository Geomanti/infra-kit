# GCP stack integration test.
#
# Proves the composition of the GCP half: that the service reaches its database
# over the private network, that the credential arrives by reference, and that
# nothing is publicly invokable unless explicitly asked for.
#
# Note on override targets: at stack level the resources live inside child
# modules, so every override is qualified — `module.network.…`,
# `module.postgres.…`. An unqualified target is silently ignored with a warning.

mock_provider "random" {
  override_resource {
    target          = module.postgres.random_password.db
    override_during = plan
    values          = { result = "GENERATED-PASSWORD-PLACEHOLDER" }
  }
}

mock_provider "google" {
  # Computed identifiers the wiring assertions need to be visible at plan time.
  override_resource {
    target          = module.network.google_compute_network.this
    override_during = plan
    values = {
      id   = "projects/predcache/global/networks/predcache-dev"
      name = "predcache-dev"
    }
  }

  override_resource {
    target          = module.network.google_vpc_access_connector.this
    override_during = plan
    values = {
      id = "projects/predcache/locations/europe-west3/connectors/predcache-dev-conn"
    }
  }

  override_resource {
    target          = module.postgres.google_sql_database_instance.this
    override_during = plan
    values = {
      name               = "predcache-dev-db"
      private_ip_address = "10.10.0.3"
      connection_name    = "predcache:europe-west3:predcache-dev-db"
    }
  }

  override_resource {
    target          = module.postgres.google_secret_manager_secret.db_password
    override_during = plan
    values          = { secret_id = "predcache-dev-db-password" }
  }

  override_resource {
    target          = module.service.google_service_account.runtime
    override_during = plan
    values = {
      email      = "predcache-dev-api-run@predcache.iam.gserviceaccount.com"
      account_id = "predcache-dev-api-run"
    }
  }

  override_resource {
    target          = module.service.google_cloud_run_v2_service.this
    override_during = plan
    values = {
      name     = "predcache-dev-api"
      location = "europe-west3"
      uri      = "https://predcache-dev-api-abcdef-ew.a.run.app"
    }
  }
}

variables {
  project_id      = "predcache"
  project         = "predcache"
  environment     = "dev"
  container_image = "europe-west3-docker.pkg.dev/predcache/app/api:1.0.0"
}

# ---------------------------------------------------------------------------
# The application reaches its database without a public path.
# ---------------------------------------------------------------------------

run "the_service_connects_by_private_ip" {
  command = plan

  assert {
    condition     = module.service.environment_variables["DATABASE_HOST"] == module.postgres.private_ip_address
    error_message = "the database host must be the private IP from the postgres module."
  }

  assert {
    condition     = module.service.environment_variables["DATABASE_HOST"] != ""
    error_message = "the database host must be populated, not left empty."
  }

  assert {
    condition     = module.postgres.has_public_ip == false
    error_message = "the database must have no public address; the connection path is the private network only."
  }

  assert {
    condition     = module.service.vpc_connector_id == module.network.connector_id
    error_message = "the service must egress through the stack's VPC connector to reach the private database."
  }
}

run "the_password_never_appears_as_a_literal" {
  command = plan

  # The credential is mounted by Secret Manager reference, named in the secret
  # variables map — not in the plain environment map.
  assert {
    condition     = module.service.secret_environment_variables["DATABASE_PASSWORD"] == module.postgres.password_secret_id
    error_message = "the database password must be mounted from Secret Manager by reference."
  }

  assert {
    condition = !contains(
      keys(module.service.environment_variables),
      "DATABASE_PASSWORD"
    )
    error_message = "the password must never be passed as a plain environment variable."
  }

  # The generated password has exactly one consumer path: the secret version.
  assert {
    condition     = module.postgres.password_secret_id != ""
    error_message = "a generated password must be stored in Secret Manager."
  }
}

# ---------------------------------------------------------------------------
# Exposure.
# ---------------------------------------------------------------------------

run "the_service_is_private_by_default" {
  command = plan

  assert {
    condition     = module.service.allow_unauthenticated == false
    error_message = "a service must not be publicly invokable by default."
  }

  assert {
    condition     = module.service.ingress_is_restrictive == false
    error_message = "the default stack allows public ingress; callers opt into internal-only."
  }
}

run "internal_only_ingress_is_honoured" {
  command = plan

  variables {
    ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  }

  assert {
    condition     = module.service.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY"
    error_message = "the ingress policy must pass through to the service."
  }

  assert {
    condition     = module.service.allow_unauthenticated == false
    error_message = "an internal-only service must not also grant public invocation."
  }
}

# ---------------------------------------------------------------------------
# Autoscaling is bounded, and the identity is minimal.
# ---------------------------------------------------------------------------

run "autoscaling_has_a_ceiling" {
  command = plan

  assert {
    condition     = module.service.max_instance_count == 10
    error_message = "unbounded autoscaling against a shared database is how a traffic spike becomes an outage."
  }

  assert {
    condition     = module.service.min_instance_count == 0
    error_message = "the default scales to zero; keeping an instance warm is an explicit cost decision."
  }
}

run "scale_follows_its_inputs" {
  command = plan

  variables {
    service_min_instances = 2
    service_max_instances = 25
  }

  assert {
    condition     = module.service.min_instance_count == 2 && module.service.max_instance_count == 25
    error_message = "instance bounds must follow their inputs."
  }
}

run "the_runtime_identity_is_dedicated" {
  command = plan

  # A dedicated service account with no roles attached here. If the module ever
  # fell back to the default compute identity, the workload would silently
  # inherit broad project permissions.
  assert {
    condition     = module.service.service_account_email != ""
    error_message = "a dedicated runtime identity must be created."
  }

  assert {
    condition     = !can(regex("-compute@developer.gserviceaccount.com", module.service.service_account_email))
    error_message = "the service must not run as the default compute identity."
  }
}

# ---------------------------------------------------------------------------
# Data safety.
# ---------------------------------------------------------------------------

run "prod_gets_a_regional_database" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = module.postgres.availability_type == "REGIONAL"
    error_message = "prod must deploy a synchronous standby."
  }
}

run "dev_stays_zonal" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = module.postgres.availability_type == "ZONAL"
    error_message = "dev should not pay for a standby."
  }
}

run "encryption_and_backups_are_not_environment_dependent" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = module.postgres.ssl_mode == "ENCRYPTED_ONLY"
    error_message = "TLS must be required in every environment."
  }

  assert {
    condition     = module.postgres.backups_enabled == true
    error_message = "backups must be on in every environment."
  }
}

# ---------------------------------------------------------------------------
# Parameterisation and attribution.
# ---------------------------------------------------------------------------

run "the_container_receives_its_configuration" {
  command = plan

  assert {
    condition     = module.service.environment_variables["APP_ENV"] == var.environment
    error_message = "APP_ENV must reflect the deployment environment."
  }

  assert {
    condition     = module.service.environment_variables["DATABASE_NAME"] == module.postgres.database_name
    error_message = "the app's database name must come from the database module."
  }

  assert {
    condition     = module.service.environment_variables["DATABASE_CONNECTION_NAME"] == module.postgres.connection_name
    error_message = "the Cloud SQL connection name must be passed for the connector library."
  }
}

run "every_resource_is_attributable" {
  command = plan

  assert {
    condition     = module.service.labels["managed_by"] == "terraform"
    error_message = "the service must be attributable to Terraform."
  }

  assert {
    condition     = module.postgres.labels["environment"] == var.environment
    error_message = "the database must be labelled with its environment."
  }

  assert {
    condition     = module.network.labels["project"] == var.project
    error_message = "the network must be labelled with its project."
  }
}
