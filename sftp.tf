##################
#  sftp/sftp.tf  #
##################

resource "aws_instance" "sftp_ec2" {
  ami           = local.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids      = [module.security_group.id]
  iam_instance_profile        = aws_iam_instance_profile.sftp_instance_profile.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region          = data.aws_region.current.region
    sftpgo_version      = var.sftpgo_version
    host_keys_secret_id = aws_secretsmanager_secret.host_keys.arn
    users_secret_id     = aws_secretsmanager_secret.users.arn
    log_group_name      = aws_cloudwatch_log_group.sftpgo.name

    sftpgo_config = jsonencode({
      common = {
        defender = {
          enabled              = true
          ban_time             = 30
          ban_time_increment   = 50
          threshold            = 10
          score_invalid        = 2
          score_valid          = 1
          score_limit_exceeded = 3
          observation_time     = 30
          entries_soft_limit   = 100
          entries_hard_limit   = 150
        }
        upload_mode = 2
      }

      sftpd = {
        bindings = [{
          port               = var.sftp_port
          address            = ""
          apply_proxy_config = false
        }]

        max_auth_tries = 3
        host_keys      = ["/var/lib/sftpgo/id_ed25519", "/var/lib/sftpgo/id_rsa"]

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
      cpu_credits = "unlimited"
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-sftp" })

  depends_on = [
    aws_secretsmanager_secret_version.host_keys,
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm,
  ]

  lifecycle {
    # Here we have kept ami id as default and it automatically updates to new AMI ID
    # We don't want to replace server automatically when new AMI Launches.
    ignore_changes = [ami]
  }
}

resource "aws_eip" "sftp_eip" {
  domain   = "vpc"
  instance = aws_instance.sftp_ec2.id

  tags = merge(var.tags, { Name = "${var.name}-sftp" })
}
