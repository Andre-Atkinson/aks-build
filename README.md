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

## If you're picking this up mid-session

Everything below describes the repo in general. If a live environment
already exists from an earlier run, check before re-running anything:

```bash
cd infra/azure && terraform output    # cluster/storage details, if it exists
cd ../aws && terraform output          # same for EKS
```

If both return real output (not "no state file"), clusters already exist -
`python orchestrator/create.py` is safe to run again regardless (every step
is idempotent: Terraform no-ops on unchanged infra, Helm upgrades in place,
K10 policies get patched not duplicated), but check the "Cross-cluster
import" section below before assuming the EKS import is done - that part is
always a manual dashboard step, run once per demo, not something
`create.py` repeats for you. When genuinely done with the environment, run
`python orchestrator/destroy.py` - don't leave it running.

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
- Docker with `buildx` (for cross-platform builds - see step 1 below), and a
  container registry you can push to (Docker Hub, ACR, ECR) for the
  `veeamon-tour` frontend image
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
- `EXPOSE_K10_DASHBOARD` - optional, defaults to false (see "Advanced
  tuning" below for the tradeoff). Set `true` to put a real LoadBalancer in
  front of each K10 dashboard instead of using `kubectl port-forward`.
- `MARIADB_ROOT_PASSWORD` / `MARIADB_APP_PASSWORD` - optional. Leave blank
  and the chart's `templates/mariadb-secret.yaml` auto-generates random
  passwords, stored only in the in-cluster `veeamon-tour-mariadb` Secret -
  nothing is committed to `chart/values.yaml`. `failover_demo.py`'s
  `--mode=corrupt` reads the generated root password straight out of that
  Secret at runtime.
- `CLOUDFLARE_API_TOKEN`, `TF_VAR_account_id`, `TF_VAR_zone_id`,
  `TF_VAR_hostname` - only needed if you apply `infra/cloudflare`.
  `TF_VAR_aks_ip`/`TF_VAR_eks_ip` aren't in `.env` because they don't exist
  until the app has a LoadBalancer IP on each cluster - export those right
  before running `terraform apply` there (see step 6 below).
- Azure/AWS auth itself is **not** in `.env` - it comes from your `az login`
  session and `~/.aws/credentials`/SSO, never from a file in this repo.

## Layout

```
infra/azure/         AKS cluster + Azure Storage account/container
infra/aws/           VPC + EKS cluster + EBS CSI driver addon
infra/kasten-azure/  Kasten K10 install on AKS + snapshot class
infra/kasten-aws/    Kasten K10 install on EKS + snapshotter CRDs + StorageClass
infra/cloudflare/    Optional: DNS load balancer failing over AKS -> EKS
app/veeamon-tour/    Flask frontend + self-authored MariaDB StatefulSet (the demo app)
orchestrator/        Python scripts that sequence all of the above
  cloud.py             Azure/AWS SDK helpers (kubeconfig writing, Terraform wrappers)
  k10_client.py        K10 CRD helpers (Policy/Profile/TransformSet/RunAction/RestoreAction)
  create.py            Provisions everything, deploys the app, runs the AKS backup+export
  failover_demo.py     Simulates an AKS failure, waits for your manual EKS restore
  destroy.py           Tears down everything create.py built, in reverse order
```

## Run order

```bash
# 1. Build and push the app image - use --platform even on Apple Silicon,
#    AKS/EKS nodes are x86_64 and a plain `docker build` here produces an
#    arm64 image that fails with "exec format error" on the cluster (hit on
#    a real run)
docker buildx build --platform linux/amd64 -t <registry>/veeamon-tour:latest \
  --push app/veeamon-tour/frontend
```

```bash
# 2. Fill in .env (see above), then provision both clusters, install K10,
#    deploy the app, and take a backup
source .venv/bin/activate
python orchestrator/create.py
```

`create.py` runs the AKS backup+export itself (verified working against a
real cluster) and creates the EKS-side storage-class transform, then prints
the exact manual step needed next - see "Cross-cluster import" below for
exactly why that step can't be automated, and what URLs to use (real
LoadBalancer IPs if `EXPOSE_K10_DASHBOARD=true`, otherwise port-forward
commands - `create.py` prints whichever applies).

```bash
# 3. Manual: set up the EKS import (K10 dashboards, URLs from create.py's output)
#    1. On AKS: open the veeamon-tour-backup policy's export action, "Show import details"
#    2. On EKS: create an Import Policy against the "azureblob" profile, paste that in,
#       apply the "azure-to-ebs-storage-class" transform, run it once
```

```bash
# 4. Get each cluster's app IP for the demo/failover step
kubectl --kubeconfig .kubeconfigs/aks.yaml -n veeamon-tour get svc veeamon-tour-veeamon-tour
kubectl --kubeconfig .kubeconfigs/eks.yaml -n veeamon-tour get svc veeamon-tour-veeamon-tour
```

```bash
# 5. Record the demo: simulate an AKS failure, then click Restore in the
#    EKS K10 dashboard yourself (on camera) - this script captures the
#    baseline count, breaks AKS, tells you what to restore, and polls
#    until EKS matches
python orchestrator/failover_demo.py \
  --aks-url http://<aks-service-ip> \
  --eks-url http://<eks-service-ip>
```

```bash
# 6. (Optional) Cloudflare failover DNS - apply once you have both IPs
export TF_VAR_aks_ip=<aks-service-ip>
export TF_VAR_eks_ip=<eks-service-ip>
cd infra/cloudflare && terraform init && terraform apply
```

```bash
# 7. Tear everything down right after recording - see "Keep it short-lived"
python orchestrator/destroy.py
```

## Keep it short-lived

This is sized for "spin up, record a demo, spin down" - not a long-running
environment:

- Node pools default to burstable, small SKUs (`Standard_B2ms` on AKS,
  `t3.large` on EKS) at 2 nodes each - enough for K10 + the app + MariaDB,
  not tuned for anything beyond that.
- Destroy right after recording: run step 7 above (or at minimum
  `python orchestrator/destroy.py`) as soon as you're done. Nothing here
  auto-expires or auto-shuts-down.
- If you only want to check what would change before destroying,
  `terraform plan -destroy` in each `infra/*` directory shows it without
  applying.

### Exactly what gets created, and roughly what it costs

Every billable resource `create.py` provisions (plus the ones that don't
cost anything, for completeness). USD, `ap-southeast-2` / `Australia East`
list pricing as of this writing - **not** pulled from a live pricing API,
so treat these as rough, and check the
[Azure](https://azure.microsoft.com/en-us/pricing/calculator/) /
[AWS](https://calculator.aws/) pricing calculators for anything precise.
Prices also drift over time and by region.

**Azure** (`infra/azure`, `infra/kasten-azure`)

| Resource | Purpose | Approx. cost while running |
|---|---|---|
| AKS cluster control plane | Kubernetes API/control plane | $0/hr (Free tier - default, no SLA) |
| 2x `Standard_B2ms` nodes | AKS worker nodes | ~$0.08-0.10/hr each, ~$0.16-0.20/hr total |
| Storage account + blob container (Standard LRS) | Shared K10 export/import location | ~$0.01/hr or less at this scale |
| MariaDB PVC (1Gi Azure Disk) | App database volume | <$0.01/hr |
| Resource group, K10 Helm release, Policies/Profiles/StorageClasses | Container/config objects | $0 - no direct cost |
| `gateway-ext` Standard Load Balancer (only if `EXPOSE_K10_DASHBOARD=true`) | Public access to the K10 dashboard | ~$0.025/hr |

**AWS** (`infra/aws`, `infra/kasten-aws`)

| Resource | Purpose | Approx. cost while running |
|---|---|---|
| EKS cluster control plane | Kubernetes API/control plane | $0.10/hr flat (fixed, not reducible) |
| 2x `t3.large` nodes | EKS worker nodes | ~$0.08-0.10/hr each, ~$0.16-0.20/hr total |
| 1x NAT Gateway | Outbound internet for private subnets | ~$0.045/hr + data processing (negligible for this workload) |
| EBS root volumes (2x ~20GB gp3) | Node OS disks | ~$0.005/hr |
| MariaDB PVC (1Gi EBS, after restore) | App database volume, post-failover | <$0.01/hr |
| VPC/subnets/route tables, IAM role, EKS addons, K10 Helm release, snapshot-controller, Policies/Profiles/StorageClasses | Networking/config objects | $0 - no direct cost |
| `gateway-ext` Classic Load Balancer (only if `EXPOSE_K10_DASHBOARD=true`) | Public access to the K10 dashboard | ~$0.025/hr + negligible data transfer |

**Rough total while both clusters are up: ~$0.45-0.60/hr combined**, or
~$0.50-0.65/hr with both dashboard LoadBalancers enabled.

**Not included above:** `infra/cloudflare` needs Cloudflare's **Load
Balancing add-on - $5/month recurring**, not a per-hour cost like everything
else here, and not prorated down when you tear the rest of this down (2
endpoints included, 500K free queries/month, $0.50/500K after that). It's
cosmetic on top of the actual DR story (`failover_demo.py` already proves
the backup/restore mechanics by hitting AKS/EKS IPs directly) - skip it
unless you specifically want a single DNS name that flips automatically for
the recording. It's also not part of the default `create.py` run either
way.

## Advanced tuning

`.env` holds the values with no safe default (subscription/account
identity, image path, secret overrides) plus a couple of behavioral toggles
for `create.py` itself (`EXPOSE_K10_DASHBOARD`) that don't belong in
Terraform defaults because they're about how *you* want to interact with a
given run, not the infrastructure's shape. Everything else - node
size/count, Kubernetes version, Azure region/location, K10 chart version -
has a sensible default and lives in each module's own `variables.tf`
(`infra/azure`, `infra/aws`, `infra/kasten-azure`, `infra/kasten-aws`) or the
app's `chart/values.yaml`. To change one of those, either edit the
`default = ...` there, or override per-run with Terraform's own mechanism
(`-var`, or a gitignored `terraform.tfvars` in that directory) / `helm
--set`, rather than adding it to `.env`.

**Why `EXPOSE_K10_DASHBOARD` defaults to false:** a `LoadBalancer` Service
puts K10's login page on the public internet; port-forward tunnels through
the Kubernetes API server instead, gated by whoever already has your
kubeconfig. For a cluster that only exists for a few hours and only you need
to reach, port-forward is the safer default. The real cost either way is
small (~$0.05/hr combined for both dashboards, see the cost table above) -
set it true if you're doing an extended interactive session across both
dashboards and don't want a foreground `kubectl port-forward` process to be
a single point of failure mid-recording.

## Cross-cluster import: what's automated vs. manual

`orchestrator/k10_client.py` drives K10 through its Kubernetes CRDs
(Policy, Profile, TransformSet, RunAction, RestoreAction) rather than the
dashboard's internal HTTP API. There is no `ImportPolicy` or generic
`ActionSet` kind - cross-cluster import is `action: import` on the same
`Policy` kind used for backup/export, triggered via `RunAction`. This
schema, and the AKS-side backup+export flow specifically, are verified
against real clusters end-to-end, not just plausible from reading docs -
`create.py`'s backup+export policy has actually completed successfully.

**The EKS-side import setup is a manual step, confirmed necessary, not just
unverified.** The `receiveString` field looked from the schema alone like a
shared passphrase you could generate yourself and set identically on both
sides. It isn't: supplying an arbitrary string on the import side fails
with `cipher: message authentication failed` - it's a cryptographic
envelope K10 generates on the export side, and the auto-created
`<policy>-<hash>-migration-token` Secret on the export cluster turns out to
be a different thing (a per-export data-encryption key, not the
cross-cluster pairing token). There's no CRD field or API call found that
produces the real value independently of the dashboard's "Show import
details" action on the export policy - so that one step has to be done by
hand. Once the Import Policy exists with the real value, the transform and
restore steps work exactly as described above.

## Notes

- Kasten K10 version is pinned in `orchestrator/create.py` (`K10_VERSION`) -
  check `helm search repo kasten/k10` for the current release before relying
  on the pin; it moves roughly monthly. Same for AKS/EKS Kubernetes versions
  in `infra/azure`/`infra/aws`'s `variables.tf` - both clouds retire standard
  support for old minor versions on their own schedule (hit on a real run:
  the pinned AKS version had aged into LTS-only within months of being set).
- The demo app's data model is a live check-in counter + guestbook
  (`app/veeamon-tour/frontend/app.py`), seeded with placeholder VeeamON Tour
  city stops - not the real tour schedule. The database is a self-authored
  MariaDB StatefulSet on the official `mariadb` image
  (`app/veeamon-tour/chart/templates/mariadb-*.yaml`), not a Bitnami chart
  dependency - Bitnami prunes old image tags on a schedule outside this
  repo's control, which broke the original Bitnami-based build.
- `infra/cloudflare` is optional and independent of the rest - apply it once
  both clusters' app Services have external IPs.
