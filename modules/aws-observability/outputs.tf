output "alert_topic_arn" {
  description = "SNS topic all alarms publish to."
  value       = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  description = "Every alarm this module manages, so a stack can assert the set is complete."
  value = [
    aws_cloudwatch_metric_alarm.http_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.p95_latency.alarm_name,
    aws_cloudwatch_metric_alarm.cpu_saturation.alarm_name,
    aws_cloudwatch_metric_alarm.running_tasks_low.alarm_name,
  ]
}

# The alarm catalogue: what is watched, how it is measured, and how missing data
# is treated. Published as an output so the alerting contract is auditable
# without reading the module source — which is also what makes the test suite
# able to assert against the module's own declared surface.
output "alarm_catalogue" {
  description = "One entry per alarm: name, metric, statistic and missing-data policy."
  value = [
    {
      name               = aws_cloudwatch_metric_alarm.http_5xx.alarm_name
      metric             = aws_cloudwatch_metric_alarm.http_5xx.metric_name
      statistic          = aws_cloudwatch_metric_alarm.http_5xx.statistic
      treat_missing_data = aws_cloudwatch_metric_alarm.http_5xx.treat_missing_data
      threshold          = aws_cloudwatch_metric_alarm.http_5xx.threshold
    },
    {
      name               = aws_cloudwatch_metric_alarm.p95_latency.alarm_name
      metric             = aws_cloudwatch_metric_alarm.p95_latency.metric_name
      statistic          = aws_cloudwatch_metric_alarm.p95_latency.extended_statistic
      treat_missing_data = aws_cloudwatch_metric_alarm.p95_latency.treat_missing_data
      threshold          = aws_cloudwatch_metric_alarm.p95_latency.threshold
    },
    {
      name               = aws_cloudwatch_metric_alarm.cpu_saturation.alarm_name
      metric             = aws_cloudwatch_metric_alarm.cpu_saturation.metric_name
      statistic          = aws_cloudwatch_metric_alarm.cpu_saturation.statistic
      treat_missing_data = aws_cloudwatch_metric_alarm.cpu_saturation.treat_missing_data
      threshold          = aws_cloudwatch_metric_alarm.cpu_saturation.threshold
    },
    {
      name               = aws_cloudwatch_metric_alarm.running_tasks_low.alarm_name
      metric             = aws_cloudwatch_metric_alarm.running_tasks_low.metric_name
      statistic          = aws_cloudwatch_metric_alarm.running_tasks_low.statistic
      treat_missing_data = aws_cloudwatch_metric_alarm.running_tasks_low.treat_missing_data
      threshold          = aws_cloudwatch_metric_alarm.running_tasks_low.threshold
    },
  ]
}

# The metric dimensions, exposed so a stack can prove the ARN-suffix derivation
# produced the right shape. A wrong suffix here is an alarm that silently watches
# nothing, which is worse than no alarm.
output "load_balancer_arn_suffix" {
  description = "ARN suffix used as the LoadBalancer metric dimension."
  value       = var.load_balancer_arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix used as the TargetGroup metric dimension."
  value       = var.target_group_arn_suffix
}

output "alarm_dimensions" {
  description = "The dimension sets every alarm is keyed on."
  value = [
    {
      load_balancer = var.load_balancer_arn_suffix
      target_group  = var.target_group_arn_suffix
      cluster_name  = var.cluster_name
      service_name  = var.service_name
    },
  ]
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
