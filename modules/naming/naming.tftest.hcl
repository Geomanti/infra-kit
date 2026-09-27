# The naming module declares no provider, so these are pure-logic assertions:
# no mock, no credentials, no network. They run in milliseconds.

run "derives_a_compact_name_from_its_parts" {
  variables {
    project     = "predcache"
    environment = "prod"
    component   = "api"
    region      = "eu-central-1"
  }

  assert {
    condition     = output.name == "predcache-prod-api"
    error_message = "name must compose project, environment and component in that order."
  }

  assert {
    condition     = output.log_group_name == "/predcache/prod/api"
    error_message = "log group convention must be /<project>/<environment>/<component>."
  }
}

run "tags_carry_enough_provenance_to_find_the_owning_stack" {
  variables {
    project     = "fractal-catcher"
    environment = "staging"
    component   = "worker"
    region      = "eu-central-1"
  }

  assert {
    condition     = output.tags["ManagedBy"] == "terraform"
    error_message = "every resource must be attributable to Terraform."
  }

  assert {
    condition     = output.tags["Region"] == "eu-central-1"
    error_message = "the region must be recorded, so a console find can be traced back."
  }

  assert {
    condition     = output.tags["Name"] == "fractal-catcher-staging-worker"
    error_message = "the Name tag must match the canonical name."
  }
}

run "labels_are_normalised_to_gcp_legality" {
  variables {
    project     = "fractal-catcher"
    environment = "dev"
    component   = "feature-store"
    region      = "europe-west3"
  }

  assert {
    condition     = output.labels["project"] == "fractal_catcher"
    error_message = "GCP labels cannot contain a hyphen, so it must be normalised or GCP rejects the write."
  }

  assert {
    condition     = output.labels["component"] == "feature_store"
    error_message = "component labels must be normalised the same way."
  }

  assert {
    condition     = !can(regex("[A-Z.]", jsonencode(output.labels)))
    error_message = "GCP labels must be lowercase and must never contain a dot."
  }

  assert {
    condition     = !contains(keys(output.labels), "Region")
    error_message = "region is not a valid GCP label here; it must not be smuggled in from the AWS tag set."
  }
}

run "caller_tags_override_the_derived_set" {
  variables {
    project     = "predcache"
    environment = "prod"
    component   = "api"
    region      = "eu-central-1"
    extra_tags = {
      Owner       = "anton"
      Environment = "prod-eu"
    }
  }

  assert {
    condition     = output.tags["Owner"] == "anton"
    error_message = "extra tags must be merged in."
  }

  assert {
    condition     = output.tags["Environment"] == "prod-eu"
    error_message = "an explicit caller tag must be allowed to override the derived value."
  }

  assert {
    condition     = output.tags["Component"] == "api"
    error_message = "overriding one tag must not drop the others."
  }
}

run "rejects_an_environment_outside_the_closed_set" {
  command = plan
  variables {
    project     = "predcache"
    environment = "qa"
    component   = "api"
    region      = "eu-central-1"
  }

  expect_failures = [var.environment]
}

run "rejects_an_uppercase_project_name" {
  command = plan
  variables {
    project     = "Predcache"
    environment = "prod"
    component   = "api"
    region      = "eu-central-1"
  }

  expect_failures = [var.project]
}

run "rejects_an_empty_region" {
  command = plan
  variables {
    project     = "predcache"
    environment = "prod"
    component   = "api"
    region      = "  "
  }

  expect_failures = [var.region]
}
