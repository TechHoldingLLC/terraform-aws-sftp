#################
#  sftp/iam.tf  #
#################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-sftp"
  description        = "Instance role for the ${var.name} SFTP host"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = var.tags
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-sftp"
  role = aws_iam_role.this.name

  tags = var.tags
}

# Session Manager replaces SSH for admin access.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # Outer boundary is the bucket. SFTPGo confines each user to their key_prefix.
  statement {
    sid    = "SftpObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = ["${module.s3.bucket_arn}/*"]
  }

  statement {
    sid    = "SftpBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]

    resources = [module.s3.bucket_arn]
  }

  # The admin secret is read by the user-sync SSM document (see sync.tf), which
  # authenticates to the local admin API to push user changes without a rebuild. 
  statement {
    sid     = "ReadBootstrapSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.host_keys.arn,
      aws_secretsmanager_secret.users.arn,
      aws_secretsmanager_secret.admin.arn,
    ]
  }

  statement {
    sid    = "ShipLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.sftpgo.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name}-sftp"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.instance.json
}
