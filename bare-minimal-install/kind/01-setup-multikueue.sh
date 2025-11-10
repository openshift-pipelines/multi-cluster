#!/bin/bash

# This script sets up a MultiKueue environment with one manager and a specified number of workers.

set -o errexit
set -o nounset
set -o pipefail

# Number of workers to create, default to 1
NUM_WORKERS=${1:-1}

# Manifest URLs from the user's script
KUEUE_MANIFEST_URL="https://gist.githubusercontent.com/khrm/a83998529449ae0f0e25c264d4e61dd0/raw/bd7933eea4b509996dbe7a4739ff96dd2101b0e3/gistfile0.txt"
MULTIKUEUE_MANIFEST_URL="https://gist.githubusercontent.com/khrm/4a022f27a97c5f1456cdc05a64885860/raw/ba1b9ae77b55ac3319de207167ab4590eb78bb0a/gistfile0.txt"
CERT_MANAGER_URL="https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml"

# Embedded worker-setup.yaml content
WORKER_SETUP_YAML=$(cat <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: "default-flavor"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: "cluster-queue"
spec:
  namespaceSelector: {} # match all.
  resourceGroups:
  - coveredResources: ["cpu", "memory", "tekton.dev/pipelineruns"]
    flavors:
    - name: "default-flavor"
      resources:
      - name: "cpu"
        nominalQuota: 9
      - name: "memory"
        nominalQuota: 36Gi
      - name: "tekton.dev/pipelineruns"
        nominalQuota: "1"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  namespace: "default"
  name: "user-queue"
spec:
  clusterQueue: "cluster-queue"
EOF
)

# Function to set up the manager cluster
setup_manager() {
  echo "Creating manager cluster..."
  kind create cluster --name=manager
  kubectl config use-context kind-manager

  echo "Installing Tekton Pipelines on manager..."
kubectl apply --server-side -f https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml
  
  echo "Installing cert-manager on manager..."
  kubectl apply --server-side -f ${CERT_MANAGER_URL}
  echo "Waiting for cert-manager to be ready..."
  kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
  
  echo "Waiting for Tekton Pipelines to be ready..."
  kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

  echo "Installing Kueue on manager..."
  kubectl apply --server-side -f ${KUEUE_MANIFEST_URL}
  echo "Waiting for Kueue to be ready..."
  kubectl wait --for=condition=Available deployment --all -n kueue-system --timeout=300s
  
  echo "Installing MultiKueue controller on manager..."
  kubectl apply -f ${MULTIKUEUE_MANIFEST_URL}
  echo "Waiting for MultiKueue controller to be ready..."
  kubectl wait --for=condition=Available deployment --all -n tekton-kueue --timeout=300s
}

# Function to set up a worker cluster
setup_worker() {
  local worker_num=$1
  local worker_name="worker${worker_num}"
  local host_port=$((6443 + worker_num))

  echo "Creating worker cluster ${worker_name}..."

  # Dynamically create kind config for the worker
  cat <<EOF > "kind-config-${worker_name}.yaml"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${worker_name}
networking:
  apiServerAddress: "0.0.0.0"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
      - "localhost"
      - "127.0.0.1"
      - "0.0.0.0"
      - "${worker_name}-control-plane"
  extraPortMappings:
  - containerPort: 6443
    hostPort: ${host_port}
    protocol: TCP
EOF

  kind create cluster --config "kind-config-${worker_name}.yaml"
  kubectl config use-context "kind-${worker_name}"

  echo "Installing Tekton Pipelines on ${worker_name}..."
  kubectl apply --server-side -f https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml

  echo "Installing Kueue on ${worker_name}..."
  kubectl apply --server-side -f ${KUEUE_MANIFEST_URL}
  echo "Waiting for Kueue to be ready on ${worker_name}..."
  kubectl wait --for=condition=Available deployment --all -n kueue-system --timeout=300s

  echo "Applying worker setup on ${worker_name}..."
  echo "${WORKER_SETUP_YAML}" | kubectl apply -f - 

  echo "Creating kubeconfig for ${worker_name}..."
  create_worker_kubeconfig "${worker_name}"

  echo "Switching back to manager context..."
  kubectl config use-context kind-manager

  echo "Creating secret for ${worker_name} on manager..."
  kubectl create secret generic "${worker_name}-secret" -n kueue-system --from-file=kubeconfig="${worker_name}.kubeconfig"
}

# Function to create a kubeconfig for a worker
create_worker_kubeconfig() {
    local worker_name=$1
    local kubeconfig_out="${worker_name}.kubeconfig"
    local multikueue_sa="multikueue-sa"
    local namespace="kueue-system"

    kubectl config use-context "kind-${worker_name}"

    echo "Creating RBAC for multikueue service account on ${worker_name}..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${multikueue_sa}
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${multikueue_sa}-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["kueue.x-k8s.io"]
  resources: ["workloads", "workloads/status"]
  verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "pipelineruns/status"]
  verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${multikueue_sa}-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${multikueue_sa}-role
subjects:
- kind: ServiceAccount
  name: ${multikueue_sa}
  namespace: ${namespace}
EOF

    local sa_secret_name
    sa_secret_name=$(kubectl get -n ${namespace} sa/${multikueue_sa} -o "jsonpath={.secrets[0]..name}")
    if [ -z "$sa_secret_name" ]; then
        kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: ${multikueue_sa}
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: "${multikueue_sa}"
EOF
        sa_secret_name=${multikueue_sa}
    fi

    local sa_token
    sa_token=$(kubectl get -n ${namespace} "secrets/${sa_secret_name}" -o "jsonpath={.data['token']}" | base64 -d)
    local ca_cert
    ca_cert=$(kubectl get -n ${namespace} "secrets/${sa_secret_name}" -o "jsonpath={.data['ca\.crt']}")
    local current_context
    current_context=$(kubectl config current-context)
    local current_cluster
    current_cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name == \"${current_context}\")].context.cluster}")
    
    local current_cluster_addr="https://${worker_name}-control-plane:6443"

    echo "Writing kubeconfig in ${kubeconfig_out}"
    cat > "${kubeconfig_out}" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${ca_cert}
    server: ${current_cluster_addr}
  name: ${current_cluster}
contexts:
- context:
    cluster: ${current_cluster}
    user: ${current_cluster}-${multikueue_sa}
  name: ${current_context}
current-context: ${current_context}
kind: Config
preferences: {}
users:
- name: ${current_cluster}-${multikueue_sa}
  user:
    token: ${sa_token}
EOF
}

# Function to generate the multi-kueue-setup.yaml file
generate_multikueue_config() {
  local num_workers=$1
  local config_file="multi-kueue-setup-generated.yaml"

  echo "Generating ${config_file} for ${num_workers} worker(s)..."

  # Start with the static part of the config
  cat <<EOF > "${config_file}"
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: "default-flavor"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: "cluster-queue"
spec:
  namespaceSelector: {} # match all.
  resourceGroups:
  - coveredResources: ["cpu", "memory", "tekton.dev/pipelineruns"]
    flavors:
    - name: "default-flavor"
      resources:
      - name: "cpu"
        nominalQuota: 9
      - name: "memory"
        nominalQuota: 36Gi
      - name: "tekton.dev/pipelineruns"
        nominalQuota: "1"
  admissionChecks:
  - sample-multikueue
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  namespace: "default"
  name: "user-queue"
spec:
  clusterQueue: "cluster-queue"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: AdmissionCheck
metadata:
  name: sample-multikueue
spec:
  controllerName: kueue.x-k8s.io/multikueue
  parameters:
    apiGroup: kueue.x-k8s.io
    kind: MultiKueueConfig
    name: multikueue-test
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: MultiKueueConfig
metadata:
  name: multikueue-test
spec:
  clusters:
EOF

  # Add all worker clusters to the MultiKueueConfig
  for i in $(seq 1 "${num_workers}"); do
    echo "  - multikueue-test-worker${i}" >> "${config_file}"
  done

  # Add a MultiKueueCluster for each worker
  for i in $(seq 1 "${num_workers}"); do
    cat <<EOF >> "${config_file}"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: MultiKueueCluster
metadata:
  name: multikueue-test-worker${i}
spec:
  kubeConfig:
    locationType: Secret
    location: worker${i}-secret
EOF
  done
}

# Main script execution
main() {
  setup_manager

  for i in $(seq 1 "${NUM_WORKERS}"); do
    setup_worker "${i}"
  
  done

  generate_multikueue_config "${NUM_WORKERS}"

  echo "Applying generated multi-kueue setup..."
  kubectl config use-context kind-manager
  kubectl apply -f multi-kueue-setup-generated.yaml

  echo "Setup complete. Verifying..."
  sleep 10 # Give some time for controllers to reconcile

  kubectl get clusterqueues cluster-queue -o jsonpath="{range .status.conditions[?(@.type == 'Active')]}{'CQ - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
  kubectl get admissionchecks sample-multikueue -o jsonpath="{range .status.conditions[?(@.type == 'Active')]}{'AC - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
  for i in $(seq 1 "${NUM_WORKERS}"); do
    kubectl get multikueuecluster "multikueue-test-worker${i}" -o jsonpath="{range .status.conditions[?(@.type == 'Active')]}{'MC - Active: '}{@.status}{' Reason: '}{@.reason}{' Message: '}{@.message}{'\n'}{end}"
  done
}

main
