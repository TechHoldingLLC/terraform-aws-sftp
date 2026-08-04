#####################
#  sftp/secrets.tf  #
#####################

# Host keys are generated here, not on the instance. If the host made its own, a
# replacement would change the fingerprint and every partner's known_hosts check
# would fail at once. Note these private keys land in Terraform state.
resource "tls_private_key" "host_ed25519" {
  algorithm = "ED25519"
}

resource "tls_private_key" "host_rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_secretsmanager_secret" "host_keys" {
  name                    = "${var.name}-sftp-host-keys"
  description             = "SSH host keys for the ${var.name} SFTP endpoint"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "host_keys" {
  secret_id = aws_secretsmanager_secret.host_keys.id

  secret_string = jsonencode({
    "id_ed25519"     = tls_private_key.host_ed25519.private_key_openssh
    "id_ed25519.pub" = tls_private_key.host_ed25519.public_key_openssh
    "id_rsa"         = tls_private_key.host_rsa.private_key_pem
    "id_rsa.pub"     = tls_private_key.host_rsa.public_key_openssh
  })
}

resource "random_password" "user" {
  for_each = { for u in var.users : u.username => u if u.enable_password && !u.key_only }

  length           = var.password_length
  override_special = "!#%*+-=?_~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "admin" {
  length           = var.password_length
  override_special = "!#%*+-=?_~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# The SFTPGo backup document. Passwords go in here and the whole thing goes to
# Secrets Manager - never to user_data, which is readable via IMDS.
resource "aws_secretsmanager_secret" "users" {
  name                    = "${var.name}-sftp-users"
  description             = "SFTPGo loaddata document for ${var.name}"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "users" {
  secret_id = aws_secretsmanager_secret.users.id

  # version 17 is the DumpVersion for SFTPGo 2.7.x. Bump with sftpgo_version.
  secret_string = jsonencode({
    version = 17
    folders = []
    groups  = []

    # Imported alongside the users, so the web admin survives instance
    # replacement. Without this, sftpgo.json sets create_default_admin = false
    # and every rebuild lands back on the first-run setup page.
    admins = [
      {
        username    = var.admin_username
        password    = random_password.admin.result
        status      = 1
        permissions = var.admin_permissions
        description = "Managed by Terraform"
      }
    ]

    users = [
      for u in var.users : {
        username        = u.username
        status          = 1
        description     = u.description
        expiration_date = u.expiration_date
        home_dir        = "/var/lib/sftpgo/users/${u.username}"
        public_keys     = u.public_keys
        max_sessions    = u.max_sessions
        quota_size      = u.quota_size
        quota_files     = 0

        # KB/s
        upload_bandwidth   = u.upload_bandwidth
        download_bandwidth = u.download_bandwidth

        password = try(random_password.user[u.username].result, "")

        permissions = {
          "/" = u.permissions
        }

        filters = {
          allowed_ip = u.allowed_ip
          denied_ip  = []

          denied_login_methods = concat(
            ["publickey+password", "publickey+keyboard-interactive", "TLSCertificate", "TLSCertificate+password"],
            (u.key_only || !u.enable_password) ? ["password", "password-over-SSH", "keyboard-interactive"] : [],
            u.password_only ? ["publickey"] : [],
          )

          denied_protocols = ["FTP", "DAV", "HTTP"]
        }

        filesystem = {
          # 1 = S3-compatible object storage
          provider = 1

          s3config = {
            bucket     = module.s3.bucket_name
            region     = data.aws_region.current.region
            key_prefix = coalesce(u.key_prefix, "${u.username}/")

            # No access_key/access_secret: SFTPGo falls back to the instance role.
            upload_part_size     = var.upload_part_size
            upload_concurrency   = var.upload_concurrency
            download_part_size   = var.download_part_size
            download_concurrency = var.download_concurrency
          }
        }
      }
    ]
  })
}

# Flat username -> password map, so an operator can read one credential without
# pulling the whole SFTPGo document. Read by `make sftp-password`.
resource "aws_secretsmanager_secret" "user_passwords" {
  name                    = "${var.name}-sftp-user-passwords"
  description             = "Username to password map for ${var.name} SFTP users"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "user_passwords" {
  secret_id     = aws_secretsmanager_secret.user_passwords.id
  secret_string = jsonencode({ for username, pw in random_password.user : username => pw.result })
}

resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.name}-sftp-admin"
  description             = "Web admin credentials for ${var.name} SFTPGo"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id

  secret_string = jsonencode({
    username = var.admin_username
    password = random_password.admin.result
  })
}
