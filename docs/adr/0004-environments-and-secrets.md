# 0004. Environments and secrets

- **Status:** Accepted, 1 Oct 2026 (D91, D92). Supersedes the cloud-apply part of D80 until accounts exist.

## Context

There are no cloud accounts and no paid budget. One small node cannot host dev, staging and prod of a stack of about 25 services. Every change must still be provable from CI alone.

## Decision

**Environments**

| | Runs on | How it is proven |
|---|---|---|
| dev | compose locally; ephemeral kind in CI | Every platform PR installs the full chart on kind and smoke-tests it |
| staging | the existing self-hosted preview | Deployed by the protected deploy workflow; fault drills allowed |
| prod | defined only | `helm lint` and kubeconform on `values-prod.yaml`; `terraform validate` and `plan` on `terraform/envs/prod` |

Terraform uses a directory per environment over shared modules, so prod credentials are never reachable from a staging run. CLI workspaces are not used.

**Secrets**
- Services read secrets only from environment variables, as today.
- Each environment's secrets are a SOPS file encrypted to that environment's age public key: `secrets/<env>.enc.yaml`. Only ciphertext is committed.
- The deploy workflow holds the age private key as a GitHub environment secret, decrypts into a Kubernetes Secret (or the compose env file) at deploy time, and never writes plaintext to the repo, logs or images.
- When a vault exists, External Secrets Operator replaces the decrypt step; services do not change.
- Rotation: re-encrypt to a new age key, update the environment secret, redeploy.

## Consequences

- Prod is reviewable and validated but not running; "prod-ready" claims are limited to what CI proves.
- Losing an environment's age key loses its secret file; the key is backed up offline by the owner.
