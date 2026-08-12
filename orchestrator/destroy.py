#!/usr/bin/env python3
"""Tear down everything create.py built, in reverse order.

Replaces destroy.ps1. Destroys Cloudflare LB (if built) -> Kasten K10 on
both clusters -> EKS+VPC -> AKS+storage. Run with the same
--subscription-id/--aws-region you used for create.py so variable state
matches.
"""

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

import cloud

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

INFRA = REPO_ROOT / "infra"
KUBECONFIG_DIR = REPO_ROOT / ".kubeconfigs"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--subscription-id",
        default=os.environ.get("AZURE_SUBSCRIPTION_ID"),
        required="AZURE_SUBSCRIPTION_ID" not in os.environ,
    )
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "ap-southeast-2"))
    parser.add_argument(
        "--skip-cloudflare",
        action="store_true",
        help="Set if infra/cloudflare was never applied",
    )
    args = parser.parse_args()

    if not args.skip_cloudflare:
        print("==> Destroying Cloudflare load balancer")
        cloud.terraform_destroy(str(INFRA / "cloudflare"))

    # The Profile/Secret/VolumeSnapshotClass k10_client.py creates directly
    # via the Kubernetes API (not Terraform - see infra/kasten-azure/main.tf)
    # aren't tracked here, but don't need to be: they get destroyed with the
    # cluster itself in the EKS/AKS teardown below.
    print("==> Uninstalling Kasten K10 from EKS")
    cloud.terraform_destroy(
        str(INFRA / "kasten-aws"),
        variables={"kube_config_path": str(KUBECONFIG_DIR / "eks.yaml")},
    )
    print("==> Uninstalling Kasten K10 from AKS")
    cloud.terraform_destroy(
        str(INFRA / "kasten-azure"),
        variables={"kube_config_path": str(KUBECONFIG_DIR / "aks.yaml")},
    )

    print("==> Destroying EKS + VPC")
    cloud.terraform_destroy(str(INFRA / "aws"), variables={"region": args.aws_region})

    print("==> Destroying AKS + storage account")
    cloud.terraform_destroy(
        str(INFRA / "azure"), variables={"subscription_id": args.subscription_id}
    )

    print("\nDone. Double check the Azure and AWS consoles for anything left behind.")


if __name__ == "__main__":
    sys.exit(main())
