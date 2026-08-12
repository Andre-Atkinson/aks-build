"""Thin Kasten K10 helper built on the official Kubernetes Python client.

K10's policies, profiles, and actions are all plain Kubernetes custom
resources - so "automating K10" here means calling the Kubernetes API (via
the `kubernetes` package's CustomObjectsApi), not the K10 dashboard's
internal HTTP API. CRDs are K10's documented extension point; the
dashboard's HTTP API is not.

Verified against a real K10 9.0.2 install, not just plausible from docs:
- The AKS-side backup+export flow (create_backup_export_policy + run_policy)
  has actually completed successfully end to end on a live cluster.
- There is no `ImportPolicy` or generic `ActionSet` kind. Cross-cluster
  import is `action: import` on the same `Policy` kind used for backup/
  export (config.kio.kasten.io/v1alpha1), with `importParameters`. On-demand
  triggering of any Policy is a `RunAction` (actions.kio.kasten.io/v1alpha1)
  referencing the Policy via `spec.subject`.
- `TransformSet` does exist as assumed (config.kio.kasten.io/v1alpha1).
- A one-off restore from an imported restore point is a standalone
  `RestoreAction` (actions.kio.kasten.io/v1alpha1) whose `spec.subject`
  references the `RestorePoint` object (apps.kio.kasten.io/v1alpha1) by
  name, with `spec.transforms[].transformSetRef` applying the TransformSet.
- `receiveString` (create_backup_export_policy / create_import_policy) is
  NOT a shared passphrase you can generate yourself - confirmed on a real
  run: an arbitrary string on the import side fails with "cipher: message
  authentication failed". It's a cryptographic envelope K10 generates on
  the export side, obtainable only via the dashboard's "Show import
  details" action - see create.py's Phase 4/5 and the README's
  "Cross-cluster import" section for the manual step this requires.
"""

from __future__ import annotations

import time

from kubernetes import client, config as kube_config

CONFIG_GROUP = "config.kio.kasten.io"
CONFIG_VERSION = "v1alpha1"
ACTIONS_GROUP = "actions.kio.kasten.io"
ACTIONS_VERSION = "v1alpha1"
APPS_GROUP = "apps.kio.kasten.io"
APPS_VERSION = "v1alpha1"
NAMESPACE = "kasten-io"


class K10Client:
    def __init__(self, kube_config_path: str):
        api_client = kube_config.new_client_from_config(config_file=kube_config_path)
        self.custom = client.CustomObjectsApi(api_client)
        self.core = client.CoreV1Api(api_client)
        self.rbac = client.RbacAuthorizationV1Api(api_client)

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

    def apply_cluster_scoped(self, group: str, version: str, plural: str, body: dict):
        name = body["metadata"]["name"]
        try:
            self.custom.get_cluster_custom_object(group, version, plural, name)
            return self.custom.patch_cluster_custom_object(group, version, plural, name, body)
        except client.exceptions.ApiException as exc:
            if exc.status != 404:
                raise
            return self.custom.create_cluster_custom_object(group, version, plural, body)

    # -- dashboard login -------------------------------------------------------

    def ensure_dashboard_service_account(self, name: str = "k10-dashboard-admin", namespace: str = NAMESPACE):
        """ServiceAccount + ClusterRoleBinding the K10 dashboard's token-auth
        login accepts (auth.tokenAuth.enabled delegates to normal RBAC via
        TokenReview - any authenticated ServiceAccount works, cluster-admin
        is what the README's manual version used). Idempotent: safe to call
        on every provisioning run.
        """
        try:
            self.core.create_namespaced_service_account(
                namespace, client.V1ServiceAccount(metadata=client.V1ObjectMeta(name=name))
            )
        except client.exceptions.ApiException as exc:
            if exc.status != 409:
                raise
        try:
            self.rbac.create_cluster_role_binding(
                client.V1ClusterRoleBinding(
                    metadata=client.V1ObjectMeta(name=name),
                    role_ref=client.V1RoleRef(
                        api_group="rbac.authorization.k8s.io", kind="ClusterRole", name="cluster-admin"
                    ),
                    subjects=[client.RbacV1Subject(kind="ServiceAccount", name=name, namespace=namespace)],
                )
            )
        except client.exceptions.ApiException as exc:
            if exc.status != 409:
                raise

    def create_dashboard_token(
        self,
        name: str = "k10-dashboard-admin",
        namespace: str = NAMESPACE,
        duration_seconds: int = 24 * 60 * 60,
    ) -> str:
        """Mint a fresh bearer token for the dashboard ServiceAccount (the
        TokenRequest API - equivalent of `kubectl create token`). Tokens are
        short-lived by design; call this again whenever one expires rather
        than persisting it.
        """
        # audiences=[] (not the default None) - the client model's setter
        # rejects None outright even though the API itself treats an empty/
        # absent audiences list as "default to the apiserver's own audience",
        # which is what `kubectl create token` relies on and what the earlier
        # TokenReview checks against both clusters were validated with.
        token_request = client.AuthenticationV1TokenRequest(
            spec=client.V1TokenRequestSpec(audiences=[], expiration_seconds=duration_seconds)
        )
        resp = self.core.create_namespaced_service_account_token(name, namespace, token_request)
        return resp.status.token

    def create_ebs_volume_snapshot_class(self, name: str = "csi-ebs-vsc"):
        """VolumeSnapshotClass for ebs.csi.aws.com, annotated for K10.

        Cluster-scoped, so this can't go through apply_namespaced. Mirrors
        the AKS-side csi-azuredisk-vsc pattern (which AKS ships a working
        snapshotter for out of the box, so it's created via Terraform there
        without hitting the plan-time CRD problem this avoids on EKS).
        """
        vsc = {
            "apiVersion": "snapshot.storage.k8s.io/v1",
            "kind": "VolumeSnapshotClass",
            "metadata": {
                "name": name,
                "annotations": {"k10.kasten.io/is-snapshot-class": "true"},
            },
            "driver": "ebs.csi.aws.com",
            "deletionPolicy": "Delete",
        }
        return self.apply_cluster_scoped(
            "snapshot.storage.k8s.io", "v1", "volumesnapshotclasses", vsc
        )

    def _wait_for_state(self, group: str, version: str, plural: str, name: str, timeout_seconds: int):
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            obj = self.get_namespaced(group, version, plural, NAMESPACE, name)
            state = obj.get("status", {}).get("state")
            if state in ("Complete", "Failed"):
                return state, obj
            time.sleep(10)
        raise TimeoutError(f"{plural}/{name} did not finish within {timeout_seconds}s")

    # -- profiles -------------------------------------------------------------

    def create_profile_azure_blob(
        self, name: str, storage_account: str, storage_key: str, container: str
    ):
        """Location Profile pointing at an Azure Blob container."""
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
            "apiVersion": f"{CONFIG_GROUP}/{CONFIG_VERSION}",
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
        return self.apply_namespaced(CONFIG_GROUP, CONFIG_VERSION, "profiles", NAMESPACE, profile)

    # -- policies ---------------------------------------------------------

    def create_backup_export_policy(
        self,
        name: str,
        app_namespace: str,
        backup_profile_name: str,
        export_profile_name: str,
        receive_string: str = "",
        schedule: str = "@daily",
    ):
        """Policy with separate backup and export actions (each action kind
        gets its own `<action>Parameters` sibling - a single action entry
        with both backupParameters and exportParameters, which the original
        version of this file used, is not how K10 structures it).

        `receive_string` is NOT a shared passphrase you can invent - it's a
        cryptographic envelope K10 generates on the export side. Confirmed
        on a real run: supplying an arbitrary string on the import side
        fails with "cipher: message authentication failed". Leave this
        unset and get the real value from the dashboard's "Show import
        details" action on this policy's export instead.
        """
        export_parameters = {
            "exportData": {"enabled": True},
            "profile": {"name": export_profile_name, "namespace": NAMESPACE},
        }
        if receive_string:
            export_parameters["receiveString"] = receive_string
        policy = {
            "apiVersion": f"{CONFIG_GROUP}/{CONFIG_VERSION}",
            "kind": "Policy",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "frequency": schedule,
                "retention": {"daily": 7},
                "selector": {
                    "matchExpressions": [
                        {
                            "key": "k10.kasten.io/appNamespace",
                            "operator": "In",
                            "values": [app_namespace],
                        }
                    ]
                },
                "actions": [
                    {
                        "action": "backup",
                        "backupParameters": {"profile": {"name": backup_profile_name, "namespace": NAMESPACE}},
                    },
                    {
                        "action": "export",
                        "exportParameters": export_parameters,
                    },
                ],
            },
        }
        return self.apply_namespaced(CONFIG_GROUP, CONFIG_VERSION, "policies", NAMESPACE, policy)

    def create_import_policy(
        self, name: str, import_profile_name: str, receive_string: str, schedule: str = "@daily"
    ):
        """Policy with an import action - the destination-cluster counterpart
        to create_backup_export_policy.

        `receive_string` must be the real value from the source policy's
        export action - "Show import details" in the K10 dashboard - not an
        arbitrary string. Not called anywhere in this repo's own scripts
        (see create.py's Phase 5), since there's no confirmed way to obtain
        that real value without the dashboard; kept here for scripting the
        rest of the setup once you've copied it out yourself.
        """
        policy = {
            "apiVersion": f"{CONFIG_GROUP}/{CONFIG_VERSION}",
            "kind": "Policy",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "frequency": schedule,
                "actions": [
                    {
                        "action": "import",
                        "importParameters": {
                            "profile": {"name": import_profile_name, "namespace": NAMESPACE},
                            "receiveString": receive_string,
                        },
                    }
                ],
            },
        }
        return self.apply_namespaced(CONFIG_GROUP, CONFIG_VERSION, "policies", NAMESPACE, policy)

    # -- transform sets -----------------------------------------------------

    def create_transform_set(self, name: str, from_storage_class: str, to_storage_class: str):
        """TransformSet rewriting a PVC's storageClassName on restore."""
        transform_set = {
            "apiVersion": f"{CONFIG_GROUP}/{CONFIG_VERSION}",
            "kind": "TransformSet",
            "metadata": {"name": name, "namespace": NAMESPACE},
            "spec": {
                "comment": f"rewrite storageClassName {from_storage_class} -> {to_storage_class}",
                "transforms": [
                    {
                        "name": "rewrite-storage-class",
                        "subject": {"resource": "persistentvolumeclaims", "version": "v1"},
                        "json": [
                            {
                                "op": "replace",
                                "path": "/spec/storageClassName",
                                "value": to_storage_class,
                            }
                        ],
                    }
                ],
            },
        }
        return self.apply_namespaced(
            CONFIG_GROUP, CONFIG_VERSION, "transformsets", NAMESPACE, transform_set
        )

    # -- on-demand actions ----------------------------------------------------

    def wait_for_policy_valid(self, policy_name: str, timeout_seconds: int = 60):
        """Poll a Policy's own status until K10's controller finishes
        validating it. Without this, a RunAction created immediately after
        the Policy fails instantly with "Cannot execute action for an
        invalid policy" - confirmed on a real run: the same Policy, run
        again a few minutes later with no changes, worked fine.
        """
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            policy = self.get_namespaced(CONFIG_GROUP, CONFIG_VERSION, "policies", NAMESPACE, policy_name)
            if policy.get("status", {}).get("validation") == "Success":
                return
            time.sleep(3)
        raise TimeoutError(f"Policy {policy_name} did not validate within {timeout_seconds}s")

    def run_policy(self, policy_name: str, timeout_seconds: int = 1800):
        """Create a RunAction to trigger a Policy immediately, and wait for it.

        Returns (state, restore_point_ref) - restore_point_ref is the
        {"name", "namespace"} of the RestorePoint created by a backup or
        import action, or None for actions that don't produce one.
        """
        self.wait_for_policy_valid(policy_name)
        run_action = {
            "apiVersion": f"{ACTIONS_GROUP}/{ACTIONS_VERSION}",
            "kind": "RunAction",
            "metadata": {"generateName": f"{policy_name}-run-", "namespace": NAMESPACE},
            "spec": {
                "subject": {
                    "apiVersion": f"{CONFIG_GROUP}/{CONFIG_VERSION}",
                    "kind": "Policy",
                    "name": policy_name,
                    "namespace": NAMESPACE,
                }
            },
        }
        created = self.custom.create_namespaced_custom_object(
            ACTIONS_GROUP, ACTIONS_VERSION, NAMESPACE, "runactions", run_action
        )
        name = created["metadata"]["name"]
        state, obj = self._wait_for_state(ACTIONS_GROUP, ACTIONS_VERSION, "runactions", name, timeout_seconds)
        return state, obj.get("status", {}).get("restorePoint")

    def latest_restore_point(self):
        """Most recently created RestorePoint - lets failover_demo.py find the
        one create.py's import step produced without a name being manually
        passed between script runs.
        """
        items = self.custom.list_namespaced_custom_object(
            APPS_GROUP, APPS_VERSION, NAMESPACE, "restorepoints"
        )["items"]
        if not items:
            return None
        return max(items, key=lambda item: item["metadata"]["creationTimestamp"])

    def restore_from_restore_point(
        self, restore_point_name: str, restore_profile_name: str, transform_set_name: str,
        timeout_seconds: int = 1800,
    ):
        """Standalone RestoreAction against an imported RestorePoint, applying
        a TransformSet (e.g. to rewrite the storage class for the target
        cluster). Returns the final state ("Complete" or "Failed").
        """
        restore_action = {
            "apiVersion": f"{ACTIONS_GROUP}/{ACTIONS_VERSION}",
            "kind": "RestoreAction",
            "metadata": {"generateName": "veeamon-tour-restore-", "namespace": NAMESPACE},
            "spec": {
                "subject": {
                    "apiVersion": f"{APPS_GROUP}/{APPS_VERSION}",
                    "kind": "RestorePoint",
                    "name": restore_point_name,
                    "namespace": NAMESPACE,
                },
                "profile": {"name": restore_profile_name, "namespace": NAMESPACE},
                "transforms": [{"transformSetRef": {"name": transform_set_name, "namespace": NAMESPACE}}],
            },
        }
        created = self.custom.create_namespaced_custom_object(
            ACTIONS_GROUP, ACTIONS_VERSION, NAMESPACE, "restoreactions", restore_action
        )
        name = created["metadata"]["name"]
        state, _ = self._wait_for_state(ACTIONS_GROUP, ACTIONS_VERSION, "restoreactions", name, timeout_seconds)
        return state
