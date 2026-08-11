"""Thin Kasten K10 helper built on the official Kubernetes Python client.

K10's policies, profiles, and on-demand actions are all plain Kubernetes
custom resources - so "automating K10" here means calling the Kubernetes API
(via the `kubernetes` package's CustomObjectsApi), not the K10 dashboard's
internal REST API. That's deliberate: CRDs are K10's documented extension
point, the dashboard's HTTP API is not.

Two of these resources (ImportPolicy, TransformSet) are used exactly as
documented at https://docs.kasten.io/latest/usage/migration/, but this repo
has not yet been run against a live K10 9.x cluster to confirm the exact
CRD group/kind/field names - schemas have shifted across K10 major versions
before. Before relying on `create_import_policy` / `create_transform_set`,
run:

    kubectl api-resources --api-group=config.kio.kasten.io

against your actual cluster and adjust API_GROUP/KIND below if they differ.
"""

from __future__ import annotations

import time

from kubernetes import client, config as kube_config

API_GROUP = "config.kio.kasten.io"
API_VERSION = "v1alpha1"
ACTIONS_API_GROUP = "actions.kio.kasten.io"
ACTIONS_API_VERSION = "v1alpha1"
NAMESPACE = "kasten-io"


class K10Client:
    def __init__(self, kube_config_path: str):
        self.kube_config_path = kube_config_path
        api_client = kube_config.new_client_from_config(config_file=kube_config_path)
        self.custom = client.CustomObjectsApi(api_client)
        self.core = client.CoreV1Api(api_client)

    # -- generic CR helpers -------------------------------------------------

    def apply_namespaced(self, group: str, version: str, plural: str, namespace: str, body: dict):
        name = body["metadata"]["name"]
        try:
            self.custom.get_namespaced_custom_object(group, version, namespace, plural, name)
            return self.custom.patch_namespaced_custom_object(
                group, version, namespace, plural, name, body
            )
        except client.exceptions.ApiException as exc:
            if exc.status != 404:
                raise
            return self.custom.create_namespaced_custom_object(
                group, version, namespace, plural, body
            )

    def get_namespaced(self, group: str, version: str, plural: str, namespace: str, name: str):
        return self.custom.get_namespaced_custom_object(group, version, namespace, plural, name)

    # -- verified-against-source-repo resources ------------------------------

    def create_profile_azure_blob(
        self, name: str, storage_account: str, storage_key: str, container: str
    ):
        """Location Profile pointing at an Azure Blob container.

        Schema matches the working profile in the original create.ps1 /
        infra/kasten-azure, so this one is verified, not assumed.
        """
        secret_name = f"{name}-secret"
        secret_body = client.V1Secret(
            metadata=client.V1ObjectMeta(name=secret_name, namespace=NAMESPACE),
            type="secrets.kanister.io/azure",
            string_data={
                "azure_storage_account_id": storage_account,
                "azure_storage_environment": "AzurePublicCloud",
                "azure_storage_key": storage_key,
            },
        )
        try:
            self.core.create_namespaced_secret(NAMESPACE, secret_body)
        except client.exceptions.ApiException as exc:
            if exc.status != 409:
                raise

        profile = {
            "apiVersion": f"{API_GROUP}/{API_VERSION}",
            "kind": "Profile",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "type": "Location",
                "locationSpec": {
                    "type": "ObjectStore",
                    "objectStore": {"name": container, "objectStoreType": "AZ"},
                    "credential": {
                        "secretType": "AzStorageAccount",
                        "secret": {
                            "apiVersion": "v1",
                            "kind": "secret",
                            "name": secret_name,
                            "namespace": NAMESPACE,
                        },
                    },
                },
            },
        }
        return self.apply_namespaced(API_GROUP, API_VERSION, "profiles", NAMESPACE, profile)

    def create_backup_export_policy(
        self, name: str, app_namespace: str, profile_name: str, schedule: str = "@daily"
    ):
        """Policy with backup + export actions, per K10's migration docs."""
        policy = {
            "apiVersion": f"{API_GROUP}/{API_VERSION}",
            "kind": "Policy",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "frequency": schedule,
                "actions": [
                    {
                        "action": "backup",
                        "exportParameters": {
                            "frequency": schedule,
                            "profile": {"name": profile_name, "namespace": NAMESPACE},
                            "exportData": {"enabled": True},
                        },
                    }
                ],
                "selector": {
                    "matchExpressions": [
                        {
                            "key": "k10.kasten.io/appNamespace",
                            "operator": "In",
                            "values": [app_namespace],
                        }
                    ]
                },
            },
        }
        return self.apply_namespaced(API_GROUP, API_VERSION, "policies", NAMESPACE, policy)

    # -- on-demand actions ----------------------------------------------------

    def run_action(self, action: str, policy_name: str) -> str:
        """Create an ActionSet to trigger a policy's action immediately.

        Returns the created ActionSet's name for status polling.
        """
        action_set = {
            "apiVersion": f"{ACTIONS_API_GROUP}/{ACTIONS_API_VERSION}",
            "kind": "ActionSet",
            "metadata": {"generateName": f"{policy_name}-{action}-", "namespace": NAMESPACE},
            "spec": {
                "actions": [
                    {
                        "action": action,
                        "object": {
                            "apiVersion": f"{API_GROUP}/{API_VERSION}",
                            "kind": "Policy",
                            "name": policy_name,
                            "namespace": NAMESPACE,
                        },
                    }
                ]
            },
        }
        created = self.custom.create_namespaced_custom_object(
            ACTIONS_API_GROUP, ACTIONS_API_VERSION, NAMESPACE, "actionsets", action_set
        )
        return created["metadata"]["name"]

    def wait_for_actionset(self, name: str, timeout_seconds: int = 1800) -> str:
        """Poll an ActionSet's status.state until it leaves 'Running'."""
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            obj = self.get_namespaced(
                ACTIONS_API_GROUP, ACTIONS_API_VERSION, "actionsets", NAMESPACE, name
            )
            state = obj.get("status", {}).get("state")
            if state in ("Complete", "Failed"):
                return state
            time.sleep(10)
        raise TimeoutError(f"ActionSet {name} did not finish within {timeout_seconds}s")

    # -- cross-cluster import / transform (UNVERIFIED - see module docstring) -

    def create_transform_set(self, name: str, from_storage_class: str, to_storage_class: str):
        raise NotImplementedError(
            "Confirm TransformSet's real CRD group/kind via "
            "`kubectl api-resources --api-group=config.kio.kasten.io` on a live "
            "K10 9.x cluster before implementing this - see module docstring."
        )

    def create_import_policy(self, name: str, import_config: str, profile_name: str):
        raise NotImplementedError(
            "Confirm ImportPolicy's real CRD group/kind via "
            "`kubectl api-resources --api-group=config.kio.kasten.io` on a live "
            "K10 9.x cluster before implementing this - see module docstring."
        )

    def restore_from_imported_restore_point(self, restore_point_name: str) -> str:
        raise NotImplementedError(
            "Confirm the imported RestorePoint object's real CRD group/kind "
            "(varies by K10 version) before implementing this - trigger the "
            "restore from the EKS K10 dashboard's Import Policy view for now."
        )
