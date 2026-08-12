"""Cross-platform, SDK-first helpers for talking to Azure and AWS.

Deliberately avoids the PowerShell `Az` module the old create.ps1 depended
on. Azure auth goes through azure-identity's DefaultAzureCredential (works
with `az login`, env vars, or managed identity - no SP secrets committed to
disk). AWS auth goes through the standard boto3 credential chain
(`aws configure` / SSO / env vars).

One exception: EKS's IAM authentication scheme vends short-lived tokens via
a presigned STS request, which kubeconfig exec plugins normally generate by
shelling out to `aws eks get-token`. There's no pure-boto3 way around that
without re-implementing the AWS CLI's token command, so the EKS kubeconfig
written here still references the `aws` CLI as its exec plugin - everything
else (cluster lookup, kubeconfig generation) is direct SDK calls.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import boto3
from azure.identity import DefaultAzureCredential
from azure.mgmt.containerservice import ContainerServiceClient
from azure.mgmt.storage import StorageManagementClient


def terraform_output(directory: str) -> dict:
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=directory,
        capture_output=True,
        text=True,
        check=True,
    )
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


def _tf_env(variables: dict | None) -> dict:
    # TF_VAR_* env vars rather than `-var` flags, so secrets (e.g. storage
    # account keys) don't end up visible in `ps` output.
    env = {**os.environ}
    for key, value in (variables or {}).items():
        env[f"TF_VAR_{key}"] = str(value)
    return env


def terraform_apply(directory: str, variables: dict | None = None, auto_approve: bool = True) -> None:
    env = _tf_env(variables)
    subprocess.run(["terraform", "init"], cwd=directory, check=True, env=env)
    args = ["terraform", "apply"]
    if auto_approve:
        args.append("-auto-approve")
    subprocess.run(args, cwd=directory, check=True, env=env)


def terraform_destroy(directory: str, variables: dict | None = None, auto_approve: bool = True) -> None:
    env = _tf_env(variables)
    args = ["terraform", "destroy"]
    if auto_approve:
        args.append("-auto-approve")
    subprocess.run(args, cwd=directory, check=True, env=env)


def write_aks_kubeconfig(subscription_id: str, resource_group: str, cluster_name: str, out_path: str) -> str:
    credential = DefaultAzureCredential()
    client = ContainerServiceClient(credential, subscription_id)
    creds = client.managed_clusters.list_cluster_user_credentials(resource_group, cluster_name)
    # The SDK already returns the raw kubeconfig YAML as a bytearray, not
    # base64 text - no decoding needed (confirmed by inspecting the actual
    # returned value; it starts with "apiVersion: v1\nclusters:...").
    kubeconfig_bytes = bytes(creds.kubeconfigs[0].value)
    Path(out_path).write_bytes(kubeconfig_bytes)
    return out_path


def get_storage_account_key(subscription_id: str, resource_group: str, account_name: str) -> str:
    credential = DefaultAzureCredential()
    client = StorageManagementClient(credential, subscription_id)
    keys = client.storage_accounts.list_keys(resource_group, account_name)
    return keys.keys[0].value


def write_eks_kubeconfig(region: str, cluster_name: str, out_path: str) -> str:
    eks = boto3.client("eks", region_name=region)
    cluster = eks.describe_cluster(name=cluster_name)["cluster"]

    kubeconfig = {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [
            {
                "name": cluster_name,
                "cluster": {
                    "server": cluster["endpoint"],
                    "certificate-authority-data": cluster["certificateAuthority"]["data"],
                },
            }
        ],
        "contexts": [
            {"name": cluster_name, "context": {"cluster": cluster_name, "user": cluster_name}}
        ],
        "current-context": cluster_name,
        "users": [
            {
                "name": cluster_name,
                "user": {
                    "exec": {
                        "apiVersion": "client.authentication.k8s.io/v1beta1",
                        "command": "aws",
                        "args": ["eks", "get-token", "--cluster-name", cluster_name, "--region", region],
                    }
                },
            }
        ],
    }

    import yaml  # local import: only needed by this one function

    Path(out_path).write_text(yaml.safe_dump(kubeconfig))
    return out_path
