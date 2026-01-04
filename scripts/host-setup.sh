#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/versions.env"

: "${KUBECTL_VERSION:=${KUBECTL_VERSION}}"
: "${HELM_VERSION:=${HELM_VERSION}}"
: "${KIND_VERSION:=${KIND_VERSION}}"
: "${JAVA_PACKAGE:=${JAVA_PACKAGE}}"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

require_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "[+] Updating apt indexes"
${SUDO} apt-get update -y

echo "[+] Installing base dependencies"
${SUDO} apt-get install -y --no-install-recommends   ca-certificates curl gnupg lsb-release   git jq unzip socat conntrack iptables   apt-transport-https

install_docker() {
  if require_cmd docker; then
    echo "[=] Docker already installed: $(docker --version)"
    return
  fi

  echo "[+] Installing Docker Engine (docker-ce)"
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg

  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  ARCH="$(dpkg --print-architecture)"

  cat <<EOF | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y --no-install-recommends     docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ${SUDO} systemctl enable --now docker || true

  echo "[+] Docker installed: $(docker --version)"
}

install_kubectl() {
  if require_cmd kubectl; then
    echo "[=] kubectl already installed: $(kubectl version --client=true --short 2>/dev/null || true)"
    return
  fi
  echo "[+] Installing kubectl ${KUBECTL_VERSION}"
  ARCH="$(dpkg --print-architecture)"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  ${SUDO} install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
}

install_helm() {
  if require_cmd helm; then
    echo "[=] helm already installed: $(helm version 2>/dev/null || true)"
    return
  fi
  echo "[+] Installing helm ${HELM_VERSION}"
  ARCH="$(dpkg --print-architecture)"
  TMPDIR="$(mktemp -d)"
  curl -fsSL -o "${TMPDIR}/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  tar -C "${TMPDIR}" -xzf "${TMPDIR}/helm.tgz"
  ${SUDO} install -m 0755 "${TMPDIR}/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${TMPDIR}"
}

install_kind() {
  if require_cmd kind; then
    echo "[=] kind already installed: $(kind version 2>/dev/null || true)"
    return
  fi
  echo "[+] Installing kind ${KIND_VERSION}"
  ARCH="$(dpkg --print-architecture)"
  curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  ${SUDO} install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
}

install_java_lein() {
  if ! require_cmd java; then
    echo "[+] Installing Java (${JAVA_PACKAGE})"
    ${SUDO} apt-get install -y --no-install-recommends "${JAVA_PACKAGE}"
  else
    echo "[=] Java already installed: $(java -version 2>&1 | head -n 1 || true)"
  fi

  if ! require_cmd lein; then
    echo "[+] Installing Leiningen"
    curl -fsSL -o /tmp/lein https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein
    ${SUDO} install -m 0755 /tmp/lein /usr/local/bin/lein
    rm -f /tmp/lein
  else
    echo "[=] Leiningen already installed: $(lein version 2>/dev/null || true)"
  fi

  echo "[+] Priming lein (self-install)"
  lein version >/dev/null
}

echo "[*] Starting host setup"
install_docker
install_kubectl
install_helm
install_kind
install_java_lein

echo "[+] Done."
echo "    - Docker: $(docker --version 2>/dev/null || true)"
echo "    - kubectl: $(kubectl version --client=true --short 2>/dev/null || true)"
echo "    - helm: $(helm version 2>/dev/null || true)"
echo "    - kind: $(kind version 2>/dev/null || true)"
echo "    - java: $(java -version 2>&1 | head -n 1 || true)"
echo "    - lein: $(lein version 2>/dev/null || true)"
