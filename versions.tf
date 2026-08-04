######################
#  sftp/versions.tf  #
######################

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.56.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}
