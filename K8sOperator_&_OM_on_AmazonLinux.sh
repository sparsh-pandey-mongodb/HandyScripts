#!/usr/bin/env bash
# MongoDB Ops Manager on Amazon Linux 2023 with kind and latest Operator
# - Installs Docker, kind, kubectl, git
# - Creates kind cluster with required port mappings
# - Installs latest MongoDB Enterprise Operator 
# - Deploys Ops Manager 8.0.11 + AppDB 8.0.10-ent (ephemeral storage)
# - Exposes Ops Manager at http://<EC2-PUBLIC-DNS>:8080 (NodePort 30080 -> kind port mapping)
# - Logs saved to setup-ops-manager.log
# - Supports --cleanup

set -euo pipefail

# ========================
# Configurable defaults (override via env vars if needed)
# ========================
KIND_VERSION="${KIND_VERSION:-0.23.0}"
K8S_VERSION="${K8S_VERSION:-1.28.13}"              # kindest/node tag
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
KUBECONTEXT="kind-${KIND_CLUSTER_NAME}"
NAMESPACE="${NAMESPACE:-mongodb}"

# Ops Manager + AppDB versions
OM_VERSION="${OM_VERSION:-8.0.11}"                 # tag known to exist on Quay
APPDB_VERSION="${APPDB_VERSION:-8.0.10-ent}"

# Ops Manager initial admin (used for login)
OM_ADMIN_USER="${OM_ADMIN_USER:-sparsh.pandey@mongodb.com}"
OM_ADMIN_PASS="${OM_ADMIN_PASS:-Sp2468@password}"
OM_FN="${OM_FN:-Sparsh}"
OM_LN="${OM_LN:-Pandey}"

# Files/dirs
WORKDIR="${WORKDIR:-$(pwd)}"
ASSETS_DIR="${ASSETS_DIR:-${WORKDIR}/om-assets}"
KIND_CONFIG="${KIND_CONFIG:-${ASSETS_DIR}/kind-config.yaml}"
OM_MANIFEST="${OM_MANIFEST:-${ASSETS_DIR}/ops-manager.yaml}"
NODEPORT_SVC="${NODEPORT_SVC:-${ASSETS_DIR}/ops-manager-nodeport.yaml}"
OP_REPO_DIR="${OP_REPO_DIR:-${WORKDIR}/mongodb-enterprise-kubernetes}"
KCFG_FILE="${KCFG_FILE:-${ASSETS_DIR}/kubeconfig}"
LOG_FILE="${LOG_FILE:-${WORKDIR}/setup-ops-manager.log}"

# ========================
# Utilities (quiet run)
# ========================
log()       { printf '%s\n' "$*"; }
ts()        { awk '{ print strftime("[%F %T]"), $0 }'; }        # prefix lines with [YYYY-MM-DD HH:MM:SS]
log_step()  { local m="[$(date +'%F %T')] $*"; echo "$m"; echo "$m" >>"$LOG_FILE"; }
log_err()   { local m="[$(date +'%F %T')] ERROR: $*"; echo "$m" >&2; echo "$m" >>"$LOG_FILE"; }

run_ts() {  # run with stdout/stderr timestamped into LOG_FILE, preserve exit code
  ( "$@" 2>&1 | ts ) >>"$LOG_FILE"
}

qrun() {  # qrun "Desc" command...
  local desc="$1"; shift
  log_step "$desc"
  run_ts "$@"
}

tryrun() {  # tryrun "Desc" command... (fail hard on error)
  local desc="$1"; shift
  log_step "$desc"
  if ! run_ts "$@"; then
    log_err "Failed: $desc. See $LOG_FILE"
    exit 1
  fi
}

wait_cmd() {  # wait for a command to succeed with timeout (seconds), quiet + timestamped logs
  local timeout="${1:-60}"; shift
  local start ts_now
  start="$(date +%s)"
  while true; do
    if run_ts "$@"; then return 0; fi
    ts_now="$(date +%s)"
    if (( ts_now - start > timeout )); then return 1; fi
    sleep 3
  done
}

wait_exists() { # wait for a Kubernetes object to be present (quiet)
  local timeout="${1}"; local ns="${2}"; local kind="${3}"; local name="${4}"
  wait_cmd "${timeout}" kubectl --context "${KUBECONTEXT}" -n "${ns}" get "${kind}" "${name}"
}

# Wait for a StatefulSet to be fully ready (no piping in variable capture)
wait_sts_ready() {
  local ns="$1" sts="$2" timeout="${3:-900}" sleep_s=5
  local start now replicas ready currrev uprev last_ready=-1
  start="$(date +%s)"
  log_step "Waiting for StatefulSet '${sts}' to be Ready (timeout ${timeout}s)..."
  while true; do
    # Capture values silently; do not pipe to the timestamp filter here
    replicas="$(kubectl --context "${KUBECONTEXT}" -n "${ns}" get sts "${sts}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
    ready="$(kubectl --context "${KUBECONTEXT}" -n "${ns}" get sts "${sts}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    currrev="$(kubectl --context "${KUBECONTEXT}" -n "${ns}" get sts "${sts}" -o jsonpath='{.status.currentRevision}' 2>/dev/null || true)"
    uprev="$(kubectl --context "${KUBECONTEXT}" -n "${ns}" get sts "${sts}" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)"
    [[ -z "${replicas}" || "${replicas}" == "null" ]] && replicas=0
    [[ -z "${ready}"    || "${ready}"    == "null" ]] && ready=0

    # Only print when readiness changes
    if [[ "${ready}" != "${last_ready}" ]]; then
      log_step "${sts}: ${ready}/${replicas} Ready"
      last_ready="${ready}"
    fi

    # Success: all replicas ready and revisions match
    if [[ "${replicas}" -gt 0 && "${ready}" -eq "${replicas}" && -n "${currrev}" && -n "${uprev}" && "${currrev}" == "${uprev}" ]]; then
      log_step "StatefulSet '${sts}' is Ready."
      return 0
    fi

    now="$(date +%s)"
    if (( now - start > timeout )); then
      log_err "Timeout waiting for StatefulSet '${sts}' to be Ready. See $LOG_FILE for details."
      {
        echo "---- Describe sts ${sts} ----"
        kubectl --context "${KUBECONTEXT}" -n "${ns}" describe sts "${sts}" || true
        echo "---- Pods for ${sts} ----"
        kubectl --context "${KUBECONTEXT}" -n "${ns}" get pods -o wide | sed -n "1p; /${sts}-/p" || true
      } | ts >>"$LOG_FILE" 2>&1
      return 1
    fi
    sleep "${sleep_s}"
  done
}

# ========================
# Cleanup 
# ========================
cleanup() {
  log_step "Starting cleanup..."
  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    kind get kubeconfig --name "${KIND_CLUSTER_NAME}" > "${KCFG_FILE}" 2>>"$LOG_FILE" || true
    export KUBECONFIG="${KCFG_FILE}"
    kubectl config use-context "${KUBECONTEXT}" >>"$LOG_FILE" 2>&1 || true
  fi

  wait_deleted() {
    local ns="$1" kind="$2" name="$3" timeout="${4:-120}"
    wait_cmd "${timeout}" kubectl --context "${KUBECONTEXT}" -n "${ns}" get "${kind}" "${name}" >/dev/null
  }
  remove_finalizers() {
    local ns="$1" kind="$2" name="$3"
    kubectl --context "${KUBECONTEXT}" -n "${ns}" patch "${kind}" "${name}" -p '{"metadata":{"finalizers":[]}}' --type=merge | ts >>"$LOG_FILE" 2>&1 || true
  }

  if kubectl --context "${KUBECONTEXT}" get crd opsmanagers.mongodb.com >/dev/null 2>&1; then
    if kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get MongoDBOpsManager ops-manager >/dev/null 2>&1; then
      qrun "Deleting Ops Manager CR..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete MongoDBOpsManager ops-manager --wait=false
      if ! wait_deleted "${NAMESPACE}" "MongoDBOpsManager" "ops-manager" 180; then
        qrun "Removing finalizers from Ops Manager CR..." remove_finalizers "${NAMESPACE}" "MongoDBOpsManager" "ops-manager"
        qrun "Retry delete Ops Manager CR..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete MongoDBOpsManager ops-manager --wait=false
      fi
    fi
  fi
  if kubectl --context "${KUBECONTEXT}" get crd mongodb.mongodb.com >/dev/null 2>&1; then
    for obj in $(kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get MongoDB -o name 2>/dev/null || true); do
      name="${obj##*/}"
      qrun "Deleting MongoDB CR '${name}'..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete "${obj}" --wait=false
      if ! wait_deleted "${NAMESPACE}" "MongoDB" "${name}" 180; then
        qrun "Removing finalizers from MongoDB CR '${name}'..." remove_finalizers "${NAMESPACE}" "MongoDB" "${name}"
        qrun "Retry delete MongoDB CR '${name}'..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete MongoDB "${name}" --wait=false
      fi
    done
  fi

  qrun "Deleting NodePort service..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" delete svc ops-manager --ignore-not-found

  if [ -d "${OP_REPO_DIR}" ]; then
    qrun "Deleting operator deployment..." kubectl --context "${KUBECONTEXT}" delete -f "${OP_REPO_DIR}/mongodb-enterprise.yaml" --ignore-not-found
    wait_cmd 120 kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get deploy mongodb-enterprise-operator >/dev/null || true
    qrun "Deleting CRDs..." kubectl --context "${KUBECONTEXT}" delete -f "${OP_REPO_DIR}/crds.yaml" --ignore-not-found
    wait_cmd 120 kubectl --context "${KUBECONTEXT}" get crd opsmanagers.mongodb.com >/dev/null || true
  fi

  if kubectl --context "${KUBECONTEXT}" get ns "${NAMESPACE}" >/dev/null 2>&1; then
    qrun "Deleting namespace '${NAMESPACE}'..." kubectl --context "${KUBECONTEXT}" delete ns "${NAMESPACE}" --wait=false
    if ! wait_cmd 180 kubectl --context "${KUBECONTEXT}" get ns "${NAMESPACE}" >/dev/null; then
      kubectl --context "${KUBECONTEXT}" get ns "${NAMESPACE}" -o json | \
        sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' | \
        kubectl --context "${KUBECONTEXT}" replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - | ts >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    qrun "Deleting kind cluster '${KIND_CLUSTER_NAME}'..." kind delete cluster --name "${KIND_CLUSTER_NAME}"
  fi

  rm -rf "${OP_REPO_DIR}" "${ASSETS_DIR}" >>"$LOG_FILE" 2>&1 || true
  log_step "Cleanup complete."
  exit 0
}

# ========================
# Arg parsing
# ========================
if [[ "${1:-}" == "--cleanup" ]]; then
  cleanup
fi

# ========================
# Preflight and installs (quiet)
# ========================
mkdir -p "${ASSETS_DIR}" >>"$LOG_FILE" 2>&1
log_step "Logs: $LOG_FILE"

if ! command -v yum >/dev/null 2>&1; then
  log_err "This script targets Amazon Linux (yum). Aborting."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  tryrun "Installing Docker..." sudo yum -y install docker
fi
tryrun "Enabling and starting Docker..." sudo systemctl enable --now docker
if ! wait_cmd 60 docker info; then log_err "Docker daemon not responding. See $LOG_FILE"; exit 1; fi

if ! command -v git >/dev/null 2>&1; then
  tryrun "Installing git..." sudo yum -y install git
fi

if ! command -v kind >/dev/null 2>&1; then
  tryrun "Installing kind v${KIND_VERSION}..." sudo curl -fsSL -o /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64"
  tryrun "Setting kind executable bit..." sudo chmod +x /usr/local/bin/kind
fi
log_step "kind: $(kind --version 2>>"$LOG_FILE")"

if ! command -v kubectl >/dev/null 2>&1; then
  tryrun "Installing kubectl v${K8S_VERSION}..." curl -fsSL -o "${ASSETS_DIR}/kubectl" "https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64/kubectl"
  tryrun "Placing kubectl..." sudo install -o root -g root -m 0755 "${ASSETS_DIR}/kubectl" /usr/local/bin/kubectl
fi
log_step "kubectl client installed."

# ========================
# kind cluster
# ========================
if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
  log_step "Creating kind cluster '${KIND_CLUSTER_NAME}'..."
  cat > "${KIND_CONFIG}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: dual
nodes:
- role: control-plane
  extraPortMappings:
    - containerPort: 30080
      hostPort: 8080
      protocol: TCP
    - containerPort: 30843
      hostPort: 8443
      protocol: TCP
    - containerPort: 27017
      hostPort: 27017
      protocol: TCP
    - containerPort: 27018
      hostPort: 27018
      protocol: TCP
    - containerPort: 27019
      hostPort: 27019
      protocol: TCP
- role: worker
- role: worker
EOF
  tryrun "Creating kind cluster..." kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KIND_CONFIG}" --retain --image "kindest/node:v${K8S_VERSION}"
else
  log_step "kind cluster '${KIND_CLUSTER_NAME}' already exists. Skipping creation."
fi

# Export kubeconfig correctly (stdout to file), log only stderr with timestamps
log_step "Exporting kubeconfig..."
kind get kubeconfig --name "${KIND_CLUSTER_NAME}" > "${KCFG_FILE}" 2>>"$LOG_FILE"
export KUBECONFIG="${KCFG_FILE}"
kubectl config use-context "${KUBECONTEXT}" >>"$LOG_FILE" 2>&1 || true

if ! wait_cmd 180 kubectl --context "${KUBECONTEXT}" get --raw='/readyz'; then
  log_err "Kubernetes API not ready in time. See $LOG_FILE"
  exit 1
fi
tryrun "Waiting for nodes to be Ready..." kubectl --context "${KUBECONTEXT}" wait --for=condition=Ready node --all --timeout=300s
qrun "Setting Docker restart policy for kind containers..." docker update --restart unless-stopped $(docker ps -a --filter "name=kind" --format "{{.ID}}")

# ========================
# Namespace
# ========================
if kubectl --context "${KUBECONTEXT}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log_step "Namespace '${NAMESPACE}' already exists."
else
  tryrun "Creating namespace '${NAMESPACE}'..." kubectl --context "${KUBECONTEXT}" create namespace "${NAMESPACE}"
fi

# ========================
# Operator (latest via git clone)
# ========================
if [ -d "${OP_REPO_DIR}" ]; then
  qrun "Updating operator repo..." git -C "${OP_REPO_DIR}" pull --ff-only
else
  tryrun "Cloning operator repo..." git clone https://github.com/mongodb/mongodb-enterprise-kubernetes.git "${OP_REPO_DIR}"
fi

tryrun "Applying CRDs..." kubectl --context "${KUBECONTEXT}" apply -f "${OP_REPO_DIR}/crds.yaml"
tryrun "Applying operator..." kubectl --context "${KUBECONTEXT}" apply -f "${OP_REPO_DIR}/mongodb-enterprise.yaml"
tryrun "Waiting for CRD 'opsmanagers.mongodb.com'..." kubectl --context "${KUBECONTEXT}" wait --for=condition=Established crd/opsmanagers.mongodb.com --timeout=180s
tryrun "Waiting for operator to be Available..." kubectl --context "${KUBECONTEXT}" rollout status deployment mongodb-enterprise-operator -n "${NAMESPACE}" --timeout=300s

# ========================
# Admin secret
# ========================
cat > "${ASSETS_DIR}/ops-manager-admin-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ops-manager-admin-secret
type: Opaque
stringData:
  Username: "${OM_ADMIN_USER}"
  Password: "${OM_ADMIN_PASS}"
  FirstName: "${OM_FN}"
  LastName: "${OM_LN}"
EOF
tryrun "Creating/updating Ops Manager admin secret..." kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" apply -f "${ASSETS_DIR}/ops-manager-admin-secret.yaml"
if ! wait_cmd 30 kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get secret ops-manager-admin-secret; then
  log_err "Admin secret not found after creation. See $LOG_FILE"
  exit 1
fi

# ========================
# Ops Manager CR (ephemeral AppDB)
# ========================
cat > "${OM_MANIFEST}" <<EOF
apiVersion: mongodb.com/v1
kind: MongoDBOpsManager
metadata:
  name: ops-manager
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  version: ${OM_VERSION}
  adminCredentials: ops-manager-admin-secret
  configuration:
    mms.fromEmailAddr: "admin@example.com"
  statefulSet:
    spec:
      template:
        spec:
          securityContext:
            fsGroup: 2000
            runAsNonRoot: true
            runAsUser: 2000
  applicationDatabase:
    members: 3
    version: ${APPDB_VERSION}
    additionalMongodConfig:
      operationProfiling:
        mode: slowOp
    podSpec:
      podTemplate:
        spec:
          securityContext:
            fsGroup: 2000
            runAsNonRoot: true
            runAsUser: 2000
      # No dataVolumeClaimSpec -> ephemeral (EmptyDir) storage for AppDB
EOF

tryrun "Applying Ops Manager CR..." kubectl --context "${KUBECONTEXT}" apply -f "${OM_MANIFEST}"

if ! wait_exists 300 "${NAMESPACE}" statefulset.apps ops-manager-db; then
  log_err "ops-manager-db StatefulSet did not appear in time. See $LOG_FILE"
  exit 1
fi
wait_sts_ready "${NAMESPACE}" "ops-manager-db" 900

if ! wait_exists 300 "${NAMESPACE}" statefulset.apps ops-manager; then
  log_err "ops-manager StatefulSet did not appear in time. See $LOG_FILE"
  exit 1
fi
wait_sts_ready "${NAMESPACE}" "ops-manager" 900

# ========================
# NodePort Service (EC2:8080)
# ========================
if ! kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get svc ops-manager-svc >/dev/null 2>&1; then
  log_err "Service ops-manager-svc not found. See $LOG_FILE"
  exit 1
fi

if kubectl --context "${KUBECONTEXT}" -n "${NAMESPACE}" get svc ops-manager >/dev/null 2>&1; then
  log_step "NodePort service 'ops-manager' already exists."
else
  cat > "${NODEPORT_SVC}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ops-manager
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: ops-manager-svc
  ports:
    - name: http
      protocol: TCP
      port: 8080
      targetPort: 8080
      nodePort: 30080
EOF
  tryrun "Creating NodePort service 'ops-manager'..." kubectl --context "${KUBECONTEXT}" apply -f "${NODEPORT_SVC}"
fi

# Use bash -c to ensure pipeline executes inside wait_cmd
if ! wait_cmd 180 bash -c "kubectl --context '${KUBECONTEXT}' -n '${NAMESPACE}' get endpoints ops-manager -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -qE '^[0-9]'"; then
  log_step "Warning: Service endpoints not populated yet; proceeding. See $LOG_FILE"
fi

# ========================
# Final summary
# ========================
log_step "Ops Manager deployed successfully."
log_step "Access URL: http://<EC2-PUBLIC-DNS>:8080"
log_step "Login user: ${OM_ADMIN_USER}"
log_step "Logs saved to: ${LOG_FILE}"
#kubectl config set-context $(kubectl config current-context) --namespace=mongodb
