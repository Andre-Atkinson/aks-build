#!/usr/bin/env python3
"""Simulate an AKS failure and fail the VeeamON Tour app over to EKS.

Replaces corrupt.ps1. Captures the guestbook count on AKS, breaks AKS, then
(once the EKS-side import/restore step is triggered - see the printed
instructions) polls EKS until the app is back with the same count.

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

    Reads the root password from the <release>-mariadb Secret the Bitnami
    chart auto-generates - nothing is hardcoded here.
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
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    print("==> Capturing pre-failure guestbook count on AKS")
    baseline = get_count(args.aks_url)
    print(f"    baseline count: {baseline}")

    if args.mode == "outage":
        simulate_outage(args.aks_kubeconfig)
    else:
        simulate_corruption(args.aks_kubeconfig)

    print(
        "\n==> AKS side is down. Now trigger the failover on EKS:\n"
        "    In the EKS K10 dashboard, open the imported veeamon-tour-backup\n"
        "    restore points and click Restore on the latest one (with the\n"
        "    storage-class transform applied). k10_client.py's\n"
        "    restore_from_imported_restore_point() is stubbed pending CRD\n"
        "    schema confirmation - see that file's docstring.\n"
        "    This script will now poll EKS until the app is back.\n"
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
