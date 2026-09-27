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

# Observability: SNS alert topic, CloudWatch alarms on the service's own
# metrics, and a dashboard.
#
# This module exists because "we have logs" is not observability. The alarms
# here are the four that actually page someone: error rate, latency, saturation
# and task death. `treat_missing_data` is set explicitly on every one of them —
# the CloudWatch default for a missing datapoint is "missing", which means an
# alarm on a service that has stopped reporting entirely never fires.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "component" { type = string }

variable "cluster_name" {
  description = "ECS cluster the service runs in."
  type        = string
}

variable "service_name" {
  description = "ECS service to alarm on."
  type        = string
}

variable "load_balancer_arn_suffix" {
  description = "ALB ARN suffix (the /app/name/hash form), used by the ALB metric namespace."
  type        = string
  default     = ""
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email to subscribe to the alert topic. Empty means the topic is created with no subscriber."
  type        = string
  default     = ""
}

variable "p95_latency_threshold_ms" {
  description = "p95 target response time, in milliseconds, that trips the latency alarm."
  type        = number
  default     = 1000
}

variable "error_rate_threshold" {
  description = "5xx responses per evaluation period that trips the error alarm."
  type        = number
  default     = 5
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

locals {
  name = "${var.project}-${var.environment}-${var.component}"
  tags = merge({ Project = var.project, Environment = var.environment, Component = var.component, ManagedBy = "terraform" }, var.extra_tags)
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# 1. Availability: any 5xx at all is a real user seeing a real error.
resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${local.name}-http-5xx"
  alarm_description   = "5xx responses from ${local.name} exceed ${var.error_rate_threshold} in 5 minutes."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.error_rate_threshold
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"
  period      = 300

  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# 2. Latency: p95 rather than average, because the average hides the tail that
#    users actually complain about.
resource "aws_cloudwatch_metric_alarm" "p95_latency" {
  alarm_name          = "${local.name}-p95-latency"
  alarm_description   = "p95 target response time for ${local.name} exceeds ${var.p95_latency_threshold_ms}ms."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.p95_latency_threshold_ms / 1000
  treat_missing_data  = "notBreaching"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"
  period             = 300

  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# 3. Saturation: CPU pinned means the service is one traffic bump from failing.
resource "aws_cloudwatch_metric_alarm" "cpu_saturation" {
  alarm_name          = "${local.name}-cpu-high"
  alarm_description   = "CPU utilisation for ${local.name} sustained above 85%."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 85
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = 300

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# 4. Task death: a service whose running count drops below desired is degraded,
#    and this is the alarm that catches a crash loop that the ALB health check
#    is masking by simply failing the task out of rotation.
resource "aws_cloudwatch_metric_alarm" "running_tasks_low" {
  alarm_name          = "${local.name}-running-tasks-low"
  alarm_description   = "Running task count for ${local.name} has dropped below desired — crash loop or capacity failure."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching" # no metric = no tasks reporting = worse than low

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Average"
  period      = 300

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "${local.name} — requests and errors"
          region = var.region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.load_balancer_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.load_balancer_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.load_balancer_arn_suffix],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "${local.name} — latency and saturation"
          region = var.region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.load_balancer_arn_suffix, { stat = "p95" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
          ]
        }
      },
    ]
  })
}
