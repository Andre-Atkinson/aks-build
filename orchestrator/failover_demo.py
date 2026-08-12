#!/usr/bin/env python3
"""Simulate an AKS failure, then wait for a manual EKS restore to catch up.

Replaces corrupt.ps1. Captures the guestbook count on AKS, breaks AKS, and
prints the RestorePoint to restore - the actual Restore is triggered by hand
in the K10 dashboard on EKS (so it's visible on camera), not by this script.
Once you click Restore there, this script polls EKS until the app is back
with the same count.

Usage:
    python failover_demo.py --aks-url http://<aks-ip> --eks-url http://<eks-ip> \\
        [--mode outage|corrupt]
"""

import argparse
import base64
import sys
import time

import requests
from kubernetes import client, config as kube_config, stream

from k10_client import K10Client

APP_NAMESPACE = "veeamon-tour"


def get_count(base_url: str) -> int:
    resp = requests.get(f"{base_url}/api/count", timeout=10)
    resp.raise_for_status()
    return resp.json()["count"]


def simulate_outage(kubeconfig_path: str):
    print(f"==> Deleting namespace {APP_NAMESPACE} on AKS (simulated cluster failure)")
    kube_config.load_kube_config(config_file=kubeconfig_path)
    client.CoreV1Api().delete_namespace(APP_NAMESPACE)


def simulate_corruption(kubeconfig_path: str, release_name: str = "veeamon-tour"):
    """Drop the app database instead of destroying the whole namespace.

    Reads the root password from the <release>-mariadb Secret the chart's
    templates/mariadb-secret.yaml auto-generates - nothing is hardcoded here.
    """
    print("==> Dropping the MariaDB database on AKS (simulated data corruption)")
    kube_config.load_kube_config(config_file=kubeconfig_path)
    api = client.CoreV1Api()
    secret = api.read_namespaced_secret(f"{release_name}-mariadb", APP_NAMESPACE)
    root_password = base64.b64decode(secret.data["mariadb-root-password"]).decode()
    pod_name = f"{release_name}-mariadb-0"
    exec_command = ["mariadb", "-uroot", f"-p{root_password}", "-e", "DROP DATABASE veeamon_tour;"]
    stream.stream(
        api.connect_get_namespaced_pod_exec,
        pod_name,
        APP_NAMESPACE,
        command=exec_command,
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aks-kubeconfig", default=".kubeconfigs/aks.yaml")
    parser.add_argument("--eks-kubeconfig", default=".kubeconfigs/eks.yaml")
    parser.add_argument("--aks-url", required=True, help="http://<aks LoadBalancer IP>")
    parser.add_argument("--eks-url", required=True, help="http://<eks LoadBalancer IP>")
    parser.add_argument("--mode", choices=["outage", "corrupt"], default="outage")
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--transform-set-name", default="azure-to-ebs-storage-class")
    args = parser.parse_args()

    print("==> Capturing pre-failure guestbook count on AKS")
    baseline = get_count(args.aks_url)
    print(f"    baseline count: {baseline}")

    if args.mode == "outage":
        simulate_outage(args.aks_kubeconfig)
    else:
        simulate_corruption(args.aks_kubeconfig)

    eks_k10 = K10Client(args.eks_kubeconfig)
    latest = eks_k10.latest_restore_point()
    restore_point_name = latest["metadata"]["name"] if latest else "(none found yet)"

    print(
        f"\n==> AKS side is down. Over to you:\n"
        f"    In the K10 dashboard on EKS, restore RestorePoint '{restore_point_name}'\n"
        f"    with the '{args.transform_set_name}' transform applied.\n"
        f"    This script will keep polling {args.eks_url} until the app is back\n"
        f"    with the pre-failure count ({baseline}).\n"
    )

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            count = get_count(args.eks_url)
            if count == baseline:
                print(f"PASS: EKS serving veeamon-tour with matching count ({count})")
                return 0
            print(f"    EKS reachable but count={count} (want {baseline}), still waiting...")
        except requests.RequestException:
            print("    EKS not reachable yet, still waiting...")
        time.sleep(15)

    print(f"FAIL: EKS did not reach matching count ({baseline}) within {args.timeout}s")
    return 1


if __name__ == "__main__":
    sys.exit(main())
