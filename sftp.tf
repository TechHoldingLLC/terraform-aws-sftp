##################
#  sftp/sftp.tf  #
##################

resource "aws_instance" "this" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [module.security_group.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # Replaced by the EIP association below; needed so the host has egress at boot.
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region          = data.aws_region.current.region
    sftpgo_version      = var.sftpgo_version
    sftpgo_rpm_sha256   = var.sftpgo_rpm_sha256
    host_keys_secret_id = aws_secretsmanager_secret.host_keys.arn
    users_secret_id     = aws_secretsmanager_secret.users.arn
    log_group_name      = aws_cloudwatch_log_group.sftpgo.name

    # Deliberately does NOT reference the users secret version. user_data is only
    # about how to build a host, not which users exist - so adding a user no longer
    # replaces the instance. Changes are pushed to the running service instead, see
    # sync.tf. A new host still imports the current document at boot.

    sftpgo_config = jsonencode({
      common = {
        defender = {
          enabled              = true
          ban_time             = var.defender_ban_time
          ban_time_increment   = 50
          threshold            = var.defender_threshold
          score_invalid        = 2
          score_valid          = 1
          score_limit_exceeded = 3
          observation_time     = 30
          entries_soft_limit   = 100
          entries_hard_limit   = 150
        }

        # Upload to a temp name and rename on completion, so consumers never see
        # a half-written object.
        upload_mode = 2
      }

      sftpd = {
        bindings = [{
          port               = var.sftp_port
          address            = ""
          apply_proxy_config = false
        }]

        max_auth_tries = var.max_auth_tries

        # Absolute. SFTPGo resolves relative paths against /etc/sftpgo, which the
        # systemd ProtectSystem=full mounts read-only - it would find no keys
        # there and silently generate a new pair, changing the fingerprint.
        host_keys = ["/var/lib/sftpgo/id_ed25519", "/var/lib/sftpgo/id_rsa"]

        keyboard_interactive_authentication = false
        password_authentication             = true
      }

      # SFTP only. FTP and WebDAV are not exposed.
      ftpd = {
        bindings = []
      }

      webdavd = {
        bindings = []
      }

      # Admin UI and REST API on loopback only. Reach them with an SSM port-forward.
      httpd = {
        bindings = [{
          port              = 8080
          address           = "127.0.0.1"
          enable_web_admin  = true
          enable_web_client = false
          enable_rest_api   = true
        }]
      }

      data_provider = {
        driver               = "sqlite"
        name                 = "/var/lib/sftpgo/sftpgo.db"
        track_quota          = 2
        create_default_admin = false

        password_hashing = {
          algo           = "bcrypt"
          bcrypt_options = { cost = 10 }
        }
      }

      # No "log" section - SFTPGo has none. Logging is set by SFTPGO_LOG_* env
      # vars in the systemd drop-in. Viper drops unknown keys silently, so a log
      # block here would look right and do nothing.

      telemetry = {
        bind_port    = 10000
        bind_address = "127.0.0.1"
      }
    })
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_id
    delete_on_termination = true

    tags = merge(var.tags, { Name = "${var.name}-sftp-root" })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  dynamic "credit_specification" {
    for_each = startswith(var.instance_type, "t") ? [1] : []

    content {
      cpu_credits = var.cpu_credits
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-sftp" })

  depends_on = [
    aws_secretsmanager_secret_version.host_keys,
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm,
  ]
}

resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id

  tags = merge(var.tags, { Name = "${var.name}-sftp" })
}
