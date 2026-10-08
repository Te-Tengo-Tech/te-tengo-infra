# te-tengo-infra

Infrastructure for **Te Tengo**: create the AWS resources, configure the server and deploy the backend.

| Folder | Tool | Will contain |
|---|---|---|
| `bootstrap/`, `envs/`, `modules/` | Terraform | One EC2 `t4g.small` with an Elastic IP in a minimal VPC, private S3 buckets for clips and backups, SES sender identity, least-privilege IAM and a GitHub OIDC deploy role; verified against the Floci emulator ([docs/terraform.md](docs/terraform.md)) |
| `ansible/` | Ansible | Install Docker and Nginx with a TLS certificate, and deploy `compose/` on the EC2 instance |
| `compose/` | Docker Compose | Production reverse proxy and `te-tengo-general-api`. With video processed on the household PC (ADR 0007 in the desktop agent repository), there is **no detection container** |

**Status:** initial structure; not implemented yet.

**Reference:** the physical architecture lives in `04-arquitectura/` of `Te-Tengo-Tech/docs` (Spanish). It must be updated for processing on the household PC.

**Never commit credentials or state files** (`*.tfstate`, `.terraform/`, `*.tfvars` with secrets); see `.gitignore`.
