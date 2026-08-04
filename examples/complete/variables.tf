variable "name" {
  description = "Name prefix for every resource"
  type        = string
  default     = "sftp-example"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile. Also used by the user-sync provisioner; leave empty in CI to use ambient credentials."
  type        = string
  default     = ""
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the SFTP port. Narrow to partner egress IPs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
