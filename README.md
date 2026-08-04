# terraform-aws-sftp

Self-hosted SFTP endpoint backed by S3 — SFTPGo on a single Graviton EC2 instance.

A drop-in replacement for AWS Transfer Family at roughly **$33/month instead of $219**,
supporting **passwords and SSH keys per user**, which is the one thing Transfer Family
makes awkward: its service-managed mode is key-only, and passwords need either AWS
Managed AD or a custom Lambda identity provider you write and maintain.

| | Transfer Family | This module |
|---|---|---|
| Fixed monthly cost | **$219** per protocol | **~$33** |
| Data in | $0.04/GB | free |
| Data out | $0.04/GB | $0.09/GB egress, first 100 GB free |
| Passwords + keys together | AD or custom Lambda IdP | native |
| Availability | AWS-managed | yours — single AZ |

**Owns the SFTP tier only.** Networking is an input, never created here — you pass a
`vpc_id` and `subnet_id` that already exist, so it drops into a project that has its own
VPC.

---

## Quick start

Four pieces: the module, the user loader, a directory of users, and — for day-to-day
operations — the `sftpctl` script plus two Makefile targets.

```hcl
# stack/sftp.tf

module "sftp_users" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git//modules/users-from-yaml?ref=v1.0.0"

  path = "${path.root}/users"
}

module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v1.0.0"

  name        = var.prefix              # e.g. "myproject-dev"
  aws_profile = var.aws_profile         # for the user-sync provisioner; "" in CI

  vpc_id    = module.vpc.id
  subnet_id = element(module.subnet_public.public_subnet_ids, 0)
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  allowed_cidr_blocks = ["203.0.113.0/24"]   # partner egress IPs

  users = module.sftp_users.users
}
```

```yaml
# stack/users/globex.yaml   — filename must match the username
username: globex
description: Globex nightly pull
key_only: true
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@globex.com
```

```hcl
# the AMI — Amazon Linux 2023 arm64
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}
```

`terraform apply`. Runnable versions of the above are in
[`examples/complete/`](examples/complete) and
[`examples/inline-users/`](examples/inline-users).

Pin **both** modules to the same `ref` — they ship from one tag, which is what keeps the
loader's validation in step with the module's schema.

**Then set up the operator commands** — three short steps, and without them you have a
running endpoint with no convenient way to read a password or open the admin panel:
[Operator commands → Setting it up](#setting-it-up-in-your-project).

### Requirements

| | |
|---|---|
| Terraform | **≥ 1.14** — `terraform_data` preconditions in the loader |
| Providers | `aws >= 6.56`, `tls >= 4.3`, `random >= 3.9`, `null >= 3.2` — declare all four in your root `required_providers` |
| Subnet | **public** — route to an internet gateway. Partners must reach it, and the host pulls packages and reaches the AWS APIs without NAT |
| SSM | whoever runs Terraform needs `ssm:SendCommand` and `ssm:GetCommandInvocation`, because user changes are pushed over SSM. In CI, add these to the OIDC role |
| AMI | Amazon Linux 2023 **arm64** — the instance type must be Graviton to match |

---

## Documentation

| Read | For |
|---|---|
| this file | inputs, outputs, architecture, design decisions |
| [`EXAMPLE.md`](EXAMPLE.md) | **calling the module** — a worked example per scenario |
| [`modules/users-from-yaml/README.md`](modules/users-from-yaml/README.md) | **the user schema** — every field, worked examples, onboarding, offboarding, troubleshooting |
| [`examples/complete/`](examples/complete) | a runnable deployment |

---

## Inputs

Required: `name`, `vpc_id`, `subnet_id`, `ami_id`.

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | **required** | Name prefix for every resource, e.g. `"sftp-dev"` |
| `vpc_id` | string | **required** | Existing VPC to attach the host to |
| `subnet_id` | string | **required** | Existing **public** subnet |
| `ami_id` | string | **required** | AMI to launch. Must be Amazon Linux 2023 **arm64** |
| `users` | object list | `[]` | Per-user config — see the users README |
| `aws_profile` | string | `""` | CLI profile for the sync provisioner. Empty = ambient creds |
| `allowed_cidr_blocks` | list(string) | `["0.0.0.0/0"]` | Who may reach the SFTP port. **Narrow this** |
| `tags` | map(string) | `{}` | Extra tags, merged with provider `default_tags` |
| `instance_type` | string | `"t4g.medium"` | Must be arm64 (Graviton) |
| `cpu_credits` | string | `"unlimited"` | `unlimited` avoids throttling but bills surplus; `standard` throttles |
| `root_volume_size` | number | `20` | GB. Transfers stage on local disk even with an S3 backend |
| `ebs_kms_key_id` | string | `null` | Null uses the AWS-managed EBS key |
| `sftp_port` | number | `22` | Service gets `CAP_NET_BIND_SERVICE`, so 22 works unprivileged |
| `sftpgo_version` | string | `"2.7.5"` | Release to install, no leading `v` |
| `sftpgo_rpm_sha256` | string | pinned | Expected RPM digest; the bootstrap fails closed on mismatch |
| `max_auth_tries` | number | `3` | Failed auths per connection before disconnect |
| `defender_threshold` | number | `10` | Ban score. Each failed login scores 2, so ~5 tries |
| `defender_ban_time` | number | `30` | Minutes banned |
| `upload_part_size` | number | `16` | S3 multipart size, MB, min 5 |
| `upload_concurrency` | number | `4` | Parts in parallel per upload |
| `download_part_size` | number | `16` | S3 ranged download size, MB, min 5 |
| `download_concurrency` | number | `4` | Parts in parallel per download |
| `password_length` | number | `16` | Generated user and admin passwords. **Changing this rotates every credential** |
| `admin_username` | string | `"sftpadmin"` | Web admin. In the loaddata document, so it survives rebuilds |
| `admin_permissions` | list(string) | `["*"]` | Narrow to `view_*` for an inspection-only panel |
| `bucket_force_destroy` | bool | `false` | Allow deleting a non-empty bucket. Keep false with real data |
| `abort_incomplete_multipart_days` | number | `7` | Aborts orphaned upload parts — billed but invisible in the console |
| `noncurrent_version_expiration_days` | number | `30` | Deletes old object versions |
| `log_retention_days` | number | `30` | CloudWatch Logs retention |
| `alarm_sns_topic_arns` | list(string) | `[]` | Empty still creates the alarms, they just page nobody |
| `disk_used_alarm_threshold` | number | `80` | Root volume used percent that alarms |

## Outputs

| Name | Purpose |
|---|---|
| `endpoint` | Address partners connect to (the Elastic IP) |
| `port` | SFTP port |
| `usernames` | Map of username → S3 prefix |
| `passwords_secret_arn` | Secret with the username → password map |
| `admin_secret_arn` | Secret with the web admin credentials |
| `host_public_keys` | SSH host public keys, for partners' `known_hosts` |
| `bucket_name` | Bucket backing the SFTP tree |
| `instance_id` | For `aws ssm start-session` |
| `security_group_id` | To reference from other security groups |
| `log_group_name` | SFTPGo and bootstrap logs |
| `sync_document_name` | SSM document that pushes user changes |

---

## What it creates

```
                      partners
                         │ TCP 22
                    ┌────▼─────┐
                    │ Elastic  │  stable address — partner IP allowlists
                    │   IP     │  survive instance replacement
                    └────┬─────┘
   ┌─────────────────────▼──────────────────────┐
   │  EC2  t4g.medium  Amazon Linux 2023 arm64  │
   │  SFTPGo, unprivileged, CAP_NET_BIND_SERVICE│
   │  admin UI + REST API on 127.0.0.1:8080     │
   └──────┬──────────────────────┬──────────────┘
          │ instance role        │ SSM
    ┌─────▼─────┐        ┌───────▼────────┐
    │    S3     │        │ Secrets Manager│  host keys, user document,
    │  bucket   │        │   (4 secrets)  │  passwords, admin creds
    └───────────┘        └────────────────┘
```

Plus: security group, IAM role, CloudWatch log group, four alarms, and the SSM document
that pushes user changes.

---

## How it works

### Storage

**S3 is a native SFTPGo backend, not a FUSE mount.** Mountpoint for S3 supports no
random writes and no append; SFTP clients resume transfers, rename in place and write
out of order as a matter of course, so a FUSE mount produces intermittent,
client-specific corruption. SFTPGo talks to S3 through the AWS SDK with real multipart
uploads — no POSIX layer misrepresenting object storage.

Each user is confined to their own key prefix. The instance role is scoped to the
bucket; SFTPGo enforces the per-user boundary inside it.

**`key_prefix` is a view, not a folder.** S3 has no directories — only keys. The prefix
chroots a user over keys that already exist, so pointing two users at an existing prefix
grants shared access to it and creates nothing. It is a single chroot per user, though,
so a user gets either their own prefix or a shared one, not both; serving both would
need SFTPGo virtual folders, which this module does not currently expose.

### Users and the admin

`users` is rendered into an SFTPGo backup document, stored in Secrets Manager, and
imported at boot with `SFTPGO_LOADDATA_MODE=0` (add new, update existing). The web admin
is in the same document, so it survives instance replacement instead of dropping you
back on SFTPGo's first-run setup page.

**Changes are pushed to the running service, not baked into the host.**
`null_resource.sync_users` triggers on the secret's `version_id` and runs an SSM document
on the instance, which `POST`s the document to
`http://127.0.0.1:8080/api/v2/loaddata?mode=0`. Applied live — no restart, no downtime,
a couple of seconds. Because the command runs *on* the host, the admin API stays bound
to loopback and nothing is exposed.

**If API auth fails, it falls back to writing the document to disk and restarting.**
That path needs no authentication, which matters because rotating the admin password
would otherwise lock the API path out of its own update — the sync authenticates with
the very credential it is responsible for setting. The fallback costs a restart (a few
seconds, and it does drop in-flight transfers) and then self-heals: the next sync is back
on the zero-downtime path.

A failed sync fails the apply, so Terraform never claims to have converged when it
hasn't.

The instance is only replaced for host-level changes: `ami_id`, `instance_type`,
`root_volume_size`, `sftp_port`, or the SFTPGo tuning variables.

### Host keys

Generated by Terraform and stored in Secrets Manager, **not** made on the instance. If
the host generated its own, every replacement would change the fingerprint and every
partner's `known_hosts` check would fail at once — and worse, partners would learn to
click through the warning, which destroys the protection entirely.

Trade-off: the private host keys live in Terraform state. **State access is equivalent to
host-key access**, so the state bucket deserves the same care as the secret.

### Credentials

**No credentials in `user_data`** — it is readable by anything that can reach IMDS, so it
carries only secret ARNs. The host fetches keys and passwords at boot with its instance
role, and `SFTPGO_LOADDATA_CLEAN=1` deletes the plaintext once imported.

### Administration

**SSM, not SSH.** The OS `sshd` is disabled so port 22 belongs to SFTPGo. No admin key
pair to rotate, no second listener to harden, every session in CloudTrail.

The admin UI and REST API bind `127.0.0.1:8080` only:

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
# then browse http://localhost:8080/web/admin
```

An internet-exposed admin panel on the box holding every partner credential is not a
trade worth making.

**Treat the panel as read-only** — connection status, transfer history, quota usage,
defender bans. Users created there are overwritten by the next sync.

---

## Operator commands

The module ships **`scripts/sftpctl`** — one self-contained script covering everything
you do to a running endpoint, so you are not copying a wall of Makefile logic into every
project.

### Setting it up in your project

**1. Copy `scripts/sftpctl` into your project's `scripts/` folder** and make it
executable. Pull it straight from the tag you pinned the module to:

```bash
VERSION=v1.0.0
curl -fsSL -o infrastructure/scripts/sftpctl \
  https://raw.githubusercontent.com/TechHoldingLLC/terraform-aws-sftp/$VERSION/scripts/sftpctl
chmod +x infrastructure/scripts/sftpctl
git add infrastructure/scripts/sftpctl
```

Or, if you have the repo checked out locally:

```bash
cp ../terraform-aws-sftp/scripts/sftpctl infrastructure/scripts/sftpctl
chmod +x infrastructure/scripts/sftpctl
```

One self-contained file. It shells out to `aws`, `python3` and `ssh-keygen`, all of which
your project already needs. Re-copy it when you bump the module version.

Don't try to reference the module's own copy under `.terraform/modules/` — Terragrunt
runs Terraform inside `.terragrunt-cache/<hash>/<hash>/` and Terraform names that
directory after your *module block*, so any such path depends on both and breaks. The
copy is deliberate.

**2. Expose the module's outputs.** None of them are sensitive, so one block does it:

```hcl
# stack/outputs.tf
output "sftp" {
  value = module.sftp
}
```

Prefer explicit outputs? `sftpctl` also reads flat ones (`sftp_endpoint`,
`sftp_instance_id`, …) — see [Output shapes](#output-shapes).

**3. Add these targets to your Makefile:**

```make
#-----------------------------------------------------------------------------
#  SFTP  (terraform-aws-sftp)
#-----------------------------------------------------------------------------
SFTPCTL = $(SCRIPTS)/sftpctl

## replace the instance (~2 min). For AMI/instance changes, or to purge users
## no longer declared. EIP, host keys, bucket and users all survive
sftp-rebuild:
	@cd $(TERRAGRUNT_DIR) && terragrunt run -- apply -replace='module.sftp.aws_instance.this'

## everything else: info, admin, admin-password, password, hostkeys,
## known-hosts, shell, logs, sync
sftp-%:
	@$(MAKE) -s tfoutput | $(SFTPCTL) $* \
		--profile $(_AWS_PROFILE) --region $(_AWS_REGION) --user "$(user)"
```

`$(SCRIPTS)` is already defined in the TechHolding Makefile template as
`infrastructure/scripts`; point `SFTPCTL` wherever you actually put the file.

The single pattern rule covers every subcommand. `sftp-rebuild` is explicit because it
drives terragrunt rather than the script, and an explicit target beats a pattern rule.

### Commands

| Command | Does |
|---|---|
| `make sftp-info` | endpoint, port, bucket, users, host key fingerprints |
| `make sftp-admin` | SSM tunnel to the admin panel, printing credentials first |
| `make sftp-admin-password` | just the admin credentials |
| `make sftp-password user=X` | one user's generated password |
| `make sftp-hostkeys` | fingerprints, to give partners out-of-band |
| `make sftp-known-hosts` | pre-pin lines — required for automated clients |
| `make sftp-shell` | shell on the host over SSM, no SSH |
| `make sftp-logs` | tail SFTPGo — every auth attempt with its source IP |
| `make sftp-sync` | manual retry if the apply-time user push failed |
| `make sftp-rebuild` | replace the instance |

Or call it directly, without Make:

```bash
terraform output -json | ./scripts/sftpctl info
```

### Output shapes

`sftpctl` resolves each field across three shapes, so it works however you expose
things:

| Shape | Example output | Lookup |
|---|---|---|
| one object | `output "sftp" { value = module.sftp }` | `.sftp.value.endpoint` |
| flat, prefixed | `output "sftp_endpoint" { … }` | `.sftp_endpoint.value` |
| flat, bare | `output "endpoint" { … }` | `.endpoint.value` |

Pass `--prefix NAME` if yours is not `sftp`. When a field cannot be found it prints
every name it tried and the output block to add.

### Why a copy rather than an install

The script lives inside the module, but there is no reliable way for a consuming
Makefile to reach it: Terragrunt runs Terraform inside `.terragrunt-cache/<hash>/<hash>/`
and Terraform names the module directory after your *module block*, so any path would
depend on both. A one-file copy is boring and always works.

It is also stable — `sftpctl` only reads Terraform outputs and calls the AWS CLI, so an
older copy keeps working against a newer module unless an output is renamed. Re-copy it
when you bump the module version.

The Terraform provisioner uses its own in-module copy via `${path.module}`, which
resolves correctly, so **`terraform apply` and CI never depend on your copy** — only
humans do.

---

## Composition

Uses the TechHolding modules where they fit:

- `terraform-aws-s3-bucket` **v1.0.7** — bucket, versioning, SSE, TLS-only policy
- `terraform-aws-security-group` **v1.0.1** — security group and rules

Four things are raw resources on purpose:

**`aws_instance`, not `terraform-aws-ec2` v1.0.3.** Two gaps are load-bearing. It has no
`user_data_replace_on_change`, and `user_data` is `forcenew=false` in the AWS provider —
so a config change would be written to state and **never reach the running host**. And
`key_name` cannot be unset (it falls back to `var.name`), but `sshd` is disabled and
admin is SSM, so a key pair would be dead weight that has to exist or the launch fails
with `InvalidKeyPair.NotFound`. Both are small upstream additions worth a PR; once
merged, this can move behind the module.

**Lifecycle configuration.** The S3 module renders only
`abort_incomplete_multipart_upload`, `expiration` and `noncurrent_version_expiration`.
Its `lifecycle_rule` is `type = any`, so an unknown key like `transition` is dropped
silently rather than rejected.

**Public access block and ownership controls.** The S3 module creates these only when
`bucket_public_read_access = true` — i.e. when deliberately *opening* a bucket. For a
private bucket it creates neither, and the control that keeps partner data private
should be explicit.

**IAM, Secrets Manager, CloudWatch, SSM** — no TechHolding modules exist for these.

---

## Two upstream SFTPGo gotchas this module works around

Both fail **silently**, and both were found by reading the SFTPGo source rather than the
documentation:

1. **There is no `log` section in `sftpgo.json`.** Logging is configured only by CLI
   flags and `SFTPGO_LOG_*` env vars. SFTPGo uses viper, which ignores unknown config
   keys without complaint, so a `log` block looks correct and does nothing. The settings
   live in the systemd drop-in instead.
2. **Paths in `sftpgo.json` must be absolute.** SFTPGo resolves relative paths against
   the config dir `/etc/sftpgo`, which the unit's `ProtectSystem=full` mounts read-only.
   A relative `host_keys` finds nothing and **silently generates a fresh pair**; a
   relative sqlite name cannot be created at all.

The bootstrap therefore asserts, after startup, that no host keys were generated in
`/etc/sftpgo`, that the key being served matches the one from Secrets Manager, and that
the user import completed. All three **poll**, because systemd reports "active" as soon
as the process forks — well before the listener binds or the import finishes.

---

## Sizing

`t4g.medium` is 2 vCPU / 4 GiB, up to 5 Gbps. Graviton has hardware AES, so network and
per-transfer memory bind before CPU.

SFTPGo holds roughly `upload_part_size × upload_concurrency` per active upload — at the
defaults (16 MB × 4) that is **64 MB per transfer**, so five concurrent uploads is
~320 MB. Comfortable on 4 GiB.

**User count costs nothing** — users are rows in SQLite. Only *concurrent sessions*
consume resources.

Two burstable caveats:

- `cpu_credits` defaults to `unlimited`, which bills surplus credits rather than
  throttling. The `cpu-surplus-credits-charged` alarm makes that spend visible; if it
  fires steadily, move to `c7g.large` (~$53/mo, 12.5 Gbps, no credit model).
- T-family **network** bandwidth is also burstable. Sustained multi-Gbps needs a
  non-burstable family regardless of CPU credits.

`root_volume_size` must exceed largest expected file × concurrent transfers, because
transfers stage on local disk even with an S3 backend.

---

## Availability

Single instance, single AZ — deliberate, to keep the cost at ~$33/month. On hardware
failure the endpoint is down until replaced (~2 minutes). The EIP, host keys, bucket,
users and admin all survive, because none of them live on the host.

Upgrade path if that RTO is unacceptable:

1. **ASG of one** across two subnets — 2–4 minute self-heal, no cost change.
2. **Two nodes behind an NLB** with RDS as the shared data provider — active/active,
   adds ~$40/mo.

Moving the data provider to RDS is also what you would do if you wanted the admin panel
to genuinely own users rather than Terraform.

---

## Protocols

**SFTP only.** `sftpgo.json` sets `ftpd.bindings = []` and every user denies `FTP`, `DAV`
and `HTTP`.

Adding FTP back means an `ftpd` binding, security-group rules for the control port and
the passive range, dropping `FTP` from `denied_protocols`, and — for FTPS rather than
cleartext FTP — a certificate on the host plus `force_passive_ip` set to the Elastic IP.

---

## Cost, us-west-2

| Line item | Monthly |
|---|---|
| t4g.medium, 730 h on-demand | $24.82 |
| EBS gp3, 20 GB | $1.60 |
| Elastic IP | $3.65 |
| Secrets Manager, 4 secrets | $1.60 |
| CloudWatch Logs, ~2 GB | $1.00 |
| **Fixed total** | **~$33** |

Plus S3 at $0.023/GB-month, and $0.09/GB internet egress on downloads after the first
100 GB. Uploads are free. A 3-year Reserved Instance or Compute Savings Plan takes
compute to about $10/month.

Rates verified against the AWS Price List API.

**One assumption to keep in view:** this treats downloads as costing $0.09/GB egress, and
assumes Transfer Family's $0.04/GB is billed *in addition to* standard egress. If that
rate is actually all-in, Transfer Family's per-GB download cost is lower and the two
cross over around 3 TB/month of pure download volume. Below that this wins regardless;
above it, confirm the billing first. Settle it in Cost Explorer on an account with a live
Transfer Family endpoint: group by Usage Type and look for a `DataTransfer-Out-Bytes`
line tracking `DownloadBytes`.

---

## Licensing

SFTPGo Community is **AGPLv3**. This module installs the official upstream RPM
unmodified and changes only configuration, which carries **no source-disclosure
obligation** — the network clause bites only if you modify the source and let users
interact with it.

| | Obligation |
|---|---|
| Run the official binary unmodified | **None.** Attribution is satisfied by the upstream public repo |
| Change config, users, folders | **None.** Configuration is not source modification |
| Files passing through the server | **None.** Your data is not a derivative work |
| Your Terraform and surrounding app | **None.** AGPL does not cross a process boundary |
| Patch SFTPGo's Go source and run it | **Publish that patch** to the service's users |

The practical risk is policy, not law: some enterprise legal teams blanket-ban AGPL in a
dependency tree regardless. If a client's counsel takes that position, SFTPGo Enterprise
is a commercial licence that removes the AGPL terms. Worth asking before delivery rather
than at handover.

This module's own code is MIT — see [LICENSE](LICENSE).

---

## Development

```bash
terraform fmt -recursive
terraform init -backend=false && terraform validate
./scripts/check-user-schema      # the loader's key list vs the users schema
```

**When adding a field to `users`, add it to both** `variables.tf` and
`modules/users-from-yaml/main.tf`. The loader keeps its own key list because a module's
schema cannot be queried from outside it; `scripts/check-user-schema` fails CI if the two
diverge.

`scripts/sftpctl` **must stay executable in git** — Terraform preserves file modes when
cloning a module, so losing the bit breaks the apply-time user sync in consumers'
projects:

```bash
git update-index --chmod=+x scripts/sftpctl
```
