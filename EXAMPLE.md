# SFTP

Below are examples of calling this module. Runnable versions live in
[`examples/`](examples).

For the per-user YAML schema and every field it accepts, see
[`modules/users-from-yaml/README.md`](modules/users-from-yaml/README.md).

## Minimal - required inputs only

```hcl
module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = "myproject-dev"
  vpc_id    = module.vpc.id
  subnet_id = element(module.vpc.public_subnet_ids, 0)   # must be public
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  users = [
    { username = "partner-a" }   # password generated, full read/write in partner-a/
  ]
}

# Amazon Linux 2023 arm64 - authoritative, unlike an aws_ami name filter
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}
```

`allowed_cidr_blocks` defaults to `0.0.0.0/0`. Narrow it - see below.

## Users from YAML files (recommended)

One file per user, so onboarding a partner is a one-file PR and
`git log users/globex.yaml` is that partner's access history.

```hcl
module "sftp_users" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git//modules/users-from-yaml?ref=v0.0.1"

  path = "${path.root}/users"   # root-relative, not a bare "users"
}

module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = var.prefix
  vpc_id    = module.vpc.id
  subnet_id = element(module.vpc.public_subnet_ids, 0)
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  users = module.sftp_users.users
}
```

```yaml
# users/globex.yaml   - the filename must match the username
username: globex
description: Globex nightly pull
key_only: true
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@globex.com
```

Pin both modules to the same `ref`. They ship from one tag, which is what keeps the
loader's validation in step with the module's schema.

## Users inline, without the loader

Reasonable for two or three stable users. You lose the loader's key-name validation, so
a typo like `permissons` is silently ignored rather than rejected.

```hcl
module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = var.prefix
  vpc_id    = module.vpc.id
  subnet_id = element(module.vpc.public_subnet_ids, 0)
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  users = [
    { username = "partner-a", enable_password = true },
    {
      username    = "partner-b"
      key_only    = true
      public_keys = ["ssh-ed25519 AAAAC3Nza... them@partner.com"]
    },
  ]
}
```

## Restricting who can reach the port

```hcl
module "sftp" {
  # ...
  allowed_cidr_blocks = [
    "203.0.113.0/24",     # partner A egress
    "198.51.100.10/32",   # partner B egress
    "49.34.161.102/32",   # office
  ]
}
```

This is the security group. A partner whose IP is missing gets a **timeout**, not an
auth error - the most common onboarding failure. Per-user `allowed_ip` is a second,
independent layer; add the range to both if you use it.

## Two users sharing an existing folder

`key_prefix` does not create anything - S3 has no folders, only keys. It is a chroot
over keys that already exist, so pointing two users at an existing prefix grants access
to what is already there.

```yaml
# users/analyst-a.yaml
username: analyst-a
enable_password: true
key_prefix: shared/          # existing prefix; nothing is created
```
```yaml
# users/analyst-b.yaml
username: analyst-b
enable_password: true
key_prefix: shared/
```

Both land at `/`, both see the existing contents of `s3://<bucket>/shared/`, and both
see each other's files.

Scope it tighter with `key_prefix: shared/inbound/` if they should only see a subtree.

**Limitation:** `key_prefix` is a single chroot, so a user gets *either* their own prefix
*or* a shared one - not both. Serving both would need SFTPGo virtual folders, which this
module does not currently expose.

## Write-only drop box

Can deposit files but not download anyone's contents.

```yaml
username: vendor-drop
enable_password: true
permissions:
  - list        # required - GUI clients list on connect and fail without it
  - upload
  - overwrite   # required - without it, re-sending the same filename fails
```

Dropping to just `- upload` hides filenames, but then **no GUI client works** - only
automation doing blind `put`s. You cannot have both hidden filenames and FileZilla.

## Read-only distribution

```yaml
username: reports-reader
key_only: true
public_keys:
  - ssh-ed25519 AAAAC3Nza... reader@corp.com
permissions:
  - list
  - download
```

## Quotas, throttling and session limits

```yaml
username: bulk-partner
enable_password: true
quota_size: 107374182400   # 100 GiB, in BYTES
max_sessions: 4
upload_bandwidth: 10240    # 10 MB/s, in KB/s
download_bandwidth: 10240
```

Bandwidth limits are the lever when one partner's bulk transfer starves everyone else on
a `t4g.medium`.

## Time-limited access

```yaml
username: auditor-temp
enable_password: true
permissions: [list, download]
expiration_date: 1767225600000   # unix MILLISECONDS - 2026-01-01T00:00:00Z
```

```bash
# macOS - give the full time, or it inherits the current time-of-day
date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-01 00:00:00' +%s000
# GNU / Linux
date -u -d '2026-01-01' +%s000
```

## Sustained throughput - off the burstable family

`t4g` bursts on **both** CPU and network. For steady multi-Gbps use a non-burstable
instance; `cpu_credits` is then ignored.

```hcl
module "sftp" {
  # ...
  instance_type    = "c7g.large"   # 12.5 Gbps, no credit model, ~$53/mo
  root_volume_size = 100           # must exceed largest file x concurrent transfers

  # Larger parts cut request count and the wait while final parts flush. Costs memory:
  # SFTPGo holds upload_part_size x upload_concurrency per active upload.
  upload_part_size   = 32
  upload_concurrency = 8
}
```

## Alarms wired to a topic

The four alarms are always created. Without a topic they show state in the console but
page nobody.

```hcl
module "sftp" {
  # ...
  alarm_sns_topic_arns      = [aws_sns_topic.ops.arn]
  disk_used_alarm_threshold = 70
  log_retention_days        = 90
}
```

## Inspection-only admin panel

```hcl
module "sftp" {
  # ...
  admin_username = "ops-readonly"
  admin_permissions = [
    "view_users", "view_conns", "view_status", "view_defender", "view_events",
  ]
}
```

Users are managed in Terraform anyway, so a read-only panel is often the right call -
anything created in the UI is overwritten by the next sync.

## Operator commands

The module ships `scripts/sftpctl`. Copy that one file into your project's `scripts/`
folder, expose the module's outputs, and add two Makefile targets.

```hcl
# stack/outputs.tf - none of the module's outputs are sensitive
output "sftp" {
  value = module.sftp
}
```

```make
SFTPCTL = $(SCRIPTS)/sftpctl

sftp-rebuild:
	@cd $(TERRAGRUNT_DIR) && terragrunt run -- apply -replace='module.sftp.aws_instance.this'

sftp-%:
	@$(MAKE) -s tfoutput | $(SFTPCTL) $* \
		--profile $(_AWS_PROFILE) --region $(_AWS_REGION) --user "$(user)"
```

```bash
make sftp-info                     # endpoint, port, bucket, users, fingerprints
make sftp-admin                    # SSM tunnel to the admin panel + credentials
make sftp-password user=acme-corp  # one user's generated password
make sftp-known-hosts              # lines a partner pre-pins (required for automation)
make sftp-logs                     # tail SFTPGo - every auth attempt with source IP
make sftp-shell                    # shell on the host, no SSH
make sftp-sync                     # manual retry if the apply-time push failed
```

Full setup notes, the command table, and the output shapes it accepts are in the
[README](README.md#operator-commands).
