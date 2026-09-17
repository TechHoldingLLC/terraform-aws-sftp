#############################################################
#  Minimal example - users inline, no users-from-yaml module #
#############################################################
#
# The loader submodule is optional. With two or three stable users and no need for a
# per-user file, pass `users` directly. You lose the key-name validation the loader
# provides, so a typo is silently ignored - worth knowing before choosing this.

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
  region = "us-west-2"
}

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

module "sftp" {
  source = "../../"

  name = "sftp-minimal"

  vpc_id    = data.aws_vpc.default.id
  subnet_id = sort(data.aws_subnets.public.ids)[0]

  allowed_cidr_blocks = ["203.0.113.0/24"] # replace with real partner IPs

  users = [
    {
      username        = "partner-a"
      enable_password = true
      description     = "Password auth"
    },
    {
      username    = "partner-b"
      key_only    = true
      public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleReplaceMe them@partner.com"]
      description = "Key auth only"
    },
  ]
}

output "endpoint" {
  value = module.sftp.endpoint
}

output "usernames" {
  value = module.sftp.usernames
}
