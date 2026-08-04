#####################
#  sftp/outputs.tf  #
#####################

output "endpoint" {
  description = "Host partners connect to"
  value       = aws_eip.this.public_ip
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

output "host_public_keys" {
  description = "SSH host public keys. Give these to partners out-of-band so their first connection is verified, not blindly trusted"
  value = {
    ed25519 = trimspace(tls_private_key.host_ed25519.public_key_openssh)
    rsa     = trimspace(tls_private_key.host_rsa.public_key_openssh)
  }
}

output "bucket_name" {
  description = "Bucket backing the SFTP tree"
  value       = module.s3.bucket_name
}

output "instance_id" {
  description = "Instance ID, for opening an SSM session"
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the SFTP host, to reference from other security groups"
  value       = module.security_group.id
}

output "log_group_name" {
  description = "CloudWatch log group with the SFTPGo and bootstrap logs"
  value       = aws_cloudwatch_log_group.sftpgo.name
}

output "sync_document_name" {
  description = "SSM document that pushes user and admin changes to the running service without a rebuild"
  value       = aws_ssm_document.sync_users.name
}
