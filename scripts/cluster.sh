#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/versions.env"

CLUSTER_NAME="${CLUSTER_NAME:-jepsen}"
METALLB_NS="metallb-system"
METALLB_VERSION="${METALLB_VERSION:-v0.14.8}"

require_cmd() { command -v "$1" >/dev/null 2>&1; }
die() { echo "[-] $*" >&2; exit 1; }

ensure_tools() {
  for c in docker kubectl kind curl; do
    require_cmd "$c" || die "Missing required command: $c (run ./scripts/host-setup.sh)"
  done
}

kind_network_name() { echo "kind"; }

detect_metallb_pool() {
  if [[ -n "${METALLB_POOL_CIDR:-}" ]]; then
    echo "${METALLB_POOL_CIDR}"
    return 0
  fi

  local net subnets subnet ip a b
  net="$(kind_network_name)"

  subnets="$(docker network inspect "${net}" -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null || true)"
  [[ -n "${subnets}" ]] || die "Could not detect docker network subnets for '${net}'. Set METALLB_POOL_CIDR manually."

  subnet="$(echo "${subnets}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -n1 || true)"
  if [[ -z "${subnet}" ]]; then
    die "No IPv4 subnet found for docker network '${net}'. Detected: ${subnets}. Set METALLB_POOL_CIDR manually, or create kind cluster with IPv4."
  fi

  ip="${subnet%/*}"
  IFS='.' read -r a b _ _ <<<"${ip}"
  [[ -n "${a:-}" && -n "${b:-}" ]] || die "Unexpected subnet format: ${subnet}"

  echo "${a}.${b}.255.200-${a}.${b}.255.250"
}

render_ippool_yaml() {
  local pool="$1"
  sed "s/{{POOL}}/${pool}/g" "${ROOT_DIR}/scripts/metallb/ippool.yaml.tmpl"
}

wait_ready() {
  local ns="$1"
  local sel="$2"
  echo "[+] Waiting for pods in ${ns} (${sel})"
  kubectl -n "${ns}" wait --for=condition=Ready pod -l "${sel}" --timeout=180s
}

metallb_install() {
  echo "[+] Installing MetalLB ${METALLB_VERSION}"
  kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  wait_ready "${METALLB_NS}" "app=metallb"
}

metallb_configure() {
  local pool="$1"
  echo "[+] Configuring MetalLB address pool: ${pool}"
  render_ippool_yaml "${pool}" | kubectl apply -f -
  kubectl apply -f "${ROOT_DIR}/scripts/metallb/l2adv.yaml"
}

kind_up() {
  echo "[+] Creating kind cluster '${CLUSTER_NAME}'"
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    echo "[=] kind cluster already exists: ${CLUSTER_NAME}"
    return 0
  fi

  if [[ -n "${KIND_CONFIG:-}" ]]; then
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  else
    cat <<'EOF' > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
    kind create cluster --name "${CLUSTER_NAME}" --config /tmp/kind-config.yaml
    rm -f /tmp/kind-config.yaml
  fi
}

kind_down() {
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    echo "[+] Deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "${CLUSTER_NAME}"
  else
    echo "[=] kind cluster not found: ${CLUSTER_NAME}"
  fi
}

lb_smoketest() {
  echo "[+] Running LoadBalancer smoke test"
  kubectl create ns jepk8s-smoke --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n jepk8s-smoke apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
EOF

  echo "[+] Waiting for external IP allocation"
  local ip=""
  for _ in {1..60}; do
    ip="$(kubectl -n jepk8s-smoke get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "[+] Got LoadBalancer IP: ${ip}"
      break
    fi
    sleep 2
  done
  [[ -n "${ip}" ]] || die "Timed out waiting for LoadBalancer IP. Check logs: kubectl -n ${METALLB_NS} logs -l app=metallb --all-containers"

  sleep 5  # wait a bit for nginx to be ready

  echo "[+] Curling nginx via ${ip}"
  curl -fsS "http://${ip}" >/dev/null || die "Smoke test failed: curl http://${ip} did not succeed."
  echo "[+] Smoke test passed."
}

status() {
  ensure_tools
  echo "[*] kind clusters:"
  kind get clusters || true
  echo
  echo "[*] MetalLB pods:"
  kubectl -n "${METALLB_NS}" get pods -o wide 2>/dev/null || true
  echo
  echo "[*] Services in smoke namespace:"
  kubectl -n jepk8s-smoke get svc 2>/dev/null || true
}

up() {
  ensure_tools
  kind_up
  kubectl cluster-info >/dev/null

  metallb_install
  local pool
  pool="$(detect_metallb_pool)"
  metallb_configure "${pool}"
  lb_smoketest
  echo "[+] Cluster ready."
}

down() { ensure_tools; kind_down; }

cmd="${1:-}"
case "${cmd}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "Usage: $0 {up|down|status}" >&2; exit 2 ;;
esac
