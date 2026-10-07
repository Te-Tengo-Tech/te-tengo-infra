# te-tengo-infra

Infraestructura de **Te Tengo**: crear los recursos en AWS, configurar el servidor y desplegar el backend.

| Carpeta | Herramienta | Qué tendrá |
|---|---|---|
| `terraform/` | Terraform | VPC, subredes, Security Groups, EC2, RDS for PostgreSQL, bucket S3 de clips con cifrado, VPC Endpoint de S3, SNS e IAM con permisos mínimos |
| `ansible/` | Ansible | Instalar Docker, Nginx con certificado TLS y desplegar `compose/` en la EC2 |
| `compose/` | Docker Compose | Producción: proxy inverso y `te-tengo-general-api`. Con el procesamiento en la vivienda (ADR 0007 del agente) **no hay contenedor de detección**. |

**Estado:** estructura inicial; pendiente.

**Referencia:** la arquitectura física está en `04-arquitectura/` de `Te-Tengo-Tech/docs`. Debe actualizarse con el procesamiento en la vivienda.

**Nunca se suben credenciales ni archivos de estado** (`*.tfstate`, `.terraform/`, `*.tfvars` con secretos); ver `.gitignore`.
