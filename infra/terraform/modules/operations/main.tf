variable "name" { type = string }
variable "kms_key_arn" { type = string }
variable "alarm_email" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_suffix" { type = string }
variable "db_instance_id" { type = string }
variable "instance_ids" { type = list(string) }
variable "backup_retention_days" { type = number }
variable "patch_window_cron" { type = string }

# ------------------------------------------------------------------ alarms ---

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = [aws_sns_topic.alarms.arn]

  alb_alarms = {
    "alb-5xx" = {
      description = "Application/platform errors returned through the load balancer"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      threshold   = 25
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
    "alb-unhealthy-targets" = {
      description = "At least one OutSystems front-end is failing health checks"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      threshold   = 0
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_suffix }
    }
    "alb-latency" = {
      description = "Average target response time above 3s"
      metric      = "TargetResponseTime"
      statistic   = "Average"
      threshold   = 3
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb" {
  for_each            = local.alb_alarms
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  dimensions          = each.value.dimensions
  period              = 300
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu"
  alarm_description   = "Platform database CPU above 80% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-free-storage"
  alarm_description   = "Platform database free storage below 20 GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  period              = 300
  evaluation_periods  = 1
  threshold           = 20 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "ec2_status" {
  count               = length(var.instance_ids)
  alarm_name          = "${var.name}-ec2-status-${count.index}"
  alarm_description   = "EC2 status check failed; auto-recover the instance"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  dimensions          = { InstanceId = var.instance_ids[count.index] }
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = concat(local.alarm_actions, ["arn:aws:automate:${data.aws_region.current.name}:ec2:recover"])
}

data "aws_region" "current" {}

# ------------------------------------------------------------------ backup ---

resource "aws_backup_vault" "this" {
  name        = "${var.name}-vault"
  kms_key_arn = var.kms_key_arn
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-daily"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 18 * * ? *)" # 02:00 SGT
    start_window      = 60
    completion_window = 240
    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# EC2 servers are selected by tag; RDS keeps its own PITR backups (see database module).
resource "aws_backup_selection" "servers" {
  name         = "${var.name}-servers"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "daily"
  }
}

# ---------------------------------------------------------------- patching ---

resource "aws_ssm_patch_baseline" "windows" {
  name             = "${var.name}-windows"
  operating_system = "WINDOWS"
  description      = "Security and critical updates, auto-approved after 7 days"

  approval_rule {
    approve_after_days = 7
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["SecurityUpdates", "CriticalUpdates"]
    }
    patch_filter {
      key    = "MSRC_SEVERITY"
      values = ["Critical", "Important"]
    }
  }
}

resource "aws_ssm_patch_group" "this" {
  baseline_id = aws_ssm_patch_baseline.windows.id
  patch_group = var.name
}

resource "aws_ssm_maintenance_window" "patch" {
  name              = "${var.name}-patching"
  schedule          = var.patch_window_cron
  schedule_timezone = "Asia/Singapore"
  duration          = 3
  cutoff            = 1
}

resource "aws_ssm_maintenance_window_target" "servers" {
  window_id     = aws_ssm_maintenance_window.patch.id
  resource_type = "INSTANCE"
  targets {
    key    = "tag:PatchGroup"
    values = [var.name]
  }
}

# Patch one server at a time so the ALB always has a healthy front-end.
resource "aws_ssm_maintenance_window_task" "patch" {
  window_id       = aws_ssm_maintenance_window.patch.id
  task_type       = "RUN_COMMAND"
  task_arn        = "AWS-RunPatchBaseline"
  priority        = 1
  max_concurrency = "1"
  max_errors      = "0"

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.servers.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "Operation"
        values = ["Install"]
      }
      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }
    }
  }
}

output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "backup_vault_name" { value = aws_backup_vault.this.name }
