variable "path" {
  description = <<-EOT
    Directory containing one *.yaml file per SFTP user.

    Pass an explicit root-relative path from the calling stack - `"$${path.root}/users"` -
    not a bare `"users"`. Terraform's `fileset()` resolves relative paths against the
    process working directory, not the module, so a bare relative path breaks depending
    on where Terraform is invoked from.
  EOT
  type        = string
}

variable "pattern" {
  description = "Glob for user files within `path`. Change only if you have a reason to."
  type        = string
  default     = "*.yaml"
}
