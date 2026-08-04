####################################################
#  Complete example — SFTP endpoint with YAML users #
####################################################
#
# Deploys a working SFTP endpoint into the account's default VPC, with users loaded
# from ./users/*.yaml.
#
#   terraform init
#   terraform apply
#
# Then read the connection details from the outputs, and a user's password out of the
# secret named by `passwords_secret_arn`.

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 6.56.0" }
    tls    = { source = "hashicorp/tls", version = ">= 4.3.0" }
    random = { source = "hashicorp/random", version = ">= 3.9.0" }
    null   = { source = "hashicorp/null", version = ">= 3.2.0" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Environment = "dev"
      createdBy   = "Terraform"
      Team        = "TechHolding"
    }
  }
}

#----------------------------------------------------------------------------
#  Networking and AMI — inputs to the module, never created by it
#----------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Amazon Linux 2023 arm64, from the AWS-published parameter. Authoritative, so it
# cannot match an unexpected community image the way a name filter can.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

#----------------------------------------------------------------------------
#  Users
#----------------------------------------------------------------------------

module "sftp_users" {
  source = "../../modules/users-from-yaml"

  # Root-relative, not a bare "users" — see the submodule README.
  path = "${path.root}/users"
}

#----------------------------------------------------------------------------
#  The SFTP endpoint
#----------------------------------------------------------------------------

module "sftp" {
  source = "../../"

  name        = var.name
  aws_profile = var.aws_profile

  vpc_id    = data.aws_vpc.default.id
  subnet_id = sort(data.aws_subnets.public.ids)[0]
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  # Narrow this to real partner egress IPs. The default is the whole internet.
  allowed_cidr_blocks = var.allowed_cidr_blocks

  users = module.sftp_users.users
}

#----------------------------------------------------------------------------
#  Outputs
#----------------------------------------------------------------------------

output "endpoint" {
  description = "Host partners connect to"
  value       = module.sftp.endpoint
}

output "port" {
  value = module.sftp.port
}

output "usernames" {
  description = "Provisioned usernames and their S3 prefixes"
  value       = module.sftp.usernames
}

output "passwords_secret_arn" {
  description = "Read a user's password from this secret"
  value       = module.sftp.passwords_secret_arn
}

output "admin_secret_arn" {
  description = "Web admin credentials"
  value       = module.sftp.admin_secret_arn
}

output "host_public_keys" {
  description = "Give these to partners for their known_hosts"
  value       = module.sftp.host_public_keys
}

output "instance_id" {
  description = "For `aws ssm start-session`"
  value       = module.sftp.instance_id
}
