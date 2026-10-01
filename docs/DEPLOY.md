# Deploying SwiftBets

The same umbrella chart (`charts/swiftbets`) installs on any conformant cluster. Two value files cover the two shapes:

| | `values-local.yaml` | `values-prod.yaml` |
|---|---|---|
| Where | kind, k3d, k3s, Docker Desktop | The OCI Always Free ARM VM running k3s |
| Betstore | In-cluster SQL Server | Azure SQL (free offer), over TLS |
| Secrets | Demo secret rendered by the chart | `swiftbets-secrets`, written by Terraform |
| Fault drills | On | Off (Steward refuses drills in Production) |

## Any local cluster

```bash
make k8s-up      # kind cluster + install; about 10 minutes the first time (image pulls)
kubectl -n swiftbets port-forward svc/gateway 7100:8080
# http://127.0.0.1:7100  operator1 / Local-Dev-Demo-1
make k8s-down
```

On an existing cluster, skip kind:

```bash
scripts/helm-deps.sh
helm upgrade --install swiftbets charts/swiftbets -n swiftbets --create-namespace -f charts/swiftbets/values-local.yaml --wait
```

kind on Linux hosts with the default `fs.inotify.max_user_instances=128` can crash kube-proxy ("too many open
files"). Raise it (`sudo sysctl fs.inotify.max_user_instances=512`) or stop other inotify-heavy processes first.

## Environments (D91, ADR 0004)

| Environment | Runs on | Proven by |
|---|---|---|
| dev | compose locally; kind in CI | Every platform PR installs the full chart on kind and smoke-tests it |
| staging | the existing self-hosted preview (compose) | The preview itself; fault drills allowed |
| prod | defined only: `values-prod.yaml` and `terraform/envs/prod` | CI lints and renders it, runs `scripts/check-prod-values.sh` and kubeconform, and validates the Terraform root. Nothing is applied until accounts exist |

Production refuses to render without a released image tag (`global.requireReleaseTag`), seeds no demo users, has
fault injection off and runs no in-cluster SQL Server; `scripts/check-prod-values.sh` fails CI if any of that changes.

## Production (OCI + Azure SQL), once accounts exist

Prerequisites: an OCI account (API key configured for the `oci` CLI/provider), an Azure subscription (`az login`), an
Object Storage bucket for state with a Customer Secret Key, and your SSH public key.

```bash
cd terraform/envs/prod
cp backend.hcl.example backend.hcl            # fill in namespace, bucket, region
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # the OCI Customer Secret Key pair
terraform init -backend-config=backend.hcl

# 1. Infrastructure: VCN, the A1 instance with k3s, Azure SQL with a firewall rule for the node only.
terraform apply -var compartment_ocid=... -var availability_domain=... \
  -var ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)" -var admin_cidr="$(curl -s ifconfig.me)/32"

# 2. Fetch the kubeconfig (the kubeconfig_hint output prints the command), then install the platform.
terraform apply ... -var kubeconfig_path=$PWD/kubeconfig-swiftbets
```

Optional: `-var anthropic_api_key=...` switches Steward from its scripted replay model to Claude (capped at USD 10 a
month by Steward itself).

## Continuous deployment

- Every service repo publishes multi-arch images tagged `sha-<commit>` and `main` on each merge, and `x.y.z` on release tags.
- `.github/workflows/deploy.yml` deploys a released version (`image_tag` must be `x.y.z`) to the `prod` GitHub
  environment, which requires a reviewer's approval. It runs on demand only.
- Store the cluster's kubeconfig as the `KUBECONFIG` secret on the `prod` environment. Until then the job exits
  cleanly with a notice.

## Secrets (D92)

Services read secrets only from environment variables. Generated infrastructure secrets (database passwords, the
identity signing key) are created by `terraform/envs/prod` and written to `swiftbets-secrets`. Third-party credentials
(payment provider, feed, model) live in `secrets/<env>.enc.yaml`, encrypted with SOPS to that environment's age key;
see `secrets/README.md`.
