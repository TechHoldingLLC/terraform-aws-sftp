# `users-from-yaml` submodule

Loads SFTP users from **one YAML file per user** and validates them, so a typo fails
`terraform plan` instead of silently granting the wrong access.

Emits raw maps for the parent module's typed `users` variable. It applies **no
defaults** - the parent does that - so defaults live in exactly one place.

Optional. If you have two users and no need for a directory, pass `users` to the parent
module as inline HCL instead and skip this. See `examples/inline-users/`.

## Usage

```hcl
module "sftp_users" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git//modules/users-from-yaml?ref=v0.0.1"
  path   = "${path.root}/users"
}

module "sftp" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-sftp.git?ref=v0.0.1"

  name      = var.prefix
  vpc_id    = module.vpc.id
  subnet_id = element(module.subnet_public.public_subnet_ids, 0)
  ami_id    = data.aws_ssm_parameter.al2023_arm64.value

  users = module.sftp_users.users
}
```

Pin **both** to the same `ref`. They ship from one repo and one tag, which is what
guarantees the loader's key list matches the parent's schema.

### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `path` | string | **required** | Directory of `*.yaml` user files. Use `"${path.root}/users"` |
| `pattern` | string | `"*.yaml"` | Glob within `path` |

### Outputs

| Name | Description |
|---|---|
| `users` | User definitions, for the sftp module's `users` variable |
| `usernames` | Sorted usernames, for a quick sanity check |

### Why `${path.root}` and not `"users"`

`fileset()` resolves relative paths against the **process working directory**, not the
module, so a bare `"users"` breaks depending on where Terraform is invoked from. Under
Terragrunt the stack is copied into `.terragrunt-cache/.../stack/` and the `users/`
directory travels with it, so `${path.root}/users` resolves correctly there too.

---

# Managing users

**One YAML file per user.** The filename must match the `username` inside it -
`globex.yaml` declares `username: globex`. Onboarding a partner is adding a file,
offboarding is deleting one, and `git log users/globex.yaml` is that partner's access
history.

You never touch the server, the SQLite database, or the JSON document in Secrets
Manager by hand.

## Quick start

```bash
# 1. create the file
cat > users/acme-corp.yaml <<'EOF'
username: acme-corp
enable_password: true
description: ACME nightly invoice drop
EOF

# 2. review - the instance should NOT be replaced
terraform plan

# 3. apply - this also pushes the change to the running server
terraform apply
```

Also add the partner's egress IPs to the sftp module's `allowed_cidr_blocks`. The
security group is allowlisted, so a partner whose IP is missing gets a **timeout**, not
an auth error - the most common onboarding failure by a wide margin.

## Field reference

Only `username` is required.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `username` | string | **required** | Login name, default S3 prefix, must match the filename |
| `description` | string | `""` | Free-text note, shown in the admin panel |
| `key_prefix` | string | `"<username>/"` | S3 prefix the user is confined to. **Must end in `/`** |
| `public_keys` | list(string) | `[]` | Partner's **public** keys, `authorized_keys` format |
| `enable_password` | bool | `true` | Generate a password and allow password auth |
| `key_only` | bool | `false` | Deny password auth. Overrides `enable_password` |
| `password_only` | bool | `false` | Deny public-key auth |
| `permissions` | list(string) | see below | What the user may do, applied at `/` |
| `quota_size` | number | `0` | Max stored **bytes**. `0` = unlimited |
| `max_sessions` | number | `0` | Max concurrent sessions. `0` = unlimited |
| `upload_bandwidth` | number | `0` | Upload throttle in **KB/s**. `0` = unlimited |
| `download_bandwidth` | number | `0` | Download throttle in **KB/s**. `0` = unlimited |
| `allowed_ip` | list(string) | `[]` | Per-user source CIDR allowlist. Empty = any source |
| `expiration_date` | number | `0` | Account expiry, unix **milliseconds**. `0` = never |

Watch the units: `quota_size` is **bytes**, bandwidth is **KB/s**, `expiration_date` is
**milliseconds**. These are SFTPGo's own units, passed through unchanged.

### `permissions`

Default is `list`, `download`, `upload`, `overwrite`, `delete`, `rename`,
`create_dirs` - ordinary read/write.

| Value | Allows |
|---|---|
| `*` | everything |
| `list` | directory listings. **Without this a client sees nothing** |
| `download` | reading files |
| `upload` | writing new files |
| `overwrite` | replacing an existing file |
| `delete` | `delete_files` + `delete_dirs` |
| `delete_files` / `delete_dirs` | files or directories only |
| `rename` | `rename_files` + `rename_dirs` |
| `rename_files` / `rename_dirs` | files or directories only |
| `create_dirs` | mkdir |
| `create_symlinks` | symlinks |
| `chmod` / `chown` / `chtimes` | permission and timestamp changes |

`chmod`, `chown`, `chtimes` and `create_symlinks` are left out of the default
deliberately - the first three are meaningless on object storage, and symlinks are a
path-escape vector.

**Two permission traps that generate support tickets:**

- **Omitting `list`** - the partner authenticates fine and then their client fails.
  GUI clients (FileZilla, Cyberduck, WinSCP) request a directory listing immediately on
  connect, so without `list` they report the whole connection as broken:
  ```
  Error: Could not get initial directory: Received error SSH_FX_PERMISSION_DENIED
  Error: Failed to retrieve directory listing
  ```
  A CLI client would connect, fail on `ls`, and still upload.
- **`upload` without `overwrite`** - the first upload of a filename works and every
  retry fails. Bites partners who re-send a daily `invoices.csv`.

---

## Examples

Each block is the entire contents of one file.

### Password auth - the common case

```yaml
username: acme-corp
enable_password: true
description: ACME nightly invoice drop
```

Lands in `s3://<bucket>/acme-corp/`. Read the password with
`make sftp-password user=acme-corp` (see the root README for the Makefile targets).

### Key-only

```yaml
username: globex
key_only: true
description: Globex automated pull
public_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... ops@globex.com
```

No password is generated. The partner generates the keypair - see
[Key handover](#key-handover).

### Both password and key

```yaml
username: partner-b
enable_password: true
public_keys:
  - ssh-ed25519 AAAAC3Nza... them@partner.com
```

Either method works. Useful while a partner migrates from password to key.

### Write-only drop box

Can deposit files but not download anyone's contents.

```yaml
username: vendor-drop
enable_password: true
description: One-way ingest - sees filenames, cannot download
permissions:
  - list
  - upload
  - overwrite
```

If you genuinely need filenames hidden, drop to just `- upload` - but then **no GUI
client can be used**, only automation doing blind `put`s. You cannot have both hidden
filenames and FileZilla.

### Read-only distribution

```yaml
username: reports-reader
key_only: true
description: Pulls generated reports, cannot modify anything
public_keys:
  - ssh-ed25519 AAAAC3Nza... reader@corp.com
permissions:
  - list
  - download
```

### Capped and throttled

```yaml
username: bulk-partner
enable_password: true
description: High-volume feed, capped so it cannot starve others
quota_size: 107374182400   # 100 GiB, in bytes
max_sessions: 4
upload_bandwidth: 10240    # 10 MB/s, in KB/s
download_bandwidth: 10240
```

Bandwidth limits are the lever when one partner's bulk transfer starves everyone else
on a `t4g.medium`.

### IP-locked

```yaml
username: secure-partner
enable_password: true
description: Only from the partner's documented egress ranges
allowed_ip:
  - 203.0.113.0/24     # replace - RFC 5737 doc range, never routable
```

**Two independent layers.** `allowed_cidr_blocks` (security group) controls who
can reach port 22 at all; `allowed_ip` controls which sources may authenticate as *this
user*. Add the range to both, or the partner gets a timeout before SFTPGo is even
consulted.

### Shared folder between two partners

```yaml
# users/partner-x.yaml
username: partner-x
key_prefix: shared/inbound/
enable_password: true
```
```yaml
# users/partner-y.yaml
username: partner-y
key_prefix: shared/inbound/
enable_password: true
```

Both see the same directory - including each other's files.

### Time-limited access

```yaml
username: auditor-temp
enable_password: true
description: Q4 audit access, expires automatically
permissions:
  - list
  - download
expiration_date: 1767225600000   # 2026-01-01T00:00:00Z
```

```bash
# macOS - give the full time, or it inherits the current time-of-day
date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-01 00:00:00' +%s000
# GNU / Linux
date -u -d '2026-01-01' +%s000
```

### A realistic directory

```
users/acme-corp.yaml      # password, nightly invoices
users/globex.yaml         # key-only, IP locked, 50 GiB quota
users/vendor-drop.yaml    # list + upload + overwrite only
users/bulk-feed.yaml      # throttled, max 2 sessions
```

`ls users/` answers "who has access" without reading any Terraform.

---

## How a change reaches the server

`make apply` updates the Secrets Manager document, then pushes it to the **running**
service. **No instance replacement and no downtime.**

The push is `null_resource.sync_users` in the module: it triggers on the secret's
`version_id` and runs the `-sftp-sync-users` SSM document on the host, which fetches
the document and `POST`s it to `http://127.0.0.1:8080/api/v2/loaddata?mode=0`. SFTPGo
applies it live - no restart, so active transfers are not interrupted. Takes a couple
of seconds.

Because the command runs *on* the instance, the admin API stays bound to loopback and
nothing is exposed.

The apply output ends with the users and admins the server actually has, so you can
confirm convergence rather than trusting an HTTP 200:

```
document: 3 user(s), 1 admin(s)
loaddata OK: {"message":"Data restored"}
  --- users now on the server ---
    harshvardhan  prefix=harshvardhan/  status=1
    partner-a     prefix=partner-a/     status=1
    upload_only   prefix=reports/       status=1
```

**If the sync fails, the apply fails** - deliberately, so Terraform never claims to
have converged when it hasn't. Retry with `make sftp-sync`, or re-run the SSM document by hand. That is also how you
recover the admin account if it is ever deleted, without a rebuild.

### When the instance *is* replaced

Only for host-level changes: `ami_id`, `instance_type`, `root_volume_size`,
`sftp_port`, the SFTPGo tuning variables, or an explicit instance replacement. That
costs ~2 minutes of downtime. The Elastic IP, host keys, bucket contents, admin and all
users survive - none of them live on the host, so a fresh instance imports the current
document at boot.

**If `make plan` wants to replace the instance after only a user change, stop and look
at what else you touched.**

---

## What `make plan` catches

Before anything is created:

- **an unrecognised key.** This one matters most: Terraform silently *drops* unknown
  keys when coercing YAML to its object type, so `permissons: [list]` would be ignored
  and the user would quietly get the **default** permissions instead of yours. The
  stack checks key names explicitly to turn that into a hard error.
- a `username` that doesn't match its filename
- an empty `users/` directory
- duplicate usernames
- a `username` breaking `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`
- a `key_prefix` not ending in `/`
- `key_only` together with `password_only`
- `key_only` with no `public_keys` - could never log in
- neither `enable_password: true` nor any `public_keys` - same problem

What it does **not** catch: a misspelled *value*, like `permissions: [downlod]`.
SFTPGo rejects that at import, so the sync fails and the apply fails - later, but not
silently.

---

## Key handover

**The partner generates their own keypair.** You only ever receive the public half:

```bash
# the partner runs this
ssh-keygen -t ed25519 -f ~/.ssh/sftp-yourcompany -C "ops@partner.com"
# they send you ~/.ssh/sftp-yourcompany.pub
```

Paste that one line into `public_keys`. The private key never touches your
infrastructure - that is the entire point of key auth.

**Public keys belong in git.** They are public by design; GitHub serves everyone's at
`github.com/<user>.keys`. Committing them is correct and gives you a reviewable
history of who has access. It is the *private* key that matters.

**Don't generate client keys in Terraform.** It works, but the private key lands in
state and you then have to transmit it to the partner - which throws away the
advantage and leaves you a secret to look after.

One formatting trap: keep each key on a single line under `- `. YAML will fold a long
line if you indent oddly, and a mangled key fails auth with no obvious error.

---

## What to send a new partner

| Item | Terraform output / helper |
|---|---|
| Host and port | `endpoint`, `port` |
| Username | whatever you set |
| Password | `passwords_secret_arn` → read that key from Secrets Manager |
| Their S3 prefix | `usernames` |
| Host key fingerprints | `host_public_keys` → `ssh-keygen -lf` |
| `known_hosts` lines | `endpoint` + `host_public_keys` |

The root README ships `make sftp-info`, `sftp-password`, `sftp-hostkeys` and
`sftp-known-hosts` wrappers for these.

The `known_hosts` line is **optional for a human** with a GUI client - they get a
trust-on-first-use prompt and click Accept. It is **required for automation**: a
scripted `sftp` with the default `StrictHostKeyChecking=ask` hangs waiting for input
that never arrives, and paramiko rejects outright.

Send the fingerprint over a different channel than the credentials if the data is
sensitive. An attacker who can intercept the email carrying the hostname and password
can also swap the fingerprint in that same email.

---

## Offboarding

**Deleting the file does not immediately revoke access.** The import runs with
`SFTPGO_LOADDATA_MODE=0` - add new, update existing. It never deletes, so a removed
user keeps working until the next instance rebuild.

It *does* take effect on a **rebuild**: a fresh instance starts with an empty database
and imports only what is declared, so anyone no longer listed disappears. That makes
an instance replacement a reconcile-and-purge - useful, but it costs ~2 minutes of downtime
and is easy to forget.

Don't rely on that. To revoke now, pick one:

1. **Expire them** - declarative, stays in git as a record. Keep the file; delete it
   later once you're sure.
   ```yaml
   username: old-partner
   enable_password: true
   expiration_date: 1
   ```
2. **Delete in the admin panel** - port-forward to `127.0.0.1:8080`, then Users → delete. Immediate,
   but not recorded in Terraform, so also delete their `users/*.yaml` or the next apply
   recreates them.

Then tidy up: remove their IPs from `allowed_cidr_blocks`, and decide whether
their S3 prefix should be deleted or retained.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Connection **times out** | Their IP isn't in `allowed_cidr_blocks` |
| `Permission denied` | Wrong password, or `key_only` with a key you didn't add |
| Connects but directory is **empty** | `list` missing from `permissions` |
| `SSH_FX_PERMISSION_DENIED` on connect | Same - `list` missing, GUI client can't get its initial listing |
| First upload works, retries fail | `overwrite` missing from `permissions` |
| Locked out after a few tries | Brute-force defender - ~5 failed attempts triggers a 30 min ban |
| New user can't log in after apply | The sync may have failed - `make sftp-sync`, then check the logs |

```bash
make sftp-logs     # every auth attempt, with source IP
make sftp-admin    # panel: Connections, and Defender for the ban list
```

(or `aws logs tail <log_group_name>` and an SSM port-forward to `127.0.0.1:8080`)

**If the log shows no attempt at all, it never reached the server** - that's the
security group or DNS, not SFTPGo.

---