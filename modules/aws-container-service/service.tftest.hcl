# Container-service module behaviour.
#
# The assertions here map to the three things that decide whether a deployment
# failure is an incident or a non-event: who can reach the task, whether the
# rollout can roll itself back, and whether a credential can leak from the task
# definition.

# The only computed value these assertions need is the ALB security group's id.
# Pinning it keeps every run in plan mode — no apply, so the mock provider's
# synthetic ARNs never reach the real provider's ARN validation.
mock_provider "aws" {
  override_resource {
    target          = aws_security_group.alb
    override_during = plan
    values          = { id = "sg-0aaaaaaaaaaaaaaaa" }
  }
}

variables {
  project                  = "predcache"
  environment              = "dev"
  region                   = "eu-central-1"
  component                = "api"
  vpc_id                   = "vpc-00000000000000001"
  subnet_ids               = ["subnet-00000000000000001", "subnet-00000000000000002"]
  load_balancer_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]
  container_image          = "ghcr.io/geomanti/predcache-api:1.0.0"
  environment_variables    = { APP_ENV = "dev" }
  secrets = {
    DATABASE_PASSWORD = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:predcache/db-abc123"
  }
}

run "tasks_are_reachable_only_from_the_load_balancer" {
  command = plan

  # `ingress` is a set, so it is normalised to a list before indexing — and the
  # assertions below then run across every element rather than trusting a single
  # rule to be the right one.
  assert {
    condition     = length(tolist(aws_security_group.task.ingress)) == 1
    error_message = "the task must have exactly one ingress rule: from the ALB."
  }

  # The rule that matters. A CIDR here would expose the service to a whole
  # subnet (or worse, the VPC), which is the classic lateral-movement opening.
  assert {
    condition = alltrue([
      for r in tolist(aws_security_group.task.ingress) :
      length(r.security_groups) == 1 && contains(tolist(r.security_groups), aws_security_group.alb.id)
    ])
    error_message = "task ingress must be scoped to the ALB security group, never to a CIDR block."
  }

  assert {
    condition = alltrue([
      for r in tolist(aws_security_group.task.ingress) :
      length(coalesce(r.cidr_blocks, [])) == 0 && length(coalesce(r.ipv6_cidr_blocks, [])) == 0
    ])
    error_message = "no task ingress rule may name a CIDR block; that would reach beyond the load balancer."
  }

  assert {
    condition = alltrue([
      for r in tolist(aws_security_group.task.ingress) :
      r.from_port == var.container_port && r.to_port == var.container_port
    ])
    error_message = "only the application port should be open on the task."
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == false
    error_message = "tasks must not receive public IPs; they belong in private subnets."
  }
}

run "rollouts_can_roll_themselves_back" {
  command = plan

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable == true
    error_message = "the deployment circuit breaker must be enabled."
  }

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].rollback == true
    error_message = "the circuit breaker must roll back; detection without rollback still leaves a broken revision live."
  }

  assert {
    condition     = aws_ecs_service.this.deployment_minimum_healthy_percent == 100
    error_message = "a rollout must not take capacity below 100% of desired; 0 healthy tasks is an outage."
  }
}

run "secrets_are_referenced_never_inlined" {
  command = plan

  # The container definition must carry the secret as a valueFrom ARN. If any
  # secret name ever appears under `environment` instead, the value is readable
  # by anyone holding ecs:DescribeTaskDefinition.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets :
      startswith(s.valueFrom, "arn:aws:secretsmanager:")
    ])
    error_message = "every secret must be a Secrets Manager ARN, not a literal value."
  }

  assert {
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      !contains(keys(var.secrets), e.name)
    ])
    error_message = "a secret name must never also appear as a plain environment variable."
  }

  # The policy is created unconditionally (a count depending on a computed ARN
  # would break plan-only pipelines), so it is referenced directly rather than
  # indexed.
  assert {
    condition     = aws_iam_role_policy.read_secrets.name == "${var.project}-${var.environment}-${var.component}-read-secrets"
    error_message = "a scoped secret-read policy must exist for the execution role."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.read_secrets.policy).Statement[0].Resource) == 1
    error_message = "the secret-read policy must be scoped to exactly the named ARNs, not to a wildcard."
  }

  assert {
    condition     = !strcontains(jsondecode(aws_iam_role_policy.read_secrets.policy).Statement[0].Resource[0], "*")
    error_message = "the secret-read resource must never be a wildcard."
  }
}

run "logs_are_retained_and_shipped" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 30
    error_message = "log retention must be set; an unset retention is an unbounded bill."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].logConfiguration.logDriver == "awslogs"
    error_message = "container logs must ship to CloudWatch."
  }
}

run "health_checks_are_tuned_for_a_slow_start" {
  command = plan

  assert {
    condition     = aws_lb_target_group.this.health_check[0].unhealthy_threshold * aws_lb_target_group.this.health_check[0].interval >= 30
    error_message = "a task needs at least ~30s of grace before being marked unhealthy, or slow starts crash-loop."
  }

  assert {
    condition     = aws_lb_target_group.this.health_check[0].matcher == "200"
    error_message = "the health check must require a 200; accepting 3xx/4xx hides a broken app."
  }

  assert {
    condition     = aws_lb_target_group.this.deregistration_delay >= 30
    error_message = "deregistration delay must leave room for in-flight requests to finish during a deploy."
  }
}

run "prod_enables_deletion_protection" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = aws_lb.this.enable_deletion_protection == true
    error_message = "the production load balancer must be protected against accidental deletion."
  }

  assert {
    condition     = aws_ecs_service.this.enable_execute_command == false
    error_message = "interactive execute-command access must be off in production."
  }

  assert {
    condition = one([
      for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"
    ]) == "enabled"
    error_message = "container insights must be on in production, or there are no per-service metrics to alarm on."
  }
}

run "rejects_an_illegal_fargate_task_size" {
  command = plan

  variables {
    cpu    = 512
    memory = 8192 # legal only at cpu 1024+
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "rejects_a_health_check_path_without_a_leading_slash" {
  command = plan

  variables {
    health_check_path = "healthz"
  }

  expect_failures = [var.health_check_path]
}

run "rejects_an_empty_container_image" {
  command = plan

  variables {
    container_image = "  "
  }

  expect_failures = [var.container_image]
}
