##################
#  sftp/logs.tf  #
##################

# SFTPGo and bootstrap logs, shipped by the CloudWatch agent on the host.
resource "aws_cloudwatch_log_group" "sftpgo" {
  name              = "/aws/ec2/${var.name}-sftp"
  retention_in_days = var.log_retention_days

  tags = var.tags
}
