# aks-build

Cross-cloud Kasten K10 disaster-recovery demo. Provisions an AKS cluster and
an EKS cluster, installs Kasten K10 on both, deploys a small two-tier demo
app ("VeeamON Tour") to AKS, backs it up to Azure Blob, imports that backup
into EKS with a storage-class transform, then simulates an AKS failure and
walks through restoring onto EKS. An optional Cloudflare DNS load balancer
can sit on top for a single URL that fails over automatically.

> **This provisions real, billed Azure and AWS resources.** Nothing runs on
> a schedule — you invoke each script yourself, and `destroy.py` tears
> everything down again. Review the Terraform plans before applying, and
> destroy promptly after a demo (see [Cost](#cost) and
> [Lifecycle](#lifecycle)).

Runs on macOS/Linux/Windows via Python + Terraform + Helm — no PowerShell,
no `Az` module. Cloud auth comes from your `az login` session and the
standard AWS credential chain (`aws configure` / SSO / env vars); no
credentials are stored in this repo.

## Contents

- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [Configuration reference](#configuration-reference)
- [Accessing the K10 dashboards](#accessing-the-k10-dashboards)
- [Cross-cluster import](#cross-cluster-import)
- [Cost](#cost)
- [Lifecycle](#lifecycle)
- [Design notes](#design-notes)

## Prerequisites

- `terraform` >= 1.7, `helm`, `kubectl`
- `az` CLI, logged in (`az login`)
- `aws` CLI, configured (`aws configure` or SSO) — also required at runtime
  by the EKS kubeconfig's exec plugin
- Python 3.11+
- Docker with `buildx`, and a container registry you can push to (Docker
  Hub, ACR, ECR) for the demo app's image
- Optional: a Cloudflare account with a zone, if you want the DNS-failover
  add-on

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r orchestrator/requirements.txt

cp .env.example .env   # fill in AZURE_SUBSCRIPTION_ID, AWS_REGION, VEEAMON_IMAGE
```

`.env` is the only place config lives for this demo — gitignored, loaded
automatically by every `orchestrator/*.py` script. See
[Configuration reference](#configuration-reference) for every field.

## Quick start

```bash
# 1. Build and push the demo app image. --platform matters even on Apple
#    Silicon: AKS/EKS nodes are x86_64, and a plain `docker build` here
#    produces an arm64 image that fails with "exec format error" on the
#    cluster.
docker buildx build --platform linux/amd64 -t <registry>/veeamon-tour:latest \
  --push app/veeamon-tour/frontend

# 2. Provision both clusters, install K10, deploy the app, and run a backup.
#    Every step is idempotent - safe to re-run.
python orchestrator/create.py
```

`create.py` finishes by printing everything you need: K10 dashboard URLs
and login tokens for both clusters, the demo app's URL, and the two
kubeconfig paths. It also prints the one manual step needed next — see
[Cross-cluster import](#cross-cluster-import) — because that step genuinely
can't be automated (K10 requires it to happen through the dashboard).

```bash
# 3. Manual: set up the EKS import (see "Cross-cluster import" below)

# 4. Record the demo: simulate an AKS failure, then click Restore in the
#    EKS K10 dashboard yourself (on camera). This script captures the
#    baseline count, breaks AKS, tells you what to restore, and polls until
#    EKS matches.
python orchestrator/failover_demo.py \
  --aks-url http://<aks-app-ip> --eks-url http://<eks-app-ip>

# 5. (Optional) Cloudflare failover DNS - apply once you have both app IPs
export TF_VAR_aks_ip=<aks-app-ip>
export TF_VAR_eks_ip=<eks-app-ip>
cd infra/cloudflare && terraform init && terraform apply && cd ../..

# 6. Tear everything down right after recording.
python orchestrator/destroy.py
```

`--aks-app-ip` / `--eks-app-ip` are the demo app's own LoadBalancer IPs
(printed by `create.py`, or re-fetch with `kubectl get svc
veeamon-tour-veeamon-tour -n veeamon-tour`) — not the K10 dashboard IPs.

## Repository layout

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
  dashboard_tokens.py  Re-applies the K10 login fix / mints fresh tokens without a full re-run
  failover_demo.py     Simulates an AKS failure, waits for your manual EKS restore
  destroy.py           Tears down everything create.py built, in reverse order
```

## Configuration reference

Everything in `.env` (copy from `.env.example`):

| Variable | Required | Purpose |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | Yes | Default for `create.py`/`destroy.py --subscription-id` |
| `AWS_REGION` | Yes | Default for `--aws-region` (default `ap-southeast-2`) |
| `VEEAMON_IMAGE` | Yes | Registry path for the image built in step 1 |
| `EXPOSE_K10_DASHBOARD` | No | `true` puts a real LoadBalancer in front of each K10 dashboard instead of `kubectl port-forward`. Defaults `false` — see [Design notes](#design-notes) for the tradeoff. |
| `MARIADB_ROOT_PASSWORD` / `MARIADB_APP_PASSWORD` | No | Leave blank to auto-generate (stored only in the in-cluster `veeamon-tour-mariadb` Secret, never written to disk) |
| `CLOUDFLARE_API_TOKEN`, `TF_VAR_account_id`, `TF_VAR_zone_id`, `TF_VAR_hostname` | Only for `infra/cloudflare` | DNS failover add-on config |

Not in `.env`:
- Azure/AWS credentials — come from `az login` and your AWS credential
  chain, never from a file in this repo.
- `TF_VAR_aks_ip` / `TF_VAR_eks_ip` — the demo app doesn't have a
  LoadBalancer IP until after `create.py` runs, so export these by hand
  right before applying `infra/cloudflare` (step 5 in
  [Quick start](#quick-start)).
- Node size/count, Kubernetes version, Azure region, K10 chart version —
  each has a sensible default in its own module's `variables.tf`
  (`infra/azure`, `infra/aws`, `infra/kasten-azure`, `infra/kasten-aws`) or
  the app's `chart/values.yaml`. Override with Terraform's `-var` / a
  gitignored `terraform.tfvars`, or Helm's `--set`, rather than adding a new
  `.env` field — these describe the infrastructure's shape, not how you
  personally want to interact with a given run.

## Accessing the K10 dashboards

K10's `auth.tokenAuth.enabled=true` (set in both `infra/kasten-azure` and
`infra/kasten-aws`) means the dashboard accepts a Kubernetes ServiceAccount
bearer token and delegates to normal RBAC — no separate K10 credential
exists. `create.py` creates that ServiceAccount (`k10-dashboard-admin`,
bound to `cluster-admin`) and mints a 24h token on both clusters
automatically, printing both at the end of the run.

Tokens expire after 24h. To get fresh ones without re-running the whole
provisioning flow:

```bash
python orchestrator/dashboard_tokens.py --expose-dashboard  # omit the flag if you're using port-forward
```

Paste the token into the dashboard's login field — not the URL bar.

## Cross-cluster import

`orchestrator/k10_client.py` drives K10 through its Kubernetes CRDs
(`Policy`, `Profile`, `TransformSet`, `RunAction`, `RestoreAction`), not the
dashboard's internal HTTP API. `create.py` automates everything up to the
point of import — the AKS backup+export policy, running it, and the EKS
storage-class transform — then stops, because K10's cross-cluster pairing
value (`receiveString`) is a cryptographic envelope generated on the export
side with no CRD field or API call that exposes it independently. It's
only available via the dashboard's **"Show import details"** action, so
that one step has to be done by hand:

1. On the **AKS** dashboard: open the `veeamon-tour-backup` policy's export
   action, click **Show import details**.
2. On the **EKS** dashboard: create an Import Policy against the
   `azureblob` profile, paste that import configuration in, apply the
   `azure-to-ebs-storage-class` transform, and run it once.

Once the Import Policy exists with the real value, everything else — the
transform, the restore, `failover_demo.py`'s polling — works as described
in [Quick start](#quick-start).

## Cost

USD, `ap-southeast-2` / `Australia East` list pricing as of this writing —
**not** pulled from a live pricing API, so treat these as rough. Check the
[Azure](https://azure.microsoft.com/en-us/pricing/calculator/) /
[AWS](https://calculator.aws/) calculators for anything precise; prices
drift by region and over time.

**Azure** (`infra/azure`, `infra/kasten-azure`)

| Resource | Approx. cost while running |
|---|---|
| AKS control plane | $0/hr (Free tier) |
| 2x `Standard_B2ms` nodes | ~$0.16–0.20/hr |
| Storage account + blob container | ~$0.01/hr or less |
| MariaDB PVC (1Gi Azure Disk) | <$0.01/hr |
| `gateway-ext` LoadBalancer (only if `EXPOSE_K10_DASHBOARD=true`) | ~$0.025/hr |
| Resource group, K10 release, Policies/Profiles/StorageClasses | $0 |

**AWS** (`infra/aws`, `infra/kasten-aws`)

| Resource | Approx. cost while running |
|---|---|
| EKS control plane | $0.10/hr flat |
| 2x `t3.large` nodes | ~$0.16–0.20/hr |
| 1x NAT Gateway | ~$0.045/hr + negligible data processing |
| EBS root volumes (2x ~20GB gp3) | ~$0.005/hr |
| MariaDB PVC (1Gi EBS, post-restore) | <$0.01/hr |
| `gateway-ext` LoadBalancer (only if `EXPOSE_K10_DASHBOARD=true`) | ~$0.025/hr + negligible data transfer |
| VPC, IAM, EKS addons, K10 release, snapshot-controller, Policies/Profiles/StorageClasses | $0 |

**Rough total while both clusters are up: ~$0.45–0.60/hr**, or
~$0.50–0.65/hr with both dashboard LoadBalancers enabled.

**Not included above:** `infra/cloudflare` needs Cloudflare's **Load
Balancing add-on — $5/month recurring**, not per-hour, and not prorated
down when you tear the rest of this down (2 endpoints included, 500K free
queries/month, $0.50/500K after). It's cosmetic on top of the actual DR
story — `failover_demo.py` already proves the backup/restore mechanics by
hitting AKS/EKS IPs directly — so skip it unless you specifically want one
DNS name that flips automatically for the recording. It's not part of the
default `create.py` run either way.

## Lifecycle

This is sized for "spin up, record a demo, spin down," not a long-running
environment — nothing here auto-expires.

- Node pools default to small, burstable SKUs (2 nodes each) — enough for
  K10 + the app + MariaDB, not tuned beyond that.
- Destroy right after recording: `python orchestrator/destroy.py`.
- To preview a teardown without applying it, run `terraform plan -destroy`
  in any `infra/*` directory.
- `destroy.py --skip-cloudflare` if `infra/cloudflare` was never applied
  (otherwise it'll try to destroy a module with no state, harmlessly, but
  it's an extra `terraform init` for nothing).
- After destroying, `.kubeconfigs/*.yaml` and every `infra/*/terraform.tfstate*`
  are stale/empty — safe to delete; `create.py` regenerates them from
  scratch on the next run.

Not sure whether an environment from an earlier run is still up? Check for
live Terraform state before running anything:

```bash
cd infra/azure && terraform output    # cluster/storage details, if state exists
cd ../aws && terraform output          # same for EKS
```

If both return real output, the clusters already exist — `create.py` is
safe to run again regardless, since every step is idempotent (Terraform
no-ops on unchanged infra, Helm upgrades in place, K10 policies get patched
not duplicated). The one exception is
[cross-cluster import](#cross-cluster-import): that's always a manual
dashboard step, so re-running `create.py` won't tell you whether it's
already been done.

## Design notes

Decisions and bugs worth knowing about if you're modifying this repo:

- **K10 dashboard login was silently broken over plain HTTP.** K10 defaults
  `auth.secureCookies` to `true`, marking its session cookie `Secure`.
  Nothing here terminates TLS in front of K10 (port-forward and the
  optional `gateway-ext` LoadBalancer are both plain HTTP), so browsers
  dropped that cookie right after a successful login and bounced back to
  the sign-in screen — even though the bearer token itself authenticated
  fine (confirmed via a raw `TokenReview` and direct API calls). Both
  `infra/kasten-azure/main.tf` and `infra/kasten-aws/main.tf` now set
  `auth.secureCookies=false`; confirmed end to end in a real browser
  (login persists across a full page reload) on both clusters.
- **`receiveString` is not a shared passphrase.** It looked from the K10
  CRD schema like something you could generate yourself and set
  identically on both sides. It isn't — an arbitrary string on the import
  side fails with `cipher: message authentication failed`. It's a
  cryptographic envelope K10 generates on the export side; the
  auto-created `<policy>-<hash>-migration-token` Secret is a different
  thing (a per-export data-encryption key, not the pairing token). There's
  no CRD field or API call that exposes the real value outside the
  dashboard's "Show import details" action, which is why that step is
  manual — see [Cross-cluster import](#cross-cluster-import).
- **Why `EXPOSE_K10_DASHBOARD` defaults to `false`.** A `LoadBalancer`
  Service puts K10's login page on the public internet; port-forward
  tunnels through the Kubernetes API server, gated by whoever already has
  your kubeconfig. For a cluster that exists for a few hours and only you
  need to reach, port-forward is the safer default. Set it `true` if you
  want both dashboards reachable without a foreground `kubectl
  port-forward` process being a single point of failure mid-recording.
- **EKS doesn't ship snapshot CRDs/CSI defaults the way AKS does** —
  `infra/aws` installs the `piraeus.io` `snapshot-controller` chart and
  sets a default `ebs-gp3` StorageClass explicitly; AKS gets both for free.
- **Terraform's `kubernetes_manifest` validates CRD schemas at plan time**,
  before anything in the *same* apply has run — so the K10 `Profile`/
  `VolumeSnapshotClass` objects that depend on CRDs the same apply installs
  can't go through that resource type. They're created directly via the
  Kubernetes Python client in `orchestrator/k10_client.py` instead.
- **The demo app's MariaDB is a self-authored StatefulSet**, not a Bitnami
  chart dependency — Bitnami prunes old image tags on a schedule outside
  this repo's control, which broke an earlier build.
- **Image pull policy is `Always`**, not `IfNotPresent` — this project
  rebuilds and pushes the same `:latest` tag repeatedly with no immutable
  digest, and a node that already cached an older `:latest` never re-pulled
  after a newer image was pushed (in one case, the wrong architecture).
- **Version pins age out.** Kasten K10's version is pinned in
  `orchestrator/create.py` (`K10_VERSION`) and moves roughly monthly — check
  `helm search repo kasten/k10` before relying on it. Same for the AKS/EKS
  Kubernetes version pins in `infra/azure`/`infra/aws`'s `variables.tf`;
  both clouds retire standard support for old minor versions on their own
  schedule.
- The demo app's data model is a live check-in counter + guestbook
  (`app/veeamon-tour/frontend/app.py`), seeded with placeholder city stops
  — not a real tour schedule.
