#!/usr/bin/env bash
set -euo pipefail

# vps-deploy.sh - ATMOS Production VPS One-Click Deployer
#
# Purpose:
# - Install all dependencies on a fresh Ubuntu 22.04+ VPS
# - Download the deployment tarball from a PUBLIC distribution repo
# - Extract to /opt/atmos and start the installer
# - Automatically detect install vs upgrade via state marker file
#
# Usage (first-time install or upgrade - auto-detected):
#   curl -fsSL https://raw.githubusercontent.com/santoshatmos/atmos-distribution/main/scripts/vps-deploy.sh | bash
#
# Usage (with specific version):
#   ATMOS_VERSION=v1.0.0 curl -fsSL https://raw.githubusercontent.com/santoshatmos/atmos-distribution/main/scripts/vps-deploy.sh | bash
#
# Environment variables:
#   ATMOS_VERSION          - Release tag to deploy (default: latest)
#   ATMOS_INSTALL_ROOT     - Installation directory (default: /opt/atmos)
#   ATMOS_RELEASE_BASE_URL - Override base URL for release artifacts

DIST_REPO_OWNER="${ATMOS_RELEASE_REPO_OWNER:-santoshatmos}"
DIST_REPO_NAME="${ATMOS_RELEASE_REPO_NAME:-atmos-distribution}"
ATMOS_RELEASE_BASE_URL="${ATMOS_RELEASE_BASE_URL:-}"
SCRIPT_URL="https://raw.githubusercontent.com/${DIST_REPO_OWNER}/${DIST_REPO_NAME}/main/scripts/vps-deploy.sh"
VERSION="${ATMOS_VERSION:-latest}"
INSTALL_ROOT="${ATMOS_INSTALL_ROOT:-/opt/atmos}"
STATE_MARKER="$INSTALL_ROOT/.atmos_installed"

MODE=""   # auto-detected below

log()  { echo "[atmos-deploy] $*"; }
err()  { echo "[atmos-deploy] ERROR: $*" >&2; }
warn() { echo "[atmos-deploy] WARN: $*" >&2; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade)   MODE="upgrade"; shift ;;
    --install)   MODE="install"; shift ;;
    --version)   VERSION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--install|--upgrade] [--version vX.Y.Z]"
      echo ""
      echo "Mode is auto-detected from the state marker file if not specified."
      echo ""
      echo "Options:"
      echo "  --install    Force fresh install"
      echo "  --upgrade    Force upgrade (preserves .env, SSL, volumes)"
      echo "  --version    Specify release version (default: latest)"
      echo ""
      echo "Environment:"
      echo "  ATMOS_VERSION            Release tag (default: latest)"
      echo "  ATMOS_INSTALL_ROOT       Install directory (default: /opt/atmos)"
      echo "  ATMOS_RELEASE_BASE_URL   Override artifact base URL"
      exit 0
      ;;
    *) err "Unknown arg: $1"; exit 2 ;;
  esac
done

# Auto-detect mode from state marker
if [[ -z "$MODE" ]]; then
  if [[ -f "$STATE_MARKER" ]]; then
    MODE="upgrade"
    log "State marker found ($STATE_MARKER) - upgrade mode"
  else
    MODE="install"
    log "No state marker found - fresh install mode"
  fi
fi

# Require root or sudo
sudo_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    err "This operation requires root privileges but sudo is not available."
    exit 1
  fi
}

validate_tarball() {
  local tarball="$1"
  if [[ ! -s "$tarball" ]]; then
    err "Downloaded tarball is missing or empty: $tarball"
    exit 1
  fi
  if ! tar -tzf "$tarball" >/dev/null 2>&1; then
    err "Downloaded tarball failed integrity check: $tarball"
    exit 1
  fi
}

write_local_wrapper() {
  local wrapper_dir="$INSTALL_ROOT/scripts"
  local wrapper_path="$wrapper_dir/vps-deploy.sh"

  mkdir -p "$wrapper_dir"
  cat > "$wrapper_path" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_URL="${ATMOS_RELEASE_SCRIPT_URL:-https://raw.githubusercontent.com/santoshatmos/atmos-distribution/main/scripts/vps-deploy.sh}"
curl -fsSL --retry 3 --connect-timeout 10 "$SCRIPT_URL" | bash -s -- "$@"
WRAPPER
  chmod +x "$wrapper_path" 2>/dev/null || true
}

# =============================================================================
# Step 1: Install system dependencies
# =============================================================================
install_dependencies() {
  log "Checking system dependencies..."

  if ! command -v curl >/dev/null 2>&1; then
    log "Installing curl..."
    sudo_cmd apt-get update -qq
    sudo_cmd apt-get install -y -qq curl
  fi

  if ! command -v tar >/dev/null 2>&1; then
    log "Installing tar..."
    sudo_cmd apt-get update -qq
    sudo_cmd apt-get install -y -qq tar
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    curl -fsSL --retry 3 --connect-timeout 10 https://get.docker.com | sudo_cmd sh
    if [[ $EUID -ne 0 ]]; then
      sudo_cmd usermod -aG docker "$USER" || true
    fi
  fi

  # Ensure Docker is running
  if ! docker version >/dev/null 2>&1; then
    log "Starting Docker daemon..."
    if command -v systemctl >/dev/null 2>&1; then
      sudo_cmd systemctl enable docker || true
      sudo_cmd systemctl start docker || true
    else
      sudo_cmd service docker start || true
    fi
  fi

  # Check Docker Compose
  if ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Compose plugin..."
    sudo_cmd apt-get update -qq
    sudo_cmd apt-get install -y -qq docker-compose-plugin
  fi

  log "Dependencies OK: curl, tar, docker, docker compose"
}

# =============================================================================
# Step 2: Resolve release version
# =============================================================================
resolve_version() {
  if [[ "$VERSION" == "latest" ]]; then
    log "Resolving latest version from distribution repo..."

    # Primary: read VERSION file from distribution repo (fast, no API rate limit)
    local version_url="https://raw.githubusercontent.com/${DIST_REPO_OWNER}/${DIST_REPO_NAME}/main/releases/latest/VERSION"
    local tag
    tag="$(curl -fsSL --retry 2 --connect-timeout 10 "$version_url" 2>/dev/null | tr -d '[:space:]' || true)"

    # Fallback: GitHub API
    if [[ -z "$tag" ]]; then
      log "VERSION file not available, falling back to GitHub API..."
      local api_url="https://api.github.com/repos/${DIST_REPO_OWNER}/${DIST_REPO_NAME}/releases/latest"
      tag="$(curl -fsSL --retry 2 --connect-timeout 10 "$api_url" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    fi

    if [[ -z "$tag" ]]; then
      err "Failed to resolve latest release version."
      err "Set ATMOS_VERSION explicitly:"
      err "  ATMOS_VERSION=v1.0.0 curl -fsSL $SCRIPT_URL | bash"
      exit 1
    fi
    VERSION="$tag"
  fi

  # Build download base URL if not overridden.
  # GitHub Releases download URL pattern:
  #   https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>
  if [[ -z "$ATMOS_RELEASE_BASE_URL" ]]; then
    ATMOS_RELEASE_BASE_URL="https://github.com/${DIST_REPO_OWNER}/${DIST_REPO_NAME}/releases/download/${VERSION}"
  fi

  log "Target version: $VERSION"
  log "Artifact URL:   ${ATMOS_RELEASE_BASE_URL}/atmos-deploy.tar.gz"
}

# =============================================================================
# Step 3: Download release tarball
# =============================================================================
download_release() {
  local tarball_name="atmos-deploy.tar.gz"
  local download_url="${ATMOS_RELEASE_BASE_URL%/}/${tarball_name}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local tarball_path="$tmp_dir/$tarball_name"

  log "Downloading ${tarball_name} ..."
  local attempt
  for attempt in 1 2 3; do
    if curl -fL --retry 3 --connect-timeout 10 \
      --max-time 300 \
      -o "$tarball_path" \
      "$download_url" 2>/dev/null; then

      validate_tarball "$tarball_path"
      log "Download OK ($(du -h "$tarball_path" | cut -f1))"
      TARBALL_PATH="$tarball_path"
      TEMP_DIR="$tmp_dir"
      return 0
    fi

    warn "Download attempt $attempt failed, retrying in $((attempt * 3))s..."
    sleep "$((attempt * 3))"
  done

  err "Failed to download release tarball from: $download_url"
  err "Verify the release exists at: $ATMOS_RELEASE_BASE_URL"
  rm -rf "$tmp_dir"
  exit 1
}

# =============================================================================
# Step 4: Extract and install
# =============================================================================
extract_and_install() {
  local tarball="$1"
  local tmp_dir="$2"
  local extract_dir="$tmp_dir/extracted"
  mkdir -p "$extract_dir"

  log "Extracting release..."
  tar -xzf "$tarball" -C "$extract_dir"

  # Find the extracted directory (atmos-deploy-vX.Y.Z/)
  local inner_dir
  inner_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  if [[ -z "$inner_dir" ]]; then
    err "Tarball does not contain expected directory structure."
    exit 1
  fi

  # --- Backup critical data on upgrade ---
  local env_backup="" acme_backup="" ssl_backup="" atmos_state_backup=""
  if [[ "$MODE" == "upgrade" ]]; then
    if [[ -f "$INSTALL_ROOT/.env" ]]; then
      env_backup="$tmp_dir/.env.backup"
      if sudo_cmd cp "$INSTALL_ROOT/.env" "$env_backup"; then
        log "Backed up .env"
      else
        warn "Failed to back up .env (continuing)"
        env_backup=""
      fi
    fi
    if [[ -d "$INSTALL_ROOT/acme" ]]; then
      acme_backup="$tmp_dir/acme.backup"
      if sudo_cmd cp -a "$INSTALL_ROOT/acme" "$acme_backup"; then
        log "Backed up acme/ (SSL certificates)"
      else
        warn "Failed to back up acme/ (continuing)"
        acme_backup=""
      fi
    fi
    if [[ -d "$INSTALL_ROOT/nginx/ssl" ]]; then
      ssl_backup="$tmp_dir/ssl.backup"
      if sudo_cmd cp -a "$INSTALL_ROOT/nginx/ssl" "$ssl_backup"; then
        log "Backed up nginx/ssl/"
      else
        warn "Failed to back up nginx/ssl/ (continuing)"
        ssl_backup=""
      fi
    fi
    if [[ -d "$INSTALL_ROOT/.atmos" ]]; then
      atmos_state_backup="$tmp_dir/atmos-state.backup"
      if sudo_cmd cp -a "$INSTALL_ROOT/.atmos" "$atmos_state_backup"; then
        log "Backed up .atmos/ (state)"
      else
        warn "Failed to back up .atmos/ (continuing)"
        atmos_state_backup=""
      fi
    fi
  fi

  # --- Deploy files ---
  sudo_cmd mkdir -p "$INSTALL_ROOT"

  if command -v rsync >/dev/null 2>&1; then
    sudo_cmd rsync -a --delete \
      --exclude '.env' \
      --exclude '.atmos/' \
      --exclude '.atmos_installed' \
      --exclude 'acme/' \
      --exclude 'nginx/ssl/' \
      "$inner_dir/" "$INSTALL_ROOT/"
  else
    if [[ "$MODE" == "upgrade" ]]; then
      local preserved_env=""
      if [[ -f "$INSTALL_ROOT/.env" ]]; then
        preserved_env="$tmp_dir/.env.preserved"
        if ! sudo_cmd cp "$INSTALL_ROOT/.env" "$preserved_env"; then
          warn "Failed to preserve .env before fallback copy (continuing)"
          preserved_env=""
        fi
      fi
    fi
    sudo_cmd cp -a "$inner_dir/." "$INSTALL_ROOT/"
    if [[ "$MODE" == "upgrade" && -n "${preserved_env:-}" && -f "$preserved_env" ]]; then
      sudo_cmd cp -f "$preserved_env" "$INSTALL_ROOT/.env"
    fi
  fi

  # --- Restore backups ---
  if [[ -n "$env_backup" && -f "$env_backup" ]]; then
    sudo_cmd cp -f "$env_backup" "$INSTALL_ROOT/.env"
    log "Restored .env"
  fi
  if [[ -n "${acme_backup:-}" && -d "$acme_backup" ]]; then
    sudo_cmd cp -a "$acme_backup/." "$INSTALL_ROOT/acme/"
    log "Restored acme/"
  fi
  if [[ -n "${ssl_backup:-}" && -d "$ssl_backup" ]]; then
    sudo_cmd cp -a "$ssl_backup/." "$INSTALL_ROOT/nginx/ssl/"
    log "Restored nginx/ssl/"
  fi
  if [[ -n "${atmos_state_backup:-}" && -d "$atmos_state_backup" ]]; then
    sudo_cmd cp -a "$atmos_state_backup/." "$INSTALL_ROOT/.atmos/"
    log "Restored .atmos/"
  fi

  # Ensure binaries are executable
  chmod +x "$INSTALL_ROOT/start.sh" 2>/dev/null || true
  chmod +x "$INSTALL_ROOT/install.sh" 2>/dev/null || true
  chmod +x "$INSTALL_ROOT/deploy.sh" 2>/dev/null || true
  chmod +x "$INSTALL_ROOT/start-stack.sh" 2>/dev/null || true
  chmod +x "$INSTALL_ROOT/launcher/atmos-launcher" 2>/dev/null || true
  chmod +x "$INSTALL_ROOT/agent/atmos-agent" 2>/dev/null || true

  # Ensure state directories exist
  mkdir -p "$INSTALL_ROOT/.atmos/cache" "$INSTALL_ROOT/.atmos/presets" 2>/dev/null || true

  # Cleanup temp
  rm -rf "$tmp_dir"

  # Recreate local wrapper for convenience
  write_local_wrapper

  log "Files deployed to: $INSTALL_ROOT"
}

# =============================================================================
# Step 5: Post-install
# =============================================================================
post_install() {
  # Record version
  echo "$VERSION" > "$INSTALL_ROOT/.atmos/version" 2>/dev/null || true

  # Write state marker (enables auto-detection on next run)
  cat > "$STATE_MARKER" <<EOF
# ATMOS installation state marker - DO NOT DELETE
# Presence of this file tells vps-deploy.sh to run in upgrade mode.
version=$VERSION
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  echo ""
  echo "========================================="
  echo "  ATMOS $VERSION deployed to $INSTALL_ROOT"
  echo "  Mode: $MODE"
  echo "========================================="
  echo ""

  if [[ "$MODE" == "upgrade" ]]; then
    echo "Upgrade complete. ATMOS will restart now."
    echo ""
    echo "To upgrade again later:"
    echo "  curl -fsSL $SCRIPT_URL | bash"
    echo ""
  else
    echo "Install complete. ATMOS will start now."
    echo ""
    echo "Operations:"
    echo "  ./start.sh status    # System overview"
    echo "  ./start.sh health    # Container health"
    echo "  ./start.sh logs core # Stream engine logs"
    echo "  ./start.sh repair    # Restart stopped containers"
    echo ""
    echo "To upgrade later:"
    echo "  curl -fsSL $SCRIPT_URL | bash"
  fi
  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  log "=== ATMOS VPS Deployer (mode=$MODE) ==="
  log ""

  install_dependencies
  resolve_version
  download_release
  extract_and_install "$TARBALL_PATH" "$TEMP_DIR"
  post_install

  log "Starting ATMOS from ${INSTALL_ROOT}..."
  (cd "$INSTALL_ROOT" && ./start.sh)
}

main "$@"
