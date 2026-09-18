#####################
#  sftp/outputs.tf  #
#####################

output "endpoint" {
  description = "Host partners connect to"
  value       = aws_eip.sftp_eip.public_ip
}

output "port" {
  description = "SFTP port"
  value       = var.sftp_port
}

output "usernames" {
  description = "Provisioned usernames and the S3 prefix each is confined to"
  value       = { for u in var.users : u.username => coalesce(u.key_prefix, "${u.username}/") }
}

output "passwords_secret_arn" {
  description = "Secret holding the username to password map"
  value       = aws_secretsmanager_secret.user_passwords.arn
}

output "admin_secret_arn" {
  description = "Secret holding the web admin username and password"
  value       = aws_secretsmanager_secret.admin.arn
}

output "bucket_name" {
  description = "Bucket backing the SFTP tree"
  value       = module.s3.bucket_name
}

output "instance_id" {
  description = "Instance ID, for opening an SSM session"
  value       = aws_instance.sftp_ec2.id
}

output "log_group_name" {
  description = "CloudWatch log group with the SFTPGo and bootstrap logs"
  value       = aws_cloudwatch_log_group.sftpgo.name
}

output "sync_document_name" {
  description = "SSM document that pushes user and admin changes to the running service without a rebuild"
  value       = aws_ssm_document.sync_users.name
}
