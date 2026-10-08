# te-tengo-infra

Infrastructure for **Te Tengo**: create the VM, configure the server and deploy the backend. Production must cost (almost) nothing, so **only the VM comes from a cloud provider**: an **Oracle Cloud (OCI) Always Free** Ampere A1 VM (1 OCPU / 6 GB, half of the tenancy's allowance). Clips, database dumps and the Terraform state live in **Cloudflare R2**, DNS records are created by hand at the registrar (**Namify**), the landing page is on Cloudflare Pages, push goes through Firebase Cloud Messaging and e-mail through a generic SMTP relay.

| Folder | Tool | Contains |
|---|---|---|
| `envs/oci/`, `modules/te-tengo-oci/` | Terraform | **Active.** One `VM.Standard.A1.Flex` (Ubuntu 24.04 aarch64) in a minimal VCN; firewall open on 80, 443 (TCP+UDP) and 8322, SSH only from `admin_cidrs`; renders the Ansible inventory; tested offline with a mocked provider ([docs/terraform.md](docs/terraform.md)) |
| `envs/mvp/`, `modules/te-tengo/`, `bootstrap/` | Terraform | **Inactive AWS alternative**, never applied: the same host on EC2 `t4g.small`, "VM only" by default (S3, SES, SNS and Route53 optional); verified against the Floci emulator through `envs/local/` |
| `ansible/` | Ansible | Configure the host over SSH (OCI) or SSH over SSM (AWS): updates, swap, host firewall, Docker; deploy `compose/`; daily PostgreSQL backups to R2 ([docs/ansible.md](docs/ansible.md)) |
| `compose/` | Docker Compose | Caddy (TLS), `te-tengo-general-api`, PostgreSQL 18 and MediaMTX (live view). With video processed on the household PC (ADR 0007 in the desktop agent repository), there is **no detection container** |
| `test/` | Docker | Local stand-in for the VM (Ubuntu 24.04 + systemd + SSH) and Floci as the S3-compatible store: `make test-all` deploys and smoke-tests the stack without any cloud account |

**Deploying:** [docs/deploy.md](docs/deploy.md) (runbook, secrets, rollback). **Contract between Terraform and Ansible:** [docs/interface-terraform-ansible.md](docs/interface-terraform-ansible.md).

**Reference:** the physical architecture lives in `04-arquitectura/` of `Te-Tengo-Tech/docs` (Spanish). It must be updated for processing on the household PC and for OCI + R2.

**Never commit credentials or state files** (`*.tfstate`, `.terraform/`, `*.tfvars`, `backend.hcl`, `~/.oci/config`, the Ansible vault unencrypted); see `.gitignore`. Applies are run by an operator: CI never plans or applies against a real cloud.
