########################
#  sftp/cloudwatch.tf  #
########################

resource "aws_cloudwatch_log_group" "sftpgo" {
  name              = "/aws/ec2/${var.name}-sftp"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Single instance, so a failed status check means the endpoint is down.
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name}-sftp-status-check-failed"
  alarm_description   = "SFTP host failing EC2 status checks - the endpoint is down"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = { InstanceId = aws_instance.this.id }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = var.tags
}

# Transfers stage on local disk even with an S3 backend, so a full root volume
# fails uploads while the service still looks healthy.
resource "aws_cloudwatch_metric_alarm" "disk_used" {
  alarm_name          = "${var.name}-sftp-disk-used"
  alarm_description   = "SFTP host root volume over ${var.disk_used_alarm_threshold}% - transfers will start failing"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.disk_used_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = aws_instance.this.id }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = var.tags
}

# cpu_credits = "unlimited" trades throttling for billed surplus credits. This makes that spend visible
resource "aws_cloudwatch_metric_alarm" "cpu_surplus_credits" {
  alarm_name          = "${var.name}-sftp-cpu-surplus-credits-charged"
  alarm_description   = "Being billed for surplus CPU credits - sustained load has outgrown ${var.instance_type}, consider c7g.large"
  namespace           = "AWS/EC2"
  metric_name         = "CPUSurplusCreditsCharged"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = aws_instance.this.id }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = var.tags
}

# Catches a failed user import or an S3 denial - the port stays open but
# transfers are broken.
resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "${var.name}-sftp-errors"
  log_group_name = aws_cloudwatch_log_group.sftpgo.name
  pattern        = "?FATAL ?\"level=error\""

  metric_transformation {
    name          = "${var.name}-sftp-error-count"
    namespace     = "SFTP"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.name}-sftp-errors"
  alarm_description   = "Errors in the SFTPGo log - check for a failed user import or S3 access denial"
  namespace           = "SFTP"
  metric_name         = aws_cloudwatch_log_metric_filter.errors.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = var.tags
}
