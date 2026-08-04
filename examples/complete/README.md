# Complete example

A working SFTP endpoint in the account's default VPC, with users loaded from
`users/*.yaml`.

```bash
terraform init
export AWS_PROFILE=your-profile   # the apply-time sync shells out to the AWS CLI
terraform apply -var 'name=sftp-example' -var 'aws_profile=your-profile'
```

Then:

```bash
terraform output endpoint
terraform output usernames

# a user's password
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw passwords_secret_arn)" \
  --query SecretString --output text | jq -r '."acme-corp"'

# host key fingerprints, for the partner's known_hosts
terraform output -json host_public_keys | jq -r '.[]' > /tmp/k
while read -r K; do echo "$K" > /tmp/k.pub && ssh-keygen -lf /tmp/k.pub; done < /tmp/k
```

## Before you use this for real

- **`allowed_cidr_blocks` defaults to `0.0.0.0/0`.** Narrow it to partner egress IPs -
  an internet-facing SFTP port is the largest piece of attack surface in this design.
- The three files in `users/` are illustrative. `globex.yaml` carries a placeholder
  public key and an RFC 5737 documentation CIDR, so it cannot be used as-is.
- This uses the **default VPC** for convenience. In a real project, pass your own
  `vpc_id` and a public `subnet_id`.

## Cleaning up

```bash
terraform destroy
```

The bucket is created with `force_destroy = false`, so `destroy` fails if partners have
uploaded anything. Empty it first, or set `bucket_force_destroy = true` on the module -
and think about whether you mean it.
