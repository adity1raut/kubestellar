#!/usr/bin/env bash
# Copyright 2025 The KubeStellar Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Test script to install ArgoCD using Helm and verify its functionality

set -e
set -x

# Default environment is 'kind'
env="kind"
if [ "$1" == "--env" ]; then
    env="$2"
fi

# Resolve script directory
SRC_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
COMMON_SRCS="${SRC_DIR}/../common"

# Source helper scripts (assuming they exist as in original setup)
source "$COMMON_SRCS/setup-shell.sh"
source "$COMMON_SRCS/setup-kubestellar.sh" --env "$env"

# Check prerequisites
"${SRC_DIR}/../../../scripts/check_pre_req.sh" --assert --verbose kind kubectl helm ko

# Set hosting context based on environment
case "$env" in
    kind) HOSTING_CONTEXT=kind-kubeflex ;;
    ocp)  HOSTING_CONTEXT=kscore ;;
    *)    echo "ERROR: Unsupported environment '$env'. Supported: kind, ocp" >&2; exit 1 ;;
esac

# Function to run commands with timeout
timeout_cmd() {
    local cmd="$1"
    local timeout_duration=30
    timeout --foreground "$timeout_duration" bash -c "$cmd" || {
        echo "ERROR: Command timed out after ${timeout_duration}s: $cmd" >&2
        return 1
    }
}

# Step 1: Install ArgoCD using Helm
echo "Step 1: Installing ArgoCD using Helm..."
ARGOCD_NS="argocd"
kubectl --context "$HOSTING_CONTEXT" create namespace "$ARGOCD_NS" 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
if ! timeout_cmd "helm install argocd argo/argo-cd --namespace '$ARGOCD_NS' --kube-context '$HOSTING_CONTEXT' --version 7.6.0 --set server.service.type=ClusterIP --wait"; then
    echo "ERROR: Failed to install ArgoCD using Helm." >&2
    exit 1
fi

# Step 2: Verify ArgoCD pods are running
echo "Step 2: Verifying ArgoCD pods are Running..."
if ! timeout_cmd "kubectl --context '$HOSTING_CONTEXT' get pods -n '$ARGOCD_NS' -l app.kubernetes.io/part-of=argocd | grep Running | wc -l | grep -v ^0$"; then
    echo "FAIL: ArgoCD pods are not running or not found." >&2
    exit 1
fi

# Step 3: Get ArgoCD server pod and namespace
echo "Step 3: Identifying ArgoCD server pod..."
ARGOCD_POD=$(kubectl --context "$HOSTING_CONTEXT" get pods -n "$ARGOCD_NS" -l app.kubernetes.io/name=argocd-server -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null) || {
    echo "ERROR: Failed to find ArgoCD server pod with label app.kubernetes.io/name=argocd-server." >&2
    exit 1
}
POD_COUNT=$(kubectl --context "$HOSTING_CONTEXT" get pods -n "$ARGOCD_NS" -l app.kubernetes.io/name=argocd-server --no-headers | wc -l)
if [ "$POD_COUNT" -ne 1 ]; then
    echo "ERROR: Expected exactly one ArgoCD server pod, found $POD_COUNT." >&2
    exit 1
fi

# Step 4: Get ArgoCD admin password
echo "Step 4: Retrieving ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl --context "$HOSTING_CONTEXT" -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null) || {
    echo "ERROR: Failed to retrieve ArgoCD admin password." >&2
    exit 1
}

# Step 5: Log into ArgoCD via CLI
echo "Step 5: Logging into ArgoCD via CLI..."
if ! timeout_cmd "kubectl --context '$HOSTING_CONTEXT' -n '$ARGOCD_NS' exec '$ARGOCD_POD' -- argocd login argocd-server.'$ARGOCD_NS' --username admin --password '$ARGOCD_PASSWORD' --insecure"; then
    echo "ERROR: Failed to log into ArgoCD." >&2
    exit 1
}

# Step 6: List ArgoCD clusters
echo "Step 6: Listing ArgoCD clusters..."
if ! timeout_cmd "kubectl --context '$HOSTING_CONTEXT' -n '$ARGOCD_NS' exec '$ARGOCD_POD' -- argocd cluster list"; then
    echo "ERROR: Failed to list ArgoCD clusters." >&2
    exit 1
}

# Step 7: Verify ArgoCD application controller
echo "Step 7: Verifying ArgoCD application controller..."
if ! timeout_cmd "kubectl --context '$HOSTING_CONTEXT' get pods -n '$ARGOCD_NS' -l app.kubernetes.io/name=argocd-application-controller | grep Running | wc -l | grep -v ^0$"; then
    echo "ERROR: ArgoCD application controller is not running." >&2
    exit 1
}

# Step 8: Create and verify a test application (optional, but useful for deeper validation)
echo "Step 8: Creating a test ArgoCD application..."
cat <<EOF | kubectl --context "$HOSTING_CONTEXT" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app
  namespace: $ARGOCD_NS
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated: {}
EOF

# Wait for the test application to be healthy
echo "Step 9: Verifying test application status..."
if ! timeout_cmd "kubectl --context '$HOSTING_CONTEXT' -n '$ARGOCD_NS' exec '$ARGOCD_POD' -- argocd app get test-app | grep Healthy"; then
    echo "ERROR: Test application did not reach Healthy status." >&2
    exit 1
}

# Step 10: Clean up test application
echo "Step 10: Cleaning up test application..."
kubectl --context "$HOSTING_CONTEXT" delete application test-app -n "$ARGOCD_NS" --ignore-not-found

echo "SUCCESS: ArgoCD installation and functionality test passed!"