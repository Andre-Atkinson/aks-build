#!/usr/bin/env python3
"""Provision the AKS + EKS Kasten K10 DR demo end to end.

Replaces create.ps1. Runs on macOS/Linux/Windows - no PowerShell, no Az
module. Requires: terraform, helm, kubectl, an authenticated `az` session
(`az login`) and AWS credentials (`aws configure` / SSO / env vars) available
to the SDKs used in cloud.py, and Python deps from requirements.txt.

This provisions real, billed cloud resources. Nothing here runs
automatically - you invoke it yourself, and destroy.py is the teardown path.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

from dotenv import load_dotenv

import cloud
from k10_client import K10Client

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

INFRA = REPO_ROOT / "infra"
KUBECONFIG_DIR = REPO_ROOT / ".kubeconfigs"

APP_NAMESPACE = "veeamon-tour"
K10_VERSION = "9.0.2"  # verify against `helm search repo kasten/k10` before relying on this


def helm(*args, kubeconfig: str):
    env = {**os.environ, "KUBECONFIG": kubeconfig}
    subprocess.run(["helm", *args], check=True, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--subscription-id",
        default=os.environ.get("AZURE_SUBSCRIPTION_ID"),
        required="AZURE_SUBSCRIPTION_ID" not in os.environ,
        help="Azure subscription ID (or set AZURE_SUBSCRIPTION_ID in .env)",
    )
    parser.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "ap-southeast-2"))
    parser.add_argument(
        "--image",
        default=os.environ.get("VEEAMON_IMAGE"),
        required="VEEAMON_IMAGE" not in os.environ,
        help="Registry path for the veeamon-tour frontend image (or set VEEAMON_IMAGE in .env)",
    )
    args = parser.parse_args()

    KUBECONFIG_DIR.mkdir(exist_ok=True)

    # --- Phase 1: infra -----------------------------------------------------
    print("==> Provisioning AKS + Azure Blob storage")
    cloud.terraform_apply(str(INFRA / "azure"), variables={"subscription_id": args.subscription_id})
    azure_out = cloud.terraform_output(str(INFRA / "azure"))

    print("==> Provisioning EKS + VPC")
    cloud.terraform_apply(str(INFRA / "aws"), variables={"region": args.aws_region})
    aws_out = cloud.terraform_output(str(INFRA / "aws"))

    aks_kubeconfig = cloud.write_aks_kubeconfig(
        args.subscription_id,
        azure_out["resource_group_name"],
        azure_out["kubernetes_cluster_name"],
        str(KUBECONFIG_DIR / "aks.yaml"),
    )
    eks_kubeconfig = cloud.write_eks_kubeconfig(
        args.aws_region, aws_out["cluster_name"], str(KUBECONFIG_DIR / "eks.yaml")
    )
    storage_key = cloud.get_storage_account_key(
        args.subscription_id, azure_out["resource_group_name"], azure_out["storage_account_name"]
    )

    # --- Phase 2: Kasten K10 on both clusters -------------------------------
    blob_vars = {
        "storage_account_name": azure_out["storage_account_name"],
        "storage_account_key": storage_key,
        "storage_container_name": azure_out["storage_container_name"],
        "k10_version": K10_VERSION,
    }

    print("==> Installing Kasten K10 on AKS")
    cloud.terraform_apply(
        str(INFRA / "kasten-azure"), variables={"kube_config_path": aks_kubeconfig, **blob_vars}
    )
    print("==> Installing Kasten K10 on EKS")
    cloud.terraform_apply(
        str(INFRA / "kasten-aws"), variables={"kube_config_path": eks_kubeconfig, **blob_vars}
    )

    # --- Phase 3: deploy the VeeamON Tour app onto AKS ----------------------
    print("==> Deploying VeeamON Tour app to AKS")
    chart_dir = str(REPO_ROOT / "app" / "veeamon-tour" / "chart")
    subprocess.run(["helm", "dependency", "update", chart_dir], check=True)
    image_repo, _, image_tag = args.image.partition(":")
    helm_args = [
        "upgrade", "--install", "veeamon-tour",
        chart_dir,
        "--namespace", APP_NAMESPACE, "--create-namespace",
        "--set", f"image.repository={image_repo}",
        "--set", f"image.tag={image_tag or 'latest'}",
    ]
    # Left unset, the Bitnami chart auto-generates these and stores them only
    # in the in-cluster Secret - these overrides are optional.
    if os.environ.get("MARIADB_ROOT_PASSWORD"):
        helm_args += ["--set", f"mariadb.auth.rootPassword={os.environ['MARIADB_ROOT_PASSWORD']}"]
    if os.environ.get("MARIADB_APP_PASSWORD"):
        helm_args += ["--set", f"mariadb.auth.password={os.environ['MARIADB_APP_PASSWORD']}"]
    helm(*helm_args, kubeconfig=aks_kubeconfig)

    # --- Phase 4: backup + export policy on AKS -----------------------------
    print("==> Creating backup/export policy on AKS and running it once")
    aks_k10 = K10Client(aks_kubeconfig)
    aks_k10.create_profile_azure_blob(
        "azureblob", azure_out["storage_account_name"], storage_key, azure_out["storage_container_name"]
    )
    aks_k10.create_backup_export_policy("veeamon-tour-backup", APP_NAMESPACE, "azureblob")
    action_name = aks_k10.run_action("backup", "veeamon-tour-backup")
    state = aks_k10.wait_for_actionset(action_name)
    print(f"    backup ActionSet {action_name}: {state}")

    # --- Phase 5: import + transform on EKS ---------------------------------
    print(
        "==> Phase 5 (import + transform on EKS) needs a manual step for now.\n"
        "    k10_client.create_import_policy / create_transform_set are stubbed out\n"
        "    pending confirmation of K10 9.x's exact CRD schema. In the K10\n"
        "    dashboard on AKS, open the veeamon-tour-backup policy's export\n"
        "    action and 'Show import details', then paste that into a new\n"
        "    Import Policy on the EKS dashboard against the azureblob profile,\n"
        "    with a transform rewriting storageClassName -> the EKS default\n"
        "    (gp3/csi-ebs-vsc). See docs.kasten.io/latest/usage/migration/."
    )

    print("\nDone. AKS kubeconfig: %s | EKS kubeconfig: %s" % (aks_kubeconfig, eks_kubeconfig))


if __name__ == "__main__":
    sys.exit(main())
