#!/usr/bin/env python3
"""Fix K10 dashboard login and mint fresh tokens on already-provisioned
AKS + EKS clusters, without re-running the rest of create.py.

Applies the auth.secureCookies=false Helm fix (see infra/kasten-azure/main.tf
and infra/kasten-aws/main.tf for why it's needed - K10 defaults to a Secure
session cookie, which browsers drop over the plain HTTP this demo's
dashboards are served on, bouncing a valid login back to the login screen),
then ensures the k10-dashboard-admin ServiceAccount/ClusterRoleBinding exist
and mints a fresh bearer token for each cluster.

Requires .kubeconfigs/aks.yaml and .kubeconfigs/eks.yaml to already exist
(written by create.py's Phase 1) and the kasten-azure/kasten-aws Terraform
state to already exist (written by create.py's Phase 2).
"""

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

import cloud
from k10_client import K10Client

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

INFRA = REPO_ROOT / "infra"
KUBECONFIG_DIR = REPO_ROOT / ".kubeconfigs"
K10_VERSION = "9.0.2"  # must match create.py's pin - a version mismatch here would trigger an unrelated chart upgrade


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--expose-dashboard",
        action="store_true",
        default=os.environ.get("EXPOSE_K10_DASHBOARD", "").lower() in ("1", "true", "yes"),
        help="Must match how create.py was originally run, or this Terraform apply "
        "will add/remove the gateway-ext LoadBalancer as a side effect.",
    )
    parser.add_argument("--duration-hours", type=int, default=24)
    args = parser.parse_args()

    aks_kubeconfig = str(KUBECONFIG_DIR / "aks.yaml")
    eks_kubeconfig = str(KUBECONFIG_DIR / "eks.yaml")
    for path in (aks_kubeconfig, eks_kubeconfig):
        if not Path(path).exists():
            print(f"Missing {path} - run create.py first.", file=sys.stderr)
            return 1

    print("==> Applying auth.secureCookies=false to K10 on AKS")
    cloud.terraform_apply(
        str(INFRA / "kasten-azure"),
        variables={
            "kube_config_path": aks_kubeconfig,
            "k10_version": K10_VERSION,
            "expose_dashboard": args.expose_dashboard,
        },
    )
    print("==> Applying auth.secureCookies=false to K10 on EKS")
    cloud.terraform_apply(
        str(INFRA / "kasten-aws"),
        variables={
            "kube_config_path": eks_kubeconfig,
            "k10_version": K10_VERSION,
            "expose_dashboard": args.expose_dashboard,
        },
    )

    print("==> Ensuring dashboard login ServiceAccount + ClusterRoleBinding on both clusters")
    aks_k10 = K10Client(aks_kubeconfig)
    eks_k10 = K10Client(eks_kubeconfig)
    aks_k10.ensure_dashboard_service_account()
    eks_k10.ensure_dashboard_service_account()

    print("==> Minting fresh dashboard tokens")
    aks_token = aks_k10.create_dashboard_token(duration_seconds=args.duration_hours * 3600)
    eks_token = eks_k10.create_dashboard_token(duration_seconds=args.duration_hours * 3600)

    aks_url = "http://localhost:8080/k10/ (kubectl --kubeconfig .kubeconfigs/aks.yaml port-forward -n kasten-io svc/gateway 8080:80)"
    eks_url = "http://localhost:8081/k10/ (kubectl --kubeconfig .kubeconfigs/eks.yaml port-forward -n kasten-io svc/gateway 8081:80)"
    if args.expose_dashboard:
        aks_url = f"http://{cloud.wait_for_loadbalancer_ip(aks_kubeconfig, 'kasten-io', 'gateway-ext')}/k10/"
        eks_url = f"http://{cloud.wait_for_loadbalancer_ip(eks_kubeconfig, 'kasten-io', 'gateway-ext')}/k10/"

    print(
        f"\n==> Dashboard login tokens (bearer tokens for ServiceAccount k10-dashboard-admin, "
        f"{args.duration_hours}h):\n"
        f"    AKS ({aks_url}): {aks_token}\n"
        f"    EKS ({eks_url}): {eks_token}\n"
        f"    Paste the token into the dashboard's login field - not the URL bar."
    )


if __name__ == "__main__":
    sys.exit(main())
