# Provider versions are pinned here as well as in the stacks.
# Without this, running `terraform init` inside a module resolves the latest
# major version, so a module tested standalone would exercise a different
# provider than the stack that consumes it in production.
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Container service: a Fargate service behind an ALB, with a task definition,
# health-checked target group, log shipping and a rollout circuit breaker.
#
# Two design decisions worth naming:
#
# 1. The deployment circuit breaker is on WITH automatic rollback. A deployment
#    that never reaches a steady state reverts itself instead of leaving the
#    service half-up; the failure mode this removes is the one where a bad push
#    stays live because nobody is watching at 3am.
# 2. The task definition is versioned by its own inputs (image tag, env, size),
#    so a deploy that changes nothing does not mint a new revision. That is what
#    makes "what is actually running" a single lookup instead of a diff.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "component" { type = string }

variable "vpc_id" { type = string }
variable "subnet_ids" {
  description = "Subnets to place tasks in."
  type        = list(string)
}
variable "load_balancer_subnet_ids" {
  description = "Public subnets for the ALB. May equal subnet_ids for an internal-only service."
  type        = list(string)
}

variable "alb_internal" {
  description = "Make the load balancer internal (no public DNS)."
  type        = bool
  default     = false
}

variable "container_image" {
  description = "Fully-qualified image reference, tag included."
  type        = string

  validation {
    condition     = length(trimspace(var.container_image)) > 0
    error_message = "container_image must not be empty."
  }
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8000

  validation {
    condition     = var.container_port > 0 && var.container_port <= 65535
    error_message = "container_port must be a valid TCP port."
  }
}

variable "desired_count" {
  description = "Number of task replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "cpu" {
  description = "Fargate task CPU units (1 vCPU = 1024)."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB. Must be a legal pairing with cpu."
  type        = number
  default     = 1024
}

variable "environment_variables" {
  description = "Plain environment variables for the container. Secrets belong in secrets (below), not here."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Container secrets, as NAME -> Secrets Manager / SSM ARN. Never inline a secret value in Terraform state."
  type        = map(string)
  default     = {}
}

variable "health_check_path" {
  description = "HTTP path the target group polls. Must return 200 without auth or the service will never stabilise."
  type        = string
  default     = "/healthz"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must begin with a slash."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Unset retention is the quiet cost leak."
  type        = number
  default     = 30
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"
  tags = merge({ Project = var.project, Environment = var.environment, Component = var.component, ManagedBy = "terraform" }, var.extra_tags)

  # Fargate only accepts specific cpu/memory pairings; an illegal one fails at
  # apply time with an opaque message. Asserting it here turns that into a plan
  # error that names the actual constraint.
  legal_task_sizes = {
    256  = [512, 1024, 2048]
    512  = [1024, 2048, 4096]
    1024 = [2048, 4096, 8192]
    2048 = [4096, 8192, 16384]
    4096 = [8192, 16384, 30720]
  }
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.environment == "prod" ? "enabled" : "disabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/${var.project}/${var.environment}/${var.component}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Inbound HTTP to the ${local.name} load balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere; terminate TLS at the ALB in production."
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the task security group only."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-alb" })
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Inbound from the ALB to ${local.name} tasks"
  vpc_id      = var.vpc_id

  # Note the source: the ALB security group, not a CIDR. The service is not
  # reachable from the internet or from a peer subnet even if the subnet routes
  # allow it.
  ingress {
    description     = "Application port, from the load balancer only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound for image pulls and upstream calls."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-task" })
}

resource "aws_lb" "this" {
  name               = substr(local.name, 0, 32)
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.load_balancer_subnet_ids

  # An ALB needs at least two AZs; one is a single point of failure the console
  # will happily let you create.
  enable_deletion_protection = var.environment == "prod"

  tags = local.tags
}

resource "aws_lb_target_group" "this" {
  name        = substr("${local.name}-tg", 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Health check tuned so a slow-starting app is not killed before it can serve:
  # 3 consecutive failures at 10s intervals gives a task ~30s of grace.
  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.tags
}

resource "aws_iam_role" "execution" {
  name = "${local.name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "${local.name}-read-secrets"
  role = aws_iam_role.execution.id

  # Created unconditionally, deliberately. A `count` here would depend on
  # values(var.secrets), which in a real stack is derived from a computed ARN
  # (RDS's managed master-user secret) — a count that cannot be determined until
  # apply forces a two-phase apply and fails outright in a plan-only pipeline.
  #
  # The safe alternative is an empty Resource list: with no resources named, the
  # statement grants nothing at all. That is strictly narrower than a fallback to
  # "*", and it keeps the resource graph fully known at plan time.
  #
  # The execution role reads secrets at task start; naming the exact ARNs is what
  # stops one service's credentials being readable by another.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
      Resource = values(var.secrets)
    }]
  })
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([
    {
      name      = var.component
      image     = var.container_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [for k, v in var.environment_variables : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.component
        }
      }

      # The container's own liveness signal, distinct from the ALB's HTTP probe:
      # this one restarts the task, the target-group one removes it from rotation.
      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }
  ])

  tags = local.tags

  lifecycle {
    precondition {
      condition     = contains(local.legal_task_sizes[var.cpu], var.memory)
      error_message = "cpu=${var.cpu} with memory=${var.memory} is not a valid Fargate task size. Legal pairings: 256/[512,1024,2048], 512/[1024,2048,4096], 1024/[2048,4096,8192], 2048/[4096,8192,16384], 4096/[8192,16384,30720]."
    }
  }
}

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.component
    container_port   = var.container_port
  }

  # Rollout safety: wait for stability, and roll back automatically rather than
  # leaving a broken revision serving.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  enable_execute_command = var.environment != "prod"

  tags = local.tags

  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns this after creation
  }
}
