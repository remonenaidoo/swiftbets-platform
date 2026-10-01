# Deploying SwiftBets

The same umbrella chart (`charts/swiftbets`) installs on any conformant cluster. Two value files cover the two shapes:

| | `values-local.yaml` | `values-cloud.yaml` |
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

## Cloud (OCI + Azure SQL)

Prerequisites: an OCI account (API key configured for the `oci` CLI/provider), an Azure subscription (`az login`), an
Object Storage bucket for state with a Customer Secret Key, and your SSH public key.

```bash
cd terraform/envs/cloud
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

- Every service repo publishes multi-arch images tagged `sha-<commit>` and `main` on each merge.
- `.github/workflows/deploy.yml` in this repo deploys to the `cloud` GitHub environment. The environment requires a
  reviewer's approval and only accepts `main`. It runs on platform merges that touch the charts, and on demand.
- Store the cluster's kubeconfig as the `KUBECONFIG` secret on the `cloud` environment. Until then the job exits
  cleanly with a notice.
