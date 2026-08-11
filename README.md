# aks-build

Cross-cloud Kasten K10 disaster-recovery demo: AKS + EKS, a small custom
"VeeamON Tour" two-tier app, backup/export to Azure Blob, cross-cluster
import with a storage-class transform, a simulated AKS failure, and
failover to EKS. Optional Cloudflare DNS load balancing on top.

**This provisions real, billed Azure and AWS resources. Nothing runs
automatically - you invoke each script yourself, and `destroy.py` tears
everything down again. Review the Terraform plans before applying.**

Runs on macOS (or Linux/Windows) - no PowerShell, no `Az` module. Auth goes
through `az login` (Azure) and the standard AWS credential chain
(`aws configure` / SSO / env vars), not stored service-principal secrets.

## Prerequisites

- `terraform` >= 1.7
- `helm`, `kubectl`
- `az` CLI (logged in: `az login`) and `aws` CLI (configured: `aws configure`
  or SSO) - both are also required at runtime by the EKS kubeconfig's exec
  plugin and by DefaultAzureCredential's CLI fallback
- Python 3.11+, in a venv:
  ```bash
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r orchestrator/requirements.txt
  ```
- Docker, and a container registry you can push to (Docker Hub, ACR, ECR) for
  the `veeamon-tour` frontend image
- (Optional) a Cloudflare account with a zone, and `CLOUDFLARE_API_TOKEN` set

## Configuration: where secrets/config live

Copy `.env.example` to `.env` and fill it in - `.env` is gitignored, and
`orchestrator/create.py`/`destroy.py` load it automatically (via
python-dotenv). This is the **only** place config for this demo lives; there
is no secrets manager wired up, since the whole point is a cluster you spin
up, demo, and destroy in one sitting.

```bash
cp .env.example .env
```

What goes where:
- `AZURE_SUBSCRIPTION_ID`, `AWS_REGION`, `VEEAMON_IMAGE` - read by
  `create.py`/`destroy.py` as defaults for their `--subscription-id`,
  `--aws-region`, `--image` flags (CLI flags still override `.env` if you
  pass them).
- `MARIADB_ROOT_PASSWORD` / `MARIADB_APP_PASSWORD` - optional. Leave blank
  and the Bitnami MariaDB chart auto-generates random passwords, stored only
  in the in-cluster `veeamon-tour-mariadb` Secret - nothing is committed to
  `chart/values.yaml`. `failover_demo.py`'s `--mode=corrupt` reads the
  generated root password straight out of that Secret at runtime.
- `CLOUDFLARE_API_TOKEN`, `TF_VAR_zone_id`, `TF_VAR_hostname` - only needed
  if you apply `infra/cloudflare`. `TF_VAR_aks_ip`/`TF_VAR_eks_ip` aren't in
  `.env` because they don't exist until the app has a LoadBalancer IP on
  each cluster - export those right before running `terraform apply` there
  (see step 5 below).
- Azure/AWS auth itself is **not** in `.env` - it comes from your `az login`
  session and `~/.aws/credentials`/SSO, never from a file in this repo.

## Layout

```
infra/azure/         AKS cluster + Azure Storage account/container
infra/aws/           VPC + EKS cluster + EBS CSI driver addon
infra/kasten-azure/  Kasten K10 install on AKS + snapshot class + blob profile
infra/kasten-aws/    Kasten K10 install on EKS + snapshotter CRDs + blob profile
infra/cloudflare/    Optional: DNS load balancer failing over AKS -> EKS
app/veeamon-tour/    Flask frontend + MariaDB Helm chart (the demo app)
orchestrator/        Python scripts that sequence all of the above
```

## Run order

```bash
# 1. Build and push the app image
docker build -t <registry>/veeamon-tour:latest app/veeamon-tour/frontend
docker push <registry>/veeamon-tour:latest

# 2. Fill in .env (see above), then provision both clusters, install K10,
#    deploy the app, and take a backup
source .venv/bin/activate
python orchestrator/create.py
```

`create.py` runs the AKS backup+export and the EKS import+transform itself -
see "Cross-cluster import" below for what's actually verified there.

```bash
# 3. Get each cluster's app IP for the demo/failover step
kubectl --kubeconfig .kubeconfigs/aks.yaml -n veeamon-tour get svc veeamon-tour-veeamon-tour
kubectl --kubeconfig .kubeconfigs/eks.yaml -n veeamon-tour get svc veeamon-tour-veeamon-tour
```

```bash
# 4. Record the demo: simulate an AKS failure, confirm EKS takes over with
#    matching guestbook data
python orchestrator/failover_demo.py \
  --aks-url http://<aks-service-ip> \
  --eks-url http://<eks-service-ip>
```

```bash
# 5. (Optional) Cloudflare failover DNS - apply once you have both IPs
export TF_VAR_aks_ip=<aks-service-ip>
export TF_VAR_eks_ip=<eks-service-ip>
cd infra/cloudflare && terraform init && terraform apply
```

```bash
# 6. Tear everything down right after recording - see "Keep it short-lived"
python orchestrator/destroy.py
```

## Keep it short-lived

This is sized for "spin up, record a demo, spin down" - not a long-running
environment:

- Node pools default to burstable, small SKUs (`Standard_B2ms` on AKS,
  `t3.large` on EKS) at 2 nodes each - enough for K10 + the app + MariaDB,
  not tuned for anything beyond that.
- The AWS side still incurs a flat EKS control-plane charge
  (~US$0.10/hour) regardless of node size - that's an EKS floor cost, not
  something this build can shrink further.
- Destroy right after recording: run step 6 above (or at minimum
  `python orchestrator/destroy.py`) as soon as you're done. Nothing here
  auto-expires or auto-shuts-down.
- If you only want to check what would change before destroying,
  `terraform plan -destroy` in each `infra/*` directory shows it without
  applying.

## Advanced tuning

`.env` intentionally only holds the handful of values with no safe default
(subscription/account identity, image path, secret overrides). Everything
else - node size/count, Kubernetes version, Azure region/location, K10
chart version, whether the K10 dashboard gets a public LoadBalancer - has a
sensible default and lives in each module's own `variables.tf`
(`infra/azure`, `infra/aws`, `infra/kasten-azure`, `infra/kasten-aws`) or the
app's `chart/values.yaml`. To change one of those, either edit the
`default = ...` there, or override per-run with Terraform's own mechanism
(`-var`, or a gitignored `terraform.tfvars` in that directory) / `helm
--set`, rather than adding it to `.env`.

## Cross-cluster import: what's verified vs. still assumed

`orchestrator/k10_client.py` drives K10 entirely through its Kubernetes CRDs
(Policy, Profile, TransformSet, RunAction, RestoreAction) rather than the
dashboard's internal HTTP API. There is no `ImportPolicy` or generic
`ActionSet` kind (an earlier version of this file assumed both, incorrectly)
- cross-cluster import is `action: import` on the same `Policy` kind used
for backup/export, triggered on demand via `RunAction`.

This schema was verified against a real, locally-running K10 9.0.2 install
(`kubectl explain <kind> --recursive`, matched against
`kubectl api-resources`), and further confirmed by actually applying a
Policy + RunAction shaped exactly like the ones this code generates and
watching it reach `status.state: Failed` for the *expected* reason (a
Profile that doesn't exist) rather than a schema-validation error - i.e.
the structure is confirmed correct, not just plausible from reading docs.

What is **not** independently verified: a real cross-cluster export ->
import -> restore round trip with actual data, since that needs two real
clusters and object storage. In particular, the `receiveString` field
(a shared secret you generate and set identically in both the export and
import Policy, pairing them - see `create_backup_export_policy` /
`create_import_policy`) is a schema-and-reconciler-level inference, not a
confirmed end-to-end behavior. If the first real run's import doesn't pick
up the export, that pairing mechanism is the first thing to check - compare
against the K10 dashboard's own "Show import details" flow
(`kubectl port-forward -n kasten-io svc/gateway 8080:80` on either
cluster) to see what it generates.

## Notes

- Kasten K10 version is pinned in `orchestrator/create.py` (`K10_VERSION`) -
  check `helm search repo kasten/k10` for the current release before relying
  on the pin; it moves roughly monthly.
- The demo app's data model is a live check-in counter + guestbook
  (`app/veeamon-tour/frontend/app.py`), seeded with placeholder VeeamON Tour
  city stops - not the real tour schedule.
- `infra/cloudflare` is optional and independent of the rest - apply it once
  both clusters' app Services have external IPs.
