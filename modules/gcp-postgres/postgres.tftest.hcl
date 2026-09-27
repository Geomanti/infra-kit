# GCP Postgres module behaviour.
#
# The single most important assertion in this file: ipv4_enabled must be false.
# A Cloud SQL instance with a public IPv4 address is reachable from the internet
# subject to IAM; with no public address, the attack surface is the VPC peering
# and nothing else.

# random_password.result is unknown until apply, which would make the wiring
# assertions un-evaluable. Pinning it at plan time keeps the comparison
# meaningful: if the config were changed to a hard-coded literal, the assertion
# below would fail because that literal would not equal this pinned value.
mock_provider "random" {
  override_resource {
    target          = random_password.db
    override_during = plan
    values          = { result = "GENERATED-PASSWORD-PLACEHOLDER" }
  }
}

mock_provider "google" {
  override_resource {
    target          = google_sql_database_instance.this
    override_during = plan
    values = {
      private_ip_address = "10.10.0.3"
      connection_name    = "predcache:europe-west3:predcache-prod-db"
    }
  }
}

variables {
  project = "predcache"
  # dev by default: the prod-only precondition must not fire on runs that are
  # testing something else. The two prod runs below set it explicitly.
  environment                 = "dev"
  region                      = "europe-west3"
  network_id                  = "projects/predcache/global/networks/predcache-prod"
  private_services_connection = "projects/predcache/global/networks/predcache-prod"
}

run "there_is_no_public_ip" {
  command = plan

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled == false
    error_message = "ipv4_enabled must be false; a public address is the difference between a private database and an internet-reachable one."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].private_network == var.network_id
    error_message = "the instance must be attached to the stack's VPC."
  }
}

run "tls_is_required_for_every_connection" {
  command = plan

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "SSL mode must require encryption, including for in-VPC connections."
  }
}

run "backups_and_pitr_are_enabled_with_bounded_retention" {
  command = plan

  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled == true
    error_message = "backups must be enabled."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled == true
    error_message = "point-in-time recovery is what makes an accidental DELETE recoverable."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].backup_retention_settings[0].retained_backups >= 1
    error_message = "at least one backup must be retained."
  }
}

run "the_password_is_generated_and_never_a_variable" {
  command = plan

  # The module takes no password input at all. A generated password written
  # straight to Secret Manager is the only path where the credential is never a
  # Terraform variable and never a plaintext argument.
  assert {
    condition     = length(random_password.db.result) > 0
    error_message = "a password must be generated."
  }

  assert {
    condition     = google_secret_manager_secret.db_password.secret_id != ""
    error_message = "the generated password must be stored in Secret Manager."
  }

  assert {
    condition     = google_secret_manager_secret_version.db_password.secret_data == random_password.db.result
    error_message = "the stored secret must be the generated password."
  }

  # Both consumers must read the same generated value. This is the assertion
  # that would fail if either were ever pointed at a hard-coded literal.
  assert {
    condition     = google_sql_user.this.password == random_password.db.result
    error_message = "the database user must use the generated password, not a separately supplied value."
  }
}

run "prod_requires_regional_availability" {
  command = plan

  variables {
    environment       = "prod"
    availability_type = "ZONAL"
  }

  expect_failures = [google_sql_database_instance.this]
}

run "regional_availability_is_accepted_in_prod" {
  command = plan

  variables {
    environment       = "prod"
    availability_type = "REGIONAL"
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].availability_type == "REGIONAL"
    error_message = "a synchronous standby must be deployed in prod."
  }
}

run "query_insights_are_on_for_diagnosability" {
  command = plan

  assert {
    condition     = google_sql_database_instance.this.settings[0].insights_config[0].query_insights_enabled == true
    error_message = "query insights are what make a slow-query incident diagnosable after the fact."
  }

  assert {
    condition     = google_sql_database_instance.this.settings[0].insights_config[0].record_client_address == false
    error_message = "client addresses should not be recorded; that is personal data with no diagnostic value here."
  }
}

run "rejects_an_invalid_availability_type" {
  command = plan

  variables {
    availability_type = "SOMETIMES"
  }

  expect_failures = [var.availability_type]
}

run "rejects_a_disk_below_the_minimum" {
  command = plan

  variables {
    disk_size_gb = 5
  }

  expect_failures = [var.disk_size_gb]
}
