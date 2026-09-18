# Examples

Worked examples for calling this module. Start with [README.md](README.md) for the quick
start, cost and input reference.

- [Defining users](#defining-users) - YAML files vs inline
- [Permission recipes](#permission-recipes) - read-only, write-only, shared folders
- [Restricting access](#restricting-access)
- [Onboarding and offboarding](#onboarding-and-offboarding)
- [Command reference](#command-reference)

---

## Defining users

Two ways. Both feed the same `users` input - pick on team size, not on features.

### Option A - one YAML file per user *(recommended)*

Best when partners come and go, or when someone who does not write Terraform needs to
review who has access. Onboarding is a one-file pull request and
`git log users/globex.yaml` is that partner's whole access history.

```
infrastructure/
├── sftp.tf
└── users/
    ├── acme-corp.yaml
    ├── globex.yaml
    └── vendor-drop.yaml
```

```hcl
# sftp.tf
module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = var.prefix
  vpc_id    = data.aws_vpc.this.id
  subnet_id = data.aws_subnets.public.ids[0]

  allowed_cidr_blocks = var.partner_ips

  # path.root, not a bare "users": fileset() resolves against the working
  # directory, which differs under Terragrunt.
  users = [
    for f in fileset("${path.root}/users", "*.{yaml,yml}") :
    yamldecode(file("${path.root}/users/${f}"))
  ]
}
```

```yaml
# users/globex.yaml - filename should match the username inside
username: globex
description: Globex nightly pull
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@globex.com
```

### Option B - inline HCL

Fine for two or three stable users that rarely change.

```hcl
module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = var.prefix
  vpc_id    = data.aws_vpc.this.id
  subnet_id = data.aws_subnets.public.ids[0]

  users = [
    {
      username        = "acme-corp"
      description     = "Password auth"
      enable_password = true
    },
    {
      username    = "globex"
      description = "Key auth"
      public_keys = ["ssh-ed25519 AAAAC3Nza... ops@globex.com"]
    },
  ]
}
```
---

## Permission recipes

`permissions` defaults to full read/write in the user's own prefix:
`list`, `download`, `upload`, `overwrite`, `delete`, `rename`, `create_dirs`.

Override it for anything narrower.

### Password only

They log in with a generated password. Read it with
`make sftp-password user=acme-corp`.

```yaml
username: acme-corp
description: ACME nightly invoice drop
enable_password: true
```

### Key only

No password is generated at all. Ask the partner to send you the **public** half of a key
they generate - never generate it for them.

```yaml
username: globex
description: Globex automated pull
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@globex.com
```

### Password *or* key

Set both and either works, whichever the client offers. Useful when a person and a cron
job share an account.

```yaml
username: partner-x
description: Scripted pull, manual fallback
enable_password: true
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@partner.com
```

### Write-only drop box

They can send files and see what they sent, but never download. Good for inbound PII you
do not want a compromised partner account able to pull back out.

```yaml
username: vendor-drop
description: One-way ingest
enable_password: true
permissions:
  - list        # required, or GUI clients fail on connect
  - upload
  - overwrite   # required, or re-sending the same filename fails
```

### Read-only distribution

They collect reports and cannot modify anything.

```yaml
username: reports-reader
description: Pulls generated reports
public_keys:
  - ssh-ed25519 AAAAC3Nza... reader@corp.com
key_prefix: shared/reports/
permissions:
  - list
  - download
```

### Two users sharing a folder

`key_prefix` does not create anything - S3 has no real folders, only keys. It is a chroot
over keys that already exist, so pointing two users at one prefix gives both access to
what is already there.

```yaml
# users/writer.yaml
username: writer
enable_password: true
key_prefix: shared/reports/
```

```yaml
# users/reader.yaml
username: reader
enable_password: true
key_prefix: shared/reports/
permissions:
  - list
  - download
```

### Quotas and throttling

```yaml
username: bulk-partner
enable_password: true
quota_size: 53687091200      # 50 GiB in bytes, 0 = unlimited
max_sessions: 4              # concurrent connections
upload_bandwidth: 10240      # KB/s
download_bandwidth: 10240    # KB/s
```

### Temporary access

`expiration_date` is unix **milliseconds**. The account stops working on its own.

```bash
# get the value for 2026-12-31
python3 -c "import datetime;print(int(datetime.datetime(2026,12,31).timestamp()*1000))"
```

```yaml
username: audit-temp
enable_password: true
expiration_date: 1798675200000
permissions:
  - list
  - download
```

---

## Restricting access

Two independent layers. Use both.

**1. The security group** - who can reach the port at all.

```hcl
allowed_cidr_blocks = [
  "203.0.113.10/32",     # partner A
  "198.51.100.0/24",     # partner B
  "49.34.161.102/32",    # office
]
```

A partner whose IP is missing gets a **timeout**, not an auth error. This is the most
common onboarding confusion - check it first when someone says "it just hangs".

**2. Per-user `allowed_ip`** - which source IPs *that account* may use.

```yaml
username: globex
public_keys:
  - ssh-ed25519 AAAAC3Nza... ops@globex.com
allowed_ip:
  - 198.51.100.0/24
```

The security group cannot do per-user. If two partners share the endpoint, the group must
allow both ranges - and then nothing stops partner A trying partner B's credentials from
their own network. `allowed_ip` is what pins each account to its own range. Add the range
to **both** lists when you use it.

---

## Onboarding and offboarding

### Add a partner

```bash
cat > users/newpartner.yaml <<'EOF'
username: newpartner
description: Acme subsidiary, monthly statements
enable_password: true
EOF

# add their egress IP to allowed_cidr_blocks, then:
terraform apply
```

Takes seconds. **The instance is not touched** - no rebuild, no dropped transfers.

Then send them, over separate channels:

```bash
make sftp-info                          # endpoint and port
make sftp-password user=newpartner      # password - send this separately
```

### Remove a partner

```bash
git rm users/oldpartner.yaml
terraform apply
```

That revokes them. The push deletes any account the YAML no longer declares, so access is
gone as soon as the apply finishes. You will see it in the output:

```
revoking oldpartner (no longer declared in Terraform)
```

Their files stay in S3 under their prefix. Remove those separately if you need to.

### Rotate one password

```bash
# delete the user's file, apply, re-add it, apply again - a new password is generated
make sftp-password user=partner
```

Changing `password_length` rotates **every** credential at once, including the admin.

---

## Command reference

All of these read `terraform output -json`.

### Day to day

```bash
make sftp-info
```
```
endpoint: 203.0.113.25
port:     22
bucket:   myproject-dev-sftp
users:
  - acme-corp
  - globex
```

```bash
make sftp-password user=acme-corp      # one user's password
make sftp-logs                         # live tail, every auth attempt with its source IP
```

Send the partner the endpoint, port, username and password. Their client will ask them to
accept the host key on first connect, which is normal.

### Admin panel

```bash
make sftp-admin
```

Prints the credentials, then opens a tunnel. Browse to
**http://localhost:8080/web/admin**. Ctrl-C closes it.

Treat it as **read-only** - connection status, transfer history, quota usage, ban list.
Users created there are overwritten by the next apply, because Terraform is the source of
truth.

### Troubleshooting

```bash
make sftp-shell                        # shell on the host, over SSM - no SSH
make sftp-sync                         # re-push the CURRENT secret, e.g. after replacing the host 
# NOTE: does not pick up YAML edits - use terraform apply for those
make sftp-rebuild                      # replace the instance (~2 min)
```

| Symptom | Cause |
|---|---|
| Connection **times out** | Their IP is not in `allowed_cidr_blocks` |
| `Permission denied` | Wrong password, or a key you did not add |
| Logs in but sees nothing | Wrong `key_prefix`, or the prefix has no objects yet |
| GUI client fails on connect | `list` missing from `permissions` |
| Re-upload of same filename fails | `overwrite` missing from `permissions` |
| Removed user can still log in | The apply did not finish. Re-run `terraform apply` |

### Without Make

```bash
terraform output -json | ./scripts/sftpctl info
terraform output -json | ./scripts/sftpctl password --user acme-corp
terraform output -json | ./scripts/sftpctl admin --profile dev --region us-west-2
./scripts/sftpctl --help
```
