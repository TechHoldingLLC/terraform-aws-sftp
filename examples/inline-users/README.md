# Minimal example — users inline

The `users-from-yaml` loader is optional. With two or three stable users, pass `users`
directly as HCL and skip it.

```bash
terraform init
terraform apply
```

## What you give up

The loader validates key names. Terraform **silently drops** unrecognised keys when
coercing to an object type, so without it a typo like `permissons = ["list"]` is ignored
and the user quietly receives the module's *default* permissions instead of your
restricted set — wrong access, clean plan, no warning.

With inline HCL you at least get an editor and `terraform validate` catching unknown
attributes, which is why this is a reasonable trade at small scale. It stops being one
once the list grows or non-Terraform people start editing it.
