############################
#  sftp/security_group.tf  #
############################

module "security_group" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-security-group.git?ref=v1.0.1"

  name        = "${var.name}-sftp"
  description = "SFTP host: partner ingress on the SFTP port, egress for AWS APIs and packages"
  vpc_id      = var.vpc_id

  ingress = [
    {
      from_port   = var.sftp_port
      to_port     = var.sftp_port
      cidr_blocks = var.allowed_cidr_blocks
      description = "SFTP"
    }
  ]

  egress = [
    {
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTPS for S3, Secrets Manager, SSM, CloudWatch and package repos"
    },
    {
      from_port   = 80
      to_port     = 80
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTP for Amazon Linux package repos"
    },
  ]

  tags = var.tags
}
