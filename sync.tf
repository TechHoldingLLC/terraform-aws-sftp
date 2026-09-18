##################
#  sftp/sync.tf  #
##################

resource "aws_ssm_document" "sync_users" {
  name            = "${var.name}-sftp-sync-users"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Push the SFTPGo users and admins document from Secrets Manager to the running service"

    parameters = {
      UsersSecretId = {
        type        = "String"
        description = "Secrets Manager ID of the SFTPGo loaddata document"
        default     = aws_secretsmanager_secret.users.arn
      }
      AdminSecretId = {
        type        = "String"
        description = "Secrets Manager ID of the web admin credentials"
        default     = aws_secretsmanager_secret.admin.arn
      }
      Region = {
        type    = "String"
        default = data.aws_region.current.region
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "syncUsers"
        inputs = {
          # Must exceed the script's own 300s wait for the bootstrap to finish,
          # or SSM kills the command mid-wait on a freshly rebuilt host.
          timeoutSeconds = "420"
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "",
            "API=http://127.0.0.1:8080/api/v2",
            "",
            "# The sync can arrive while cloud-init is still installing SFTPGo - the SSM",
            "# agent registers a minute or more before the bootstrap finishes. Without this",
            "# wait, the first apply after a rebuild races the install and fails.",
            "for i in $(seq 1 60); do",
            "  systemctl is-active --quiet sftpgo && break",
            "  [[ $i -eq 1 ]] && echo 'waiting for the sftpgo service to come up'",
            "  sleep 5",
            "done",
            "systemctl is-active --quiet sftpgo \\",
            "  || { echo 'FATAL: sftpgo is not running after 5 minutes; check /var/log/sftp-bootstrap.log'; exit 1; }",
            "",
            "# Written to a 0600 file owned by root rather than passed on a command line,",
            "# where it would be visible in `ps` to any local process.",
            "DOC=$(mktemp)",
            "chmod 600 \"$DOC\"",
            "trap 'rm -f \"$DOC\"' EXIT",
            "",
            "aws secretsmanager get-secret-value --secret-id '{{UsersSecretId}}' --region '{{Region}}' --query SecretString --output text > \"$DOC\"",
            "jq empty \"$DOC\" || { echo 'FATAL: users document is not valid JSON'; exit 1; }",
            "echo \"document: $(jq -r '.users | length' \"$DOC\") user(s), $(jq -r '.admins | length' \"$DOC\") admin(s)\"",
            "",
            "ADMIN=$(aws secretsmanager get-secret-value --secret-id '{{AdminSecretId}}' --region '{{Region}}' --query SecretString --output text)",
            "AU=$(jq -r .username <<<\"$ADMIN\")",
            "AP=$(jq -r .password <<<\"$ADMIN\")",
            "",
            "# Must not abort the script when the API is unreachable: under `set -e` with",
            "# pipefail a curl exit 7 would kill the whole sync before the retry loop or the",
            "# fallback ever ran. Swallow the failure and return an empty token instead.",
            "get_token() {",
            "  curl -sS --max-time 10 -u \"$AU:$AP\" \"$API/token\" 2>/dev/null \\",
            "    | jq -r '.access_token // empty' || true",
            "}",
            "",
            "# The admin may not exist yet on a brand-new host if the boot import has not",
            "# finished, so retry briefly rather than fail on a startup race.",
            "TOKEN=''",
            "for i in $(seq 1 5); do",
            "  TOKEN=$(get_token)",
            "  [[ -n \"$TOKEN\" ]] && break",
            "  echo \"waiting for the SFTPGo admin API (attempt $i/5)\"",
            "  sleep 3",
            "done",
            "",
            "# mode=0: add new, update existing. Never deletes - removing a user from",
            "# Terraform does not revoke them. See the users table in README.md.",
            "if [[ -n \"$TOKEN\" ]]; then",
            "  # Preferred path: apply live over the API. No restart, so in-flight",
            "  # transfers are not interrupted.",
            # %%{ escapes the HCL template directive so curl receives a literal %{http_code}
            "  HTTP=$(curl -sS --max-time 60 -o /tmp/loaddata.out -w '%%{http_code}' \\",
            "    -X POST \"$API/loaddata?mode=0&scan-quota=0\" \\",
            "    -H \"Authorization: Bearer $TOKEN\" \\",
            "    -H 'Content-Type: application/json' \\",
            "    --data-binary \"@$DOC\")",
            "  if [[ \"$HTTP\" != \"200\" ]]; then",
            "    echo \"FATAL: loaddata returned HTTP $HTTP\"; cat /tmp/loaddata.out; rm -f /tmp/loaddata.out; exit 1",
            "  fi",
            "  echo \"loaddata OK via API: $(cat /tmp/loaddata.out)\"",
            "  rm -f /tmp/loaddata.out",
            "else",
            "  # Fallback: the API needs the admin credential that this very document is",
            "  # responsible for setting, so rotating the admin password locks the API path",
            "  # out of its own update. Importing from file at startup needs no auth and",
            "  # always converges. Costs a restart - a few seconds, and it does drop",
            "  # in-flight transfers.",
            "  echo 'admin API auth failed - falling back to file import + restart'",
            "  install -m 0600 -o sftpgo -g sftpgo \"$DOC\" /var/lib/sftpgo/loaddata.json",
            "  systemctl restart sftpgo",
            "",
            "  for i in $(seq 1 20); do",
            "    systemctl is-active --quiet sftpgo && [[ ! -f /var/lib/sftpgo/loaddata.json ]] && break",
            "    sleep 2",
            "  done",
            "",
            "  systemctl is-active --quiet sftpgo \\",
            "    || { echo 'FATAL: sftpgo did not come back after restart'; exit 1; }",
            "  [[ ! -f /var/lib/sftpgo/loaddata.json ]] \\",
            "    || { echo 'FATAL: import did not consume the document; check: journalctl -u sftpgo | grep -i loaddata'; exit 1; }",
            "  echo 'loaddata OK via restart'",
            "",
            "  # The document has now been applied, so the credential in it is live.",
            "  TOKEN=$(get_token)",
            "fi",
            "unset ADMIN AP",
            "",
            "# Report what the service actually has now, so the SSM output is evidence of",
            "# convergence rather than just 'the call returned 200'. Best effort: the import",
            "# has already succeeded by this point, so a token problem here is not fatal.",
            "if [[ -z \"$TOKEN\" ]]; then",
            "  echo 'note: could not read back the server state (no admin token); the import itself succeeded'",
            "  exit 0",
            "fi",
            "",
            "# loaddata only adds and updates - it never deletes - so a user removed from",
            "# Terraform would keep working. Prune anything no longer declared, which is what",
            "# makes Terraform authoritative for who exists.",
            "DECLARED=$(jq -r '.users[].username' \"$DOC\")",
            "if [[ -n \"$DECLARED\" ]]; then",
            "  ONSERVER=$(curl -sS --max-time 15 -H \"Authorization: Bearer $TOKEN\" \"$API/users\" | jq -r '.[].username')",
            "  for U in $ONSERVER; do",
            "    if ! grep -qxF \"$U\" <<<\"$DECLARED\"; then",
            "      echo \"revoking $U (no longer declared in Terraform)\"",
            "      curl -sS --max-time 15 -X DELETE -H \"Authorization: Bearer $TOKEN\" \"$API/users/$U\" >/dev/null || echo \"  WARNING: could not delete $U\"",
            "    fi",
            "  done",
            "else",
            "  # An empty document means something upstream went wrong. Pruning here would",
            "  # delete every account, so do nothing and let the operator look.",
            "  echo 'WARNING: document declares no users, skipping prune'",
            "fi",
            "",
            "echo '--- users now on the server ---'",
            "curl -sS --max-time 15 -H \"Authorization: Bearer $TOKEN\" \"$API/users\" \\",
            "  | jq -r '.[] | \"  \\(.username)  prefix=\\(.filesystem.s3config.key_prefix // \"-\")  status=\\(.status)\"'",
            "echo '--- admins now on the server ---'",
            "curl -sS --max-time 15 -H \"Authorization: Bearer $TOKEN\" \"$API/admins\" \\",
            "  | jq -r '.[] | \"  \\(.username)  status=\\(.status)\"'",
          ]
        }
      }
    ]
  })

  tags = var.tags
}

# Runs the document whenever the users/admins document changes, so `make apply`
# converges the running host without replacing it.
resource "null_resource" "sync_users" {
  triggers = {
    # version_id changes only when the secret content changes.
    users_secret_version = aws_secretsmanager_secret_version.users.version_id
    document             = aws_ssm_document.sync_users.name
    instance             = aws_instance.sftp_ec2.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -Eeuo pipefail
      "${path.module}/scripts/sftpctl" sync \
        --instance "${aws_instance.sftp_ec2.id}" \
        --document "${aws_ssm_document.sync_users.name}" \
        --region "${data.aws_region.current.region}"
    EOT
  }

  depends_on = [
    aws_instance.sftp_ec2,
    aws_secretsmanager_secret_version.users,
    aws_secretsmanager_secret_version.admin,
    aws_iam_role_policy.instance,
  ]
}
