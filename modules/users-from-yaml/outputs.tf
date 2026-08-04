# Raw maps, deliberately. No defaults are applied here - the parent module's typed
# `users` variable does the coercion and applies every optional() default, so defaults
# are defined in exactly one place and cannot drift between the two modules.
output "users" {
  description = "User definitions, ready to pass to the sftp module's `users` variable."
  value       = values(local.users_raw)

  depends_on = [terraform_data.validate]
}

output "usernames" {
  description = "Usernames found, sorted. Useful for a quick `terraform output` sanity check."
  value       = sort([for u in values(local.users_raw) : u.username])
}
