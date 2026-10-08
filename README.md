# te-tengo-infra

Infrastructure for **Te Tengo**: create the AWS resources, configure the server and deploy the backend.

| Folder | Tool | Will contain |
|---|---|---|
| `terraform/` | Terraform | VPC, subnets, security groups, EC2, RDS for PostgreSQL, encrypted S3 clip bucket, S3 VPC endpoint, SNS and least-privilege IAM |
| `ansible/` | Ansible | Configure the EC2 host (updates, swap, Docker), deploy `compose/` and schedule PostgreSQL backups to S3 ([docs/ansible.md](docs/ansible.md)) |
| `compose/` | Docker Compose | Caddy (TLS), `te-tengo-general-api`, PostgreSQL 18 and MediaMTX (live view). With video processed on the household PC (ADR 0007 in the desktop agent repository), there is **no detection container** |
| `test/` | Docker | Local stand-in for the EC2 host (Ubuntu 24.04 + systemd) and Floci: `make test-all` deploys and smoke-tests the stack without AWS |

**Deploying:** [docs/deploy.md](docs/deploy.md) (runbook, secrets, rollback).

**Reference:** the physical architecture lives in `04-arquitectura/` of `Te-Tengo-Tech/docs` (Spanish). It must be updated for processing on the household PC.

**Never commit credentials or state files** (`*.tfstate`, `.terraform/`, `*.tfvars` with secrets); see `.gitignore`.
