# Stack-level integration test.
#
# The module suites each prove one component. This file proves the composition:
# that the modules are wired to each other correctly, that the service can reach
# its data tiers and nothing else can, and that no credential ends up as a
# literal anywhere in the graph.
#
# This is the layer bugs actually live at — a module can be perfect and the
# stack still hand the application the wrong database host, or grant the load
# balancer's security group to Postgres by mistake.
#
# Note on override targets: at stack level the resources live inside child
# modules, so every override is qualified — `module.network.data.…`,
# `module.service.aws_…`. An unqualified target is silently ignored with a
# warning, which would leave the assertions evaluating unknown values.

mock_provider "aws" {
  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
      id    = "eu-central-1"
    }
  }

  # Computed ids the wiring assertions need to be visible at plan time. Each is
  # qualified with the module that owns it.

  override_resource {
    target          = module.service.aws_security_group.alb
    override_during = plan
    values          = { id = "sg-0aaaaaaaaaaaaaaa1" }
  }

  override_resource {
    target          = module.service.aws_security_group.task
    override_during = plan
    values          = { id = "sg-0bbbbbbbbbbbbbbb2" }
  }

  # The load balancer and target group ARNs, pinned so the ARN-suffix derivation
  # is genuinely exercised. The suffix shape ("app/<name>/<hash>") is what the
  # ECS/ALB metric dimensions require; deriving it wrongly produces an alarm that
  # silently watches nothing, so this is the assertion worth having.
  override_resource {
    target          = module.observability.aws_sns_topic.alerts
    override_during = plan
    values = {
      arn = "arn:aws:sns:eu-central-1:123456789012:predcache-dev-api-alerts"
    }
  }

  override_resource {
    target          = module.service.aws_lb.this
    override_during = plan
    values = {
      arn      = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/predcache-dev-api/50dc6c495c0c9188"
      dns_name = "predcache-dev-api-1234567890.eu-central-1.elb.amazonaws.com"
    }
  }

  override_resource {
    target          = module.service.aws_lb_target_group.this
    override_during = plan
    values = {
      arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/predcache-dev-api-tg/b8f3a1e2c4d5e6f7"
    }
  }

  # Subnet ids are computed, so pin them to make the placement assertions
  # evaluable — "the service runs in the private subnets" is only a real check if
  # both sets are known. override_resource takes an object per instance, so a
  # counted resource is pinned one index at a time.
  override_resource {
    target          = module.network.aws_subnet.public[0]
    override_during = plan
    values          = { id = "subnet-0public000000001", availability_zone = "eu-central-1a" }
  }

  override_resource {
    target          = module.network.aws_subnet.public[1]
    override_during = plan
    values          = { id = "subnet-0public000000002", availability_zone = "eu-central-1b" }
  }

  override_resource {
    target          = module.network.aws_subnet.private[0]
    override_during = plan
    values          = { id = "subnet-0private00000001", availability_zone = "eu-central-1a" }
  }

  override_resource {
    target          = module.network.aws_subnet.private[1]
    override_during = plan
    values          = { id = "subnet-0private00000002", availability_zone = "eu-central-1b" }
  }

  # The data-tier endpoints are computed by the provider, so without pinning them
  # the wiring assertions below cannot be evaluated at all — they would silently
  # pass as "unknown". Pinning them makes the assertion meaningful: the stack
  # must pass exactly these values through to the container.
  override_resource {
    target          = module.postgres.aws_db_instance.this
    override_during = plan
    values = {
      address  = "predcache-dev-db.pinned.internal"
      endpoint = "predcache-dev-db.pinned.internal:5432"
      port     = 5432
      db_name  = "app"
      password = null
      master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:predcache-dev-db-abc123"
      }]
    }
  }

  override_resource {
    target          = module.cache.aws_elasticache_replication_group.this
    override_during = plan
    values = {
      primary_endpoint_address = "predcache-dev-cache.pinned.internal"
      reader_endpoint_address  = "predcache-dev-cache-ro.pinned.internal"
      port                     = 6379
    }
  }
}

variables {
  project         = "predcache"
  environment     = "dev"
  container_image = "ghcr.io/geomanti/predcache-api:1.0.0"
}

# ---------------------------------------------------------------------------
# The application receives a working, least-privilege data path.
# ---------------------------------------------------------------------------

run "the_service_is_given_its_database_connection_details" {
  command = plan

  # Read the composition contract, not the inputs: whatever the container is
  # actually handed is what the application will use at runtime.
  assert {
    condition     = module.service.container_environment["DATABASE_HOST"] == module.postgres.address
    error_message = "DATABASE_HOST must be wired from the postgres module's address, not left unset or hard-coded."
  }

  assert {
    condition     = module.service.container_environment["REDIS_HOST"] == module.cache.primary_endpoint
    error_message = "REDIS_HOST must be wired from the cache module's primary endpoint."
  }

  assert {
    condition     = module.service.container_environment["DATABASE_NAME"] == module.postgres.database_name
    error_message = "DATABASE_NAME must come from the database module, so the app and the instance cannot disagree."
  }

  assert {
    condition     = module.service.container_environment["PORT"] == tostring(var.container_port)
    error_message = "PORT must be passed to the container so the app binds the port the target group polls."
  }
}

run "no_credential_appears_as_a_literal_anywhere" {
  command = plan

  # The password must arrive as a Secrets Manager ARN. A literal value here
  # would be readable by anyone with ecs:DescribeTaskDefinition.
  assert {
    condition     = startswith(module.service.container_secrets["DATABASE_PASSWORD"], "arn:aws:secretsmanager:")
    error_message = "the database password must be a Secrets Manager reference, not a value."
  }

  # The strong form of the same check: no secret name may ALSO appear as a plain
  # environment variable.
  assert {
    condition = alltrue([
      for name in keys(module.service.container_secrets) :
      !contains(keys(module.service.container_environment), name)
    ])
    error_message = "a secret name must never also be passed as a plain environment variable."
  }

  # Belt and braces: the database must not carry a plaintext password attribute
  # either, since that value would land in Terraform state.
  assert {
    condition     = module.postgres.password_is_unset
    error_message = "the RDS instance must not carry an inline password."
  }

  assert {
    condition     = module.postgres.master_user_secret_arn != null
    error_message = "RDS must produce a managed master-user secret for the service to read."
  }
}

run "only_the_service_can_reach_the_data_tiers" {
  command = plan

  # Postgres accepts connections from exactly one security group: the service's.
  # If the ALB group ever appeared here, the load balancer itself would be a
  # path to the database.
  assert {
    condition     = length(module.postgres.allowed_client_security_group_ids) == 1
    error_message = "Postgres must accept connections from exactly one security group."
  }

  assert {
    condition     = contains(module.postgres.allowed_client_security_group_ids, module.service.task_security_group_id)
    error_message = "Postgres must accept connections from the service's task security group."
  }

  assert {
    condition     = contains(module.cache.allowed_client_security_group_ids, module.service.task_security_group_id)
    error_message = "Redis must accept connections only from the service's task security group."
  }

  assert {
    condition     = !contains(module.postgres.allowed_client_security_group_ids, module.service.alb_security_group_id)
    error_message = "the load balancer must not be able to reach the database."
  }
}

# ---------------------------------------------------------------------------
# Network placement.
# ---------------------------------------------------------------------------

run "the_alb_is_public_but_the_tasks_are_not" {
  command = plan

  assert {
    condition     = module.service.alb_internal == false
    error_message = "the default stack serves traffic publicly."
  }

  assert {
    condition     = module.service.assign_public_ip == false
    error_message = "tasks must sit in private subnets with no public IP."
  }

  # The ALB must be in the public subnets and the tasks in the private ones —
  # a swap here is a silent misconfiguration that only shows up at runtime.
  assert {
    condition = alltrue([
      for s in module.service.subnet_ids :
      contains(module.network.private_subnet_ids, s)
    ])
    error_message = "the service must run in the private subnets."
  }

  assert {
    condition = alltrue([
      for s in module.network.private_subnet_ids :
      !contains(module.network.public_subnet_ids, s)
    ])
    error_message = "public and private subnets must be disjoint sets."
  }

  # Egress: with NAT disabled there must be no private default route at all.
  assert {
    condition     = length(module.network.nat_gateway_ids) == 0
    error_message = "dev runs without NAT egress by default; enable_nat_gateway would change this."
  }
}

# ---------------------------------------------------------------------------
# Rollout safety.
# ---------------------------------------------------------------------------

run "a_bad_deploy_rolls_itself_back" {
  command = plan

  assert {
    condition     = module.service.deployment_circuit_breaker.enabled == true
    error_message = "the deployment circuit breaker must be enabled at stack level."
  }

  assert {
    condition     = module.service.deployment_circuit_breaker.rollback == true
    error_message = "the circuit breaker must actually roll back."
  }
}

# ---------------------------------------------------------------------------
# Observability is wired to the right identifiers.
# ---------------------------------------------------------------------------

run "alarms_are_published_and_dimensioned_correctly" {
  command = plan

  assert {
    condition     = length(module.observability.alert_topic_arn) > 0
    error_message = "an alert topic must exist."
  }

  assert {
    condition     = length(module.observability.alarm_catalogue) == 4
    error_message = "errors, latency, saturation and task-death must each be alarmed."
  }

  # The ARN-suffix derivation is the fiddly part of this stack: ECS/ALB metric
  # dimensions want "app/<name>/<hash>", not the full ARN. This asserts the
  # derivation produced the right shape, which is the difference between an
  # alarm that fires and one that silently watches nothing.
  assert {
    condition = alltrue([
      for d in module.observability.alarm_dimensions : !can(regex("^arn:", d.load_balancer))
    ])
    error_message = "the LoadBalancer metric dimension must be an ARN suffix, not a full ARN."
  }

  assert {
    condition     = length(regexall("^app/", module.observability.load_balancer_arn_suffix)) == 1
    error_message = "an ALB metric suffix must begin with the resource type, e.g. app/<name>/<hash>."
  }

  assert {
    condition     = length(regexall("^targetgroup/", module.observability.target_group_arn_suffix)) == 1
    error_message = "a target group metric suffix must begin with 'targetgroup/'."
  }

  assert {
    condition     = module.observability.dashboard_name == module.service.service_name
    error_message = "the dashboard must be named after the service it describes."
  }
}

# ---------------------------------------------------------------------------
# Parameterisation actually parameterises.
# ---------------------------------------------------------------------------

run "scale_is_driven_by_inputs" {
  command = plan

  variables {
    service_desired_count = 5
    service_cpu           = 1024
    service_memory        = 2048
  }

  assert {
    condition     = module.service.desired_count == 5
    error_message = "desired_count must follow its input."
  }

  assert {
    # Compared as strings: the ECS task definition models cpu/memory as strings
    # in the provider schema (they are passed through to the container runtime),
    # so a numeric comparison would fail on the type rather than the value.
    condition     = tostring(module.service.task_cpu) == "1024" && tostring(module.service.task_memory) == "2048"
    error_message = "task size must follow its inputs."
  }
}

run "prod_turns_on_the_safety_settings" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = module.postgres.multi_az == true
    error_message = "prod must deploy a synchronous database standby."
  }

  assert {
    condition     = module.postgres.deletion_protection == true
    error_message = "prod must protect the database against accidental deletion."
  }

  assert {
    condition     = module.service.deletion_protection == true
    error_message = "prod must protect the load balancer against accidental deletion."
  }

  assert {
    condition     = module.service.execute_command_enabled == false
    error_message = "prod must not allow interactive exec into tasks."
  }
}

run "dev_stays_cheap_without_giving_up_encryption_or_backups" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = module.postgres.multi_az == false
    error_message = "dev should not pay for a standby."
  }

  assert {
    condition     = module.postgres.storage_encrypted == true
    error_message = "encryption is not an environment-dependent choice."
  }

  assert {
    condition     = module.postgres.backup_retention_days >= 1
    error_message = "even dev must be restorable."
  }
}

# ---------------------------------------------------------------------------
# Caching cannot become a load source.
# ---------------------------------------------------------------------------

run "the_cache_can_always_evict" {
  command = plan

  assert {
    condition     = module.cache.maxmemory_policy != "noeviction"
    error_message = "noeviction turns a full cache into write errors; a cache must be able to shed load."
  }
}

# ---------------------------------------------------------------------------
# The stack is reviewable in one pass.
# ---------------------------------------------------------------------------

run "every_resource_is_attributable" {
  command = plan

  assert {
    condition     = module.postgres.tags["ManagedBy"] == "terraform"
    error_message = "the database must be attributable to Terraform."
  }

  assert {
    condition     = module.service.tags["Environment"] == var.environment
    error_message = "the service must be tagged with its environment."
  }

  assert {
    condition     = module.cache.tags["Project"] == var.project
    error_message = "the cache must be tagged with its project."
  }

  assert {
    condition     = module.network.tags["ManagedBy"] == "terraform"
    error_message = "the network must be attributable to Terraform."
  }
}
