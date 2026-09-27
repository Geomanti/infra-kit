# Observability module behaviour.
#
# The assertion that matters most here is `treat_missing_data`. The CloudWatch
# default is "missing", which means an alarm attached to a service that has
# stopped reporting entirely never fires — the exact case you most want paged.
#
# These runs read the module's own `alarm_catalogue` output rather than reaching
# into individual resources, so the test asserts the published alerting contract.

mock_provider "aws" {}

variables {
  project                  = "predcache"
  environment              = "prod"
  region                   = "eu-central-1"
  component                = "api"
  cluster_name             = "predcache-prod-api"
  service_name             = "predcache-prod-api"
  load_balancer_arn_suffix = "app/predcache-prod-api/50dc6c495c0c9188"
  target_group_arn_suffix  = "targetgroup/predcache-prod-api/b8f3a1e2c4d5e6f7"
}

run "all_four_failure_modes_are_alarmed" {
  command = plan

  assert {
    condition     = length(output.alarm_catalogue) == 4
    error_message = "errors, latency, saturation and task-death must each have an alarm."
  }

  assert {
    condition     = length(output.alarm_names) == 4
    error_message = "the published alarm list must name every alarm."
  }
}

run "each_metric_that_matters_is_watched" {
  command = plan

  assert {
    condition = anytrue([
      for a in output.alarm_catalogue : a.metric == "HTTPCode_Target_5XX_Count"
    ])
    error_message = "there must be an error-rate alarm."
  }

  assert {
    condition = anytrue([
      for a in output.alarm_catalogue : a.metric == "TargetResponseTime"
    ])
    error_message = "there must be a latency alarm."
  }

  assert {
    condition = anytrue([
      for a in output.alarm_catalogue : a.metric == "CPUUtilization"
    ])
    error_message = "there must be a saturation alarm."
  }

  assert {
    condition = anytrue([
      for a in output.alarm_catalogue : a.metric == "RunningTaskCount"
    ])
    error_message = "there must be a task-death alarm; the ALB health check masks a crash loop by failing tasks out of rotation."
  }
}

run "latency_is_measured_at_p95_not_mean" {
  command = plan

  assert {
    condition = anytrue([
      for a in output.alarm_catalogue :
      a.metric == "TargetResponseTime" && a.statistic == "p95"
    ])
    error_message = "latency must be alarmed on p95; a mean hides the tail users actually complain about."
  }
}

run "missing_data_never_silently_disarms_an_alarm" {
  command = plan

  assert {
    condition = alltrue([
      for a in output.alarm_catalogue : a.treat_missing_data != "missing"
    ])
    error_message = "every alarm must set treat_missing_data explicitly; the default 'missing' means a service that stopped reporting is never paged."
  }

  # Task-death is the one case where absent data is itself the alarm condition.
  assert {
    condition = anytrue([
      for a in output.alarm_catalogue :
      a.metric == "RunningTaskCount" && a.treat_missing_data == "breaching"
    ])
    error_message = "the task-death alarm must treat missing data as breaching; no metric means no tasks reporting."
  }
}

run "thresholds_are_finite_and_positive" {
  command = plan

  assert {
    condition = alltrue([
      for a in output.alarm_catalogue : a.threshold > 0
    ])
    error_message = "every alarm threshold must be a positive number."
  }
}

run "alarms_notify_and_recover" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.http_5xx,
        aws_cloudwatch_metric_alarm.p95_latency,
        aws_cloudwatch_metric_alarm.cpu_saturation,
        aws_cloudwatch_metric_alarm.running_tasks_low,
      ] :
      length(a.alarm_actions) == 1 && length(a.ok_actions) == 1
    ])
    error_message = "every alarm must notify on breach and on recovery; an alarm with no OK action never tells you it cleared."
  }
}

run "subscription_is_only_created_when_an_address_is_given" {
  command = plan

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "no address was supplied, so no subscription should be created."
  }
}

run "subscription_is_created_when_an_address_is_given" {
  command = plan

  variables {
    alarm_email = "oncall@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "supplying an address must subscribe it."
  }

  assert {
    condition     = aws_sns_topic_subscription.email[0].endpoint == "oncall@example.com"
    error_message = "the subscription must target the address that was supplied."
  }
}

run "dashboard_covers_requests_latency_and_saturation" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 2
    error_message = "the dashboard must show traffic/errors and latency/saturation."
  }
}
