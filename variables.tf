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
  default     = ["0.0.0.0/0"]
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
  default     = null
}

variable "cpu_credits" {
  description = "Burstable CPU credits: \"unlimited\" avoids throttling mid-transfer but bills surplus credits, \"standard\" throttles instead. Ignored on non-burstable families"
  type        = string
  default     = "unlimited"

  validation {
    condition     = contains(["unlimited", "standard"], var.cpu_credits)
    error_message = "cpu_credits must be \"unlimited\" or \"standard\"."
  }
}

variable "root_volume_size" {
  description = "Root volume GB. SFTPGo stages in-flight and resumed transfers on local disk even with an S3 backend, so this must exceed largest file x concurrent transfers"
  type        = number
  default     = 20
}

variable "ebs_kms_key_id" {
  description = "KMS key for root volume encryption. Null uses the AWS-managed EBS key"
  type        = string
  default     = null
}

#-----------------------------------------------------------------------------
#  SFTPGo
#-----------------------------------------------------------------------------

variable "sftpgo_version" {
  description = "SFTPGo release to install, without the leading \"v\""
  type        = string
  default     = "2.7.5"
}

variable "sftpgo_rpm_sha256" {
  description = "Expected SHA-256 of the SFTPGo aarch64 RPM. Bootstrap fails closed on mismatch. Update together with sftpgo_version: curl -sSL https://github.com/drakkan/sftpgo/releases/download/v<VER>/sftpgo-<VER>-1.aarch64.rpm | sha256sum"
  type        = string
  default     = "01e6e0e2dca73f931eb57c30a9793781c40791e8492127c2fd88666bf8ea947d"
}

variable "sftp_port" {
  description = "Port SFTPGo listens on. The service gets CAP_NET_BIND_SERVICE so 22 works without root"
  type        = number
  default     = 22
}

variable "max_auth_tries" {
  description = "Failed auth attempts per connection before SFTPGo drops it"
  type        = number
  default     = 3
}

variable "defender_ban_time" {
  description = "Minutes a host stays banned by the brute-force defender"
  type        = number
  default     = 30
}

variable "defender_threshold" {
  description = "Defender score at which a host is banned. Each failed login scores 2"
  type        = number
  default     = 10
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

      username           Login name, and the default S3 key prefix
      key_prefix         S3 prefix the user is confined to. Defaults to "<username>/", must end in "/"
      public_keys        Authorized SSH public keys in authorized_keys format
      enable_password    Generate a password and allow password auth
      password_only      Deny public-key auth
      key_only           Deny password auth, overrides enable_password
      permissions        SFTPGo permissions at "/"
      quota_size         Max stored bytes, 0 for unlimited
      max_sessions       Max concurrent sessions, 0 for unlimited
      upload_bandwidth   Upload throttle KB/s, 0 for unlimited
      download_bandwidth Download throttle KB/s, 0 for unlimited
      allowed_ip         Per-user source CIDR allowlist, empty for any
      expiration_date    Account expiry, unix milliseconds, 0 for never
      description        Note shown in the SFTPGo admin UI
  EOT

  type = list(object({
    username           = string
    key_prefix         = optional(string)
    public_keys        = optional(list(string), [])
    enable_password    = optional(bool, true)
    password_only      = optional(bool, false)
    key_only           = optional(bool, false)
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
    condition     = alltrue([for u in var.users : u.key_prefix == null || endswith(coalesce(u.key_prefix, "/"), "/")])
    error_message = "key_prefix must end with \"/\"."
  }

  validation {
    condition     = alltrue([for u in var.users : !(u.key_only && u.password_only)])
    error_message = "A user cannot be both key_only and password_only."
  }

  validation {
    condition     = alltrue([for u in var.users : u.key_only ? length(u.public_keys) > 0 : true])
    error_message = "A key_only user needs at least one public key."
  }

  validation {
    condition     = alltrue([for u in var.users : u.enable_password || length(u.public_keys) > 0])
    error_message = "Each user needs enable_password = true or at least one public key."
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

variable "admin_permissions" {
  description = "Admin permissions. \"*\" is super admin; narrow to a read-only set like [\"view_users\",\"view_conns\",\"view_status\",\"view_defender\",\"view_events\"] if the panel is only for inspection"
  type        = list(string)
  default     = ["*"]
}


#-----------------------------------------------------------------------------
#  Storage
#-----------------------------------------------------------------------------

variable "bucket_force_destroy" {
  description = "Allow Terraform to delete a non-empty bucket. Keep false where partner data lives"
  type        = bool
  default     = false
}

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
  default     = 30
}

#-----------------------------------------------------------------------------
#  Observability
#-----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the SFTPGo log"
  type        = number
  default     = 30
}
