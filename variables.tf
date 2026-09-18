#######################
#  sftp/variables.tf  #
#######################

variable "name" {
  description = "Name prefix for every resource, e.g. \"sftp-dev\""
  type        = string
}

variable "tags" {
  description = "Extra tags, merged with provider default_tags"
  type        = map(string)
  default     = {}
}

#-----------------------------------------------------------------------------
#  Network - supplied by the caller, never created here
#-----------------------------------------------------------------------------

variable "vpc_id" {
  description = "Existing VPC to attach the SFTP host to"
  type        = string
}

variable "subnet_id" {
  description = "Existing public subnet for the SFTP host. Needs a route to an internet gateway so partners can reach it and the host can pull packages without NAT"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the SFTP port. Narrow to partner IPs once known"
  type        = list(string)
  # Used by Security group
  default = ["0.0.0.0/0"]
}

#-----------------------------------------------------------------------------
#  Compute
#-----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t4g.medium"
}

variable "ami_id" {
  description = "AMI to launch."
  type        = string
  # Passed via SSM Parameter by default
  default = null
}

variable "root_volume_size" {
  description = "Root volume GB. SFTPGo stages in-flight and resumed transfers on local disk even with an S3 backend, so this must exceed largest file x concurrent transfers"
  type        = number
  default     = 20
}

#-----------------------------------------------------------------------------
#  SFTPGo
#-----------------------------------------------------------------------------

variable "sftpgo_version" {
  description = "SFTPGo release to install, without the leading \"v\""
  type        = string
  default     = "2.7.5"
}

variable "sftp_port" {
  description = "Port SFTPGo listens on."
  type        = number
  default     = 22
}

variable "upload_part_size" {
  description = "S3 multipart upload part size in MB, minimum 5. SFTPGo holds upload_part_size x upload_concurrency in memory per active upload"
  type        = number
  default     = 16

  validation {
    condition     = var.upload_part_size >= 5
    error_message = "upload_part_size must be at least 5 MB, the S3 multipart minimum."
  }
}

variable "upload_concurrency" {
  description = "S3 parts uploaded in parallel per transfer"
  type        = number
  default     = 4
}

variable "download_part_size" {
  description = "S3 ranged download part size in MB, minimum 5"
  type        = number
  default     = 16

  validation {
    condition     = var.download_part_size >= 5
    error_message = "download_part_size must be at least 5 MB."
  }
}

variable "download_concurrency" {
  description = "S3 parts downloaded in parallel per transfer"
  type        = number
  default     = 4
}

#-----------------------------------------------------------------------------
#  Users
#-----------------------------------------------------------------------------

variable "users" {
  description = <<-EOT
    SFTP users. Rendered to an SFTPGo backup document, stored in Secrets Manager and
    imported at boot, so the instance is disposable.

    Auth mode follows from what you set - there is no mode to pick:
      public_keys only                 key-only
      enable_password only             password-only
      enable_password + public_keys    either one works

      username           Login name, and the default S3 key prefix
      key_prefix         S3 prefix the user is confined to, must end in "/". Unset gives
                         "<username>/"; "" gives the whole bucket
      public_keys        Authorized SSH public keys in authorized_keys format
      enable_password    Generate a password and allow password auth
      permissions        SFTPGo permissions at "/"
      quota_size         Max stored bytes, 0 for unlimited
      max_sessions       Max concurrent sessions, 0 for unlimited
      upload_bandwidth   Upload throttle KB/s, 0 for unlimited
      download_bandwidth Download throttle KB/s, 0 for unlimited
      allowed_ip         Source CIDRs THIS user may log in from, empty for any. Narrower
                         than allowed_cidr_blocks, which gates the port for everyone
      expiration_date    Account expiry, unix milliseconds, 0 for never
      description        Note shown in the SFTPGo admin UI
  EOT

  type = list(object({
    username           = string
    key_prefix         = optional(string)
    public_keys        = optional(list(string), [])
    enable_password    = optional(bool, false)
    permissions        = optional(list(string), ["list", "download", "upload", "overwrite", "delete", "rename", "create_dirs"])
    quota_size         = optional(number, 0)
    max_sessions       = optional(number, 0)
    upload_bandwidth   = optional(number, 0)
    download_bandwidth = optional(number, 0)
    allowed_ip         = optional(list(string), [])
    expiration_date    = optional(number, 0)
    description        = optional(string, "")
  }))

  default = []

  validation {
    condition     = length(distinct([for u in var.users : u.username])) == length(var.users)
    error_message = "Usernames must be unique."
  }

  validation {
    condition     = alltrue([for u in var.users : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", u.username))])
    error_message = "Usernames must start alphanumeric and contain only letters, digits, dot, underscore or hyphen, max 64 characters."
  }

  validation {
    condition     = alltrue([for u in var.users : u.key_prefix == null || u.key_prefix == "" || endswith(u.key_prefix, "/")])
    error_message = "key_prefix must end with \"/\", or be \"\" for the whole bucket."
  }

  validation {
    condition     = alltrue([for u in var.users : u.enable_password || length(u.public_keys) > 0])
    error_message = "Each user needs enable_password = true, at least one public key, or both - otherwise they cannot log in."
  }
}

variable "password_length" {
  description = "Length of generated user and admin passwords"
  type        = number
  default     = 16
}

#-----------------------------------------------------------------------------
#  Admin panel
#-----------------------------------------------------------------------------

variable "admin_username" {
  description = "SFTPGo web admin username. Included in the loaddata document so it survives instance replacement"
  type        = string
  default     = "sftpadmin"
}


#-----------------------------------------------------------------------------
#  Storage
#-----------------------------------------------------------------------------

variable "bucket_versioning" {
  description = "Keep every object version. Set at bucket creation - S3 cannot return a versioned bucket to unversioned"
  type        = bool
  default     = false
}

variable "abort_incomplete_multipart_days" {
  description = "Days before incomplete multipart uploads are aborted. Interrupted SFTP uploads leave parts that are billed but invisible in the console"
  type        = number
  default     = 7
}

variable "noncurrent_version_expiration_days" {
  description = "Days before non-current object versions are deleted. Only applies when bucket_versioning is true"
  type        = number
  default     = 14
}

#-----------------------------------------------------------------------------
#  Observability
#-----------------------------------------------------------------------------
variable "log_retention_days" {
  description = "CloudWatch Logs retention for the SFTPGo log"
  type        = number
  default     = 30
}
