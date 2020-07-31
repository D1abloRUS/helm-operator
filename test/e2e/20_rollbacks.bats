#!/usr/bin/env bats

function setup() {
  # Load libraries in setup() to access BATS_* variables
  load lib/env
  load lib/helm
  load lib/install
  load lib/poll

  kubectl create namespace "$E2E_NAMESPACE"
  install_gitsrv
  install_tiller
  install_helm_operator_with_helm
  kubectl create namespace "$DEMO_NAMESPACE"
}

@test "When rollback.enable is set, releases with failed waits are rolled back" {
  # Apply the HelmRelease
  kubectl apply -f "$FIXTURES_DIR/releases/helm-repository.yaml" >&3

  # Wait for it to be deployed
  poll_until_equals 'release deploy' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  # Apply a patch which causes wait to fail
  kubectl patch -f "$FIXTURES_DIR/releases/helm-repository.yaml" --type='json' -p='[{"op": "replace", "path": "/spec/values/faults/unready", "value":"true"}]' >&3

  # Wait for release failure
  poll_until_true 'upgrade failure' "kubectl -n $E2E_NAMESPACE logs deploy/helm-operator | grep -E \"upgrade failed\""

  # Wait for rollback
  poll_until_equals 'rollback' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.conditions[?(@.type==\"RolledBack\")].status}'"

  # Apply fix patch
  kubectl apply -f "$FIXTURES_DIR/releases/helm-repository.yaml" >&3

  # Assert recovery
  poll_until_equals 'recovery' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  poll_no_restarts
}

@test "When rollback.retry is set, upgrades are reattempted after a rollback" {
  # Apply the HelmRelease
  kubectl apply -f "$FIXTURES_DIR/releases/helm-repository.yaml" >&3

  # Wait for it to be deployed
  poll_until_equals 'release deploy' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  # Apply a faulty patch and enable retries
  kubectl patch -f "$FIXTURES_DIR/releases/helm-repository.yaml" --type='json' -p='[{"op": "replace", "path": "/spec/values/faults/unready", "value": true},{"op": "add", "path": "/spec/rollback/retry", "value": true}]' >&3

  # Wait for release failure
  poll_until_true 'upgrade failure' "kubectl -n $E2E_NAMESPACE logs deploy/helm-operator | grep -E \"upgrade failed\""

  # Wait for rollback count to increase
  poll_until_equals 'rollback count == 3' '3' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.rollbackCount}'"

  # Apply fix patch
  kubectl apply -f "$FIXTURES_DIR/releases/helm-repository.yaml" >&3

  # Assert rollback count is reset
  poll_until_equals 'rollback count reset' '' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.rollbackCount}'" >&3

  poll_no_restarts
}

@test "When rollback.maxRetries is set to 1,  upgrade is only retried once" {
  # Apply the HelmRelease
  kubectl apply -f "$FIXTURES_DIR/releases/helm-repository.yaml" >&3

  # Wait for it to be deployed
  poll_until_equals 'release deploy' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  # Apply a faulty patch and enable retries
  kubectl patch -f "$FIXTURES_DIR/releases/helm-repository.yaml" --type='json' -p='[{"op": "replace", "path": "/spec/values/faults/unready", "value": true},{"op": "add", "path": "/spec/rollback/retry", "value": true},{"op": "add", "path": "/spec/rollback/maxRetries", "value": 1}]' >&3

  # Wait for release failure
  poll_until_true 'upgrade failure' "kubectl -n $E2E_NAMESPACE logs deploy/helm-operator | grep -E \"upgrade failed\""

  # Wait for rollback count to increase
  poll_until_equals 'rollback count == 2' '2' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-helm-repository -o jsonpath='{.status.rollbackCount}'"

  # Wait for dry-run to be compared, instead of retry
  poll_until_true 'dry-run comparison to failed release' "kubectl -n $E2E_NAMESPACE logs deploy/helm-operator | grep -E \"running dry-run upgrade to compare with release\""

  poll_no_restarts
}

@test "When rollback.enable is set, validation error does not trigger a rollback" {
  if [ "$HELM_VERSION" != "v3" ]; then
    skip
  fi

  # Apply the HelmRelease
  kubectl apply -f "$FIXTURES_DIR/releases/git.yaml" >&3

  # Wait for it to be deployed
  poll_until_equals 'release deploy' 'True' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-git -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  # Apply a faulty patch
  kubectl patch -f "$FIXTURES_DIR/releases/git.yaml" --type='json' -p='[{"op": "replace", "path": "/spec/values/replicaCount", "value":"faulty"}]' >&3

  # Wait for release failure
  poll_until_equals 'upgrade failure' 'False' "kubectl -n $DEMO_NAMESPACE get helmrelease/podinfo-git -o jsonpath='{.status.conditions[?(@.type==\"Released\")].status}'"

  # Assert release version
  version=$(helm status podinfo-git --namespace "$DEMO_NAMESPACE" -o json | jq .version)
  [ "$version" -eq 1 ]

  # Assert rollback count is zero
  count=$(kubectl -n "$DEMO_NAMESPACE" get helmrelease/podinfo-git -o jsonpath='{.status.rollbackCount}')
  [ -z "$count" ]

  poll_no_restarts
}

function teardown() {
  # Teardown is verbose when a test fails, and this will help most of the time
  # to determine _why_ it failed.
  echo ""
  echo "### Previous container:"
  kubectl logs -n "$E2E_NAMESPACE" deploy/helm-operator -p
  echo ""
  echo "### Current container:"
  kubectl logs -n "$E2E_NAMESPACE" deploy/helm-operator

  # Removing the operator also takes care of the global resources it installs.
  uninstall_helm_operator_with_helm
  uninstall_tiller
  # Removing the namespace also takes care of removing gitsrv.
  kubectl delete namespace "$E2E_NAMESPACE"
  # Only remove the demo workloads after the operator, so that they cannot be recreated.
  kubectl delete namespace "$DEMO_NAMESPACE"
}
