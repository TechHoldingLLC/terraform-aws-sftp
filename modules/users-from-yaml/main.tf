locals {
  user_files = fileset(var.path, var.pattern)

  # Keyed by filename so error messages can name the offending file.
  users_raw = {
    for f in local.user_files :
    f => yamldecode(file("${var.path}/${f}"))
  }

  # Every attribute the sftp module's `users` variable accepts.
  #
  # This exists because Terraform silently DROPS unrecognised keys when coercing a map
  # to an object type. Without this check, `permissons: [list]` would be ignored and the
  # user would quietly receive the module's default permissions instead of the
  # restricted set you intended — wrong access, clean plan, no warning.
  #
  # Kept in step with the parent module by .github/workflows/validate.yml, which fails
  # if the two lists diverge.
  allowed_user_keys = [
    "username",
    "key_prefix",
    "public_keys",
    "enable_password",
    "password_only",
    "key_only",
    "permissions",
    "quota_size",
    "max_sessions",
    "upload_bandwidth",
    "download_bandwidth",
    "allowed_ip",
    "expiration_date",
    "description",
  ]

  unknown_user_keys = flatten([
    for f, u in local.users_raw : [
      for k in setsubtract(keys(u), local.allowed_user_keys) : "${f}: ${k}"
    ]
  ])

  # A file named globex.yaml whose username is something else is almost always a
  # copy-paste slip, and it makes the directory listing lie about who has access.
  mismatched_user_files = [
    for f, u in local.users_raw : f
    if try(u.username, null) != trimsuffix(f, ".yaml")
  ]
}

# Fails `terraform plan` before anything is touched. terraform_data is used rather than
# a `check` block because checks only warn, and a silently-ignored permission key is not
# something to warn about.
resource "terraform_data" "validate" {
  input = sort(tolist(local.user_files))

  lifecycle {
    precondition {
      condition     = length(local.unknown_user_keys) == 0
      error_message = "Unrecognised keys in ${var.path} (Terraform would ignore these silently): ${join(", ", local.unknown_user_keys)}. Valid keys: ${join(", ", local.allowed_user_keys)}"
    }

    precondition {
      condition     = length(local.mismatched_user_files) == 0
      error_message = "These files must set `username` to match their filename: ${join(", ", local.mismatched_user_files)}"
    }

    precondition {
      condition     = length(local.user_files) > 0
      error_message = "No user files matching '${var.pattern}' found in ${var.path}. At least one is required, otherwise nobody can log in."
    }
  }
}
