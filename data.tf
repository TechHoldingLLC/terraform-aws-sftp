##################
#  sftp/data.tf  #
##################

data "aws_region" "current" {}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  # nonsensitive: SSM marks every value sensitive, and an AMI ID is not.
  ami_id = coalesce(var.ami_id, nonsensitive(one(data.aws_ssm_parameter.ami[*].value)))
}
