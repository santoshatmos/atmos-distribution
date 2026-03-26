#!/usr/bin/env bash
set -euo pipefail

# vps-deploy.sh - ATMOS Production VPS One-Click Deployer
#
# Versioned release layout (Capistrano-style):
#   /opt/atmos/
#   ├── releases/
#   │   ├── v1.0.0/
#   │   └── v1.0.1/
#   ├── current -> releases/v1.0.1   (symlink, atomic switch)
#   ├── shared/
#   │   ├── .env
#   │   ├── .atmos/
#   │   ├── .atmos_installed
#   │   ├── acme/
#   │   └── nginx/ssl/
#   └── scripts/
#
# Usage (first-time install or upgrade - auto-detected):
#   curl -fsSL https://raw.githubusercontent.com/santoshatmos/atmos-distribution/main/scripts/vps-deploy.sh | bash
#
# Usage (with specific version):
#   ATMOS_VERSION=v1.0.0 curl -fsSL ... | bash
#
# Rollback to previous version:
#   curl -fsSL ... | bash -s -- --rollback
#
# Environment variables:
#   ATMOS_VERSION          - Release tag to deploy (default: latest)
#   ATMOS_INSTALL_ROOT     - Installation directory (default: /opt/atmos)
#   ATMOS_RELEASE_BASE_URL - Override base URL for release artifacts
#   ATMOS_KEEP_RELEASES    - Number of old releases to keep (default: 3)

DIST_REPO_OWNER="${ATMOS_RELEASE_REPO_OWNER:-santoshatmos}"
DIST_REPO_NAME="${ATMOS_RELEASE_REPO_NAME:-atmos-distribution}"
ATMOS_RELEASE_BASE_URL="${ATMOS_RELEASE_BASE_URL:-}"
SCRIPT_URL="https://raw.githubusercontent.com/${DIST_REPO_OWNER}/${DIST_REPO_NAME}/main/scripts/vps-deploy.sh"
VERSION="${ATMOS_VERSION:-latest}"
INSTALL_ROOT="${ATMOS_INSTALL_ROOT:-/opt/atmos}"
RELEASES_DIR="$INSTALL_ROOT/releases"
SHARED_DIR="$INSTALL_ROOT/shared"
CURRENT_LINK="$INSTALL_ROOT/current"
KEEP_RELEASES="${ATMOS_KEEP_RELEASES:-3}"

# Shared items: paths relative to a release dir -> shared dir
# Format: <relative_path_in_release>:<relative_path_in_shared>
SHARED_ITEMS=(
  ".env:.env"
  ".atmos:.atmos"
  ".atmos_installed:.atmos_installed"
  "acme:acme"
  "nginx/ssl:nginx/ssl"
)

MODE=""   # auto-detected below

log()  { echo "[atmos-deploy] $*"; }
err()  { echo "[atmos-deploy] ERROR: $*" >&2; }
warn() { echo "[atmos-deploy] WARN: $*" >&2; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade)   MODE="upgrade"; shift ;;
    --install)   MODE="install"; shift ;;
    --rollback)  MODE="rollback"; shift ;;
    --version)   VERSION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--install|--upgrade|--rollback] [--version vX.Y.Z]"
      echo ""
      echo "Mode is auto-detected from the state marker file if not specified."
      echo ""
      echo "Options:"
      echo "  --install    Force fresh install"
      echo "  --upgrade    Force upgrade (preserves .env, SSL, volumes)"
      echo "  --rollback   Revert to the previous release"
      echo "  --version    Specify release version (default: latest)"
      echo ""
      echo "Environment:"
      echo "  ATMOS_VERSION            Release tag (default: latest)"
      echo "  ATMOS_INSTALL_ROOT       Install directory (default: /opt/atmos)"
      echo "  ATMOS_RELEASE_BASE_URL   Override artifact base URL"
      echo "  ATMOS_KEEP_RELEASES      Old releases to retain (default: 3)"
      exit 0
      ;;
    *) err "Unknown arg: $1"; exit 2 ;;
  esac
done

# Auto-detect mode
if [[ -z "$MODE" ]]; then
  if [[ -L "$CURRENT_LINK" ]]; then
    MODE="upgrade"
    log "Versioned layout detected - upgrade mode"
  elif [[ -f "$INSTALL_ROOT/.atmos_installed" && ! -d "$RELEASES_DIR" ]]; then
    MODE="install"
    log "Legacy flat layout detected - will wipe and do fresh versioned install"
  else
    MODE="install"
    log "No existing installation found - fresh install mode"
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

ensure_sudo_ready() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    err "This operation requires root privileges but sudo is not available."
    exit 1
  fi
  echo ""
  echo "=============================================================="
  echo "  ATTENTION: SUDO PASSWORD REQUIRED"
  echo "  ATMOS needs elevated privileges to write under: $INSTALL_ROOT"
  echo "=============================================================="
  echo ""
  # Prompt once early to make UX explicit and avoid surprise during file copy.
  sudo -v
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

  sudo_cmd mkdir -p "$wrapper_dir"
  sudo_cmd tee "$wrapper_path" > /dev/null <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_URL="${ATMOS_RELEASE_SCRIPT_URL:-https://raw.githubusercontent.com/santoshatmos/atmos-distribution/main/scripts/vps-deploy.sh}"
curl -fsSL --retry 3 --connect-timeout 10 "$SCRIPT_URL" | bash -s -- "$@"
WRAPPER
  sudo_cmd chmod +x "$wrapper_path" 2>/dev/null || true
}

# Compute relative path from $1 to $2
relpath() {
  python3 -c "import os.path; print(os.path.relpath('$2','$1'))" 2>/dev/null \
    || python -c "import os.path; print os.path.relpath('$2','$1')" 2>/dev/null \
    || echo "$2"
}

# Create symlinks from release dir to shared dir for persistent data
link_shared_into_release() {
  local release_dir="$1"
  local item rel_path shared_path parent_dir target
  for item in "${SHARED_ITEMS[@]}"; do
    rel_path="${item%%:*}"
    shared_path="$SHARED_DIR/${item##*:}"
    local dest="$release_dir/$rel_path"
    parent_dir="$(dirname "$dest")"
    sudo_cmd mkdir -p "$parent_dir"
    # Remove any existing file/dir at destination (from tarball) so symlink succeeds
    if [[ -e "$dest" && ! -L "$dest" ]]; then
      sudo_cmd rm -rf "$dest"
    fi
    target="$(relpath "$parent_dir" "$shared_path")"
    sudo_cmd ln -sfn "$target" "$dest"
  done
}

# Wipe legacy flat layout before fresh versioned install
wipe_legacy_flat_layout() {
  log "Removing legacy flat layout at $INSTALL_ROOT..."
  # Stop running containers first if docker-compose exists
  if [[ -f "$INSTALL_ROOT/docker-compose.yml" ]]; then
    (cd "$INSTALL_ROOT" && docker compose down 2>/dev/null) || true
  fi
  sudo_cmd rm -rf "$INSTALL_ROOT"
  sudo_cmd mkdir -p "$INSTALL_ROOT"
  log "Legacy layout removed. Starting fresh versioned install."
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
# Step 4: Extract and install (versioned)
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

  # --- Wipe legacy flat layout if detected ---
  if [[ ! -d "$RELEASES_DIR" && -f "$INSTALL_ROOT/.atmos_installed" ]]; then
    wipe_legacy_flat_layout
  fi

  # --- Ensure directory structure ---
  sudo_cmd mkdir -p "$RELEASES_DIR" "$SHARED_DIR" "$SHARED_DIR/nginx"

  # --- Deploy release to releases/<version>/ ---
  local release_dir="$RELEASES_DIR/$VERSION"
  if [[ -d "$release_dir" ]]; then
    log "Removing existing release directory: $release_dir"
    sudo_cmd rm -rf "$release_dir"
  fi
  sudo_cmd cp -a "$inner_dir" "$release_dir"
  log "Release extracted to: $release_dir"

  # --- Initialize shared dir from first install ---
  # Move any persistent data from the release into shared (first install only)
  for item in "${SHARED_ITEMS[@]}"; do
    local rel_path="${item%%:*}"
    local shared_sub="${item##*:}"
    local src="$release_dir/$rel_path"
    local dst="$SHARED_DIR/$shared_sub"
    if [[ -e "$src" && ! -L "$src" && ! -e "$dst" ]]; then
      sudo_cmd mkdir -p "$(dirname "$dst")"
      sudo_cmd mv "$src" "$dst"
    fi
  done
  # Ensure shared .env exists on first install. Some release bundles only include
  # .env.example, while current/.env is symlinked to shared/.env.
  if [[ ! -e "$SHARED_DIR/.env" ]]; then
    if [[ -f "$release_dir/.env" ]]; then
      sudo_cmd cp -a "$release_dir/.env" "$SHARED_DIR/.env"
    elif [[ -f "$release_dir/.env.example" ]]; then
      sudo_cmd cp -a "$release_dir/.env.example" "$SHARED_DIR/.env"
    fi
  fi
  # Ensure shared state dirs exist
  sudo_cmd mkdir -p "$SHARED_DIR/.atmos/cache" "$SHARED_DIR/.atmos/presets" 2>/dev/null || true

  # --- Symlink shared data into release ---
  link_shared_into_release "$release_dir"

  # --- Ensure binaries are executable ---
  for bin in start.sh install.sh deploy.sh start-stack.sh launcher/atmos-launcher agent/atmos-agent; do
    sudo_cmd chmod +x "$release_dir/$bin" 2>/dev/null || true
  done

  # --- Atomic switch: update current symlink ---
  local prev_target=""
  if [[ -L "$CURRENT_LINK" ]]; then
    prev_target="$(readlink "$CURRENT_LINK")"
  fi
  sudo_cmd ln -sfn "releases/$VERSION" "$CURRENT_LINK"
  log "Switched current -> releases/$VERSION"
  if [[ -n "$prev_target" ]]; then
    log "Previous release: $prev_target"
  fi

  # --- Cleanup temp (may contain root-owned files) ---
  sudo_cmd rm -rf "$tmp_dir"

  # Recreate local wrapper for convenience
  write_local_wrapper

  # --- Prune old releases ---
  prune_old_releases

  log "Files deployed to: $release_dir (current -> releases/$VERSION)"
}

# =============================================================================
# Step 4b: Prune old releases
# =============================================================================
prune_old_releases() {
  local count current_target
  current_target="$(readlink "$CURRENT_LINK" 2>/dev/null | sed 's|^releases/||' || true)"
  count=0
  # List releases by modification time (newest first), skip current
  while IFS= read -r dir; do
    local base="$(basename "$dir")"
    [[ "$base" == "$current_target" ]] && continue
    count=$((count + 1))
    if (( count > KEEP_RELEASES )); then
      log "Pruning old release: $base"
      sudo_cmd rm -rf "$dir"
    fi
  done < <(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null || true)
}

# =============================================================================
# Step 4c: Rollback
# =============================================================================
do_rollback() {
  if [[ ! -L "$CURRENT_LINK" ]]; then
    err "No current symlink found. Cannot rollback."
    exit 1
  fi
  local current_target
  current_target="$(readlink "$CURRENT_LINK" | sed 's|^releases/||')"
  log "Current release: $current_target"

  # Find previous release (second newest by mtime)
  local prev_release=""
  while IFS= read -r dir; do
    local base="$(basename "$dir")"
    [[ "$base" == "$current_target" ]] && continue
    prev_release="$base"
    break
  done < <(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null)

  if [[ -z "$prev_release" ]]; then
    err "No previous release found to rollback to."
    exit 1
  fi

  log "Rolling back: $current_target -> $prev_release"
  sudo_cmd ln -sfn "releases/$prev_release" "$CURRENT_LINK"

  # Update state marker
  local marker="$SHARED_DIR/.atmos_installed"
  sudo_cmd tee "$marker" > /dev/null <<EOF
# ATMOS installation state marker - DO NOT DELETE
version=$prev_release
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
rollback_from=$current_target
EOF
  sudo_cmd tee "$SHARED_DIR/.atmos/version" > /dev/null <<< "$prev_release"

  log "Rollback complete. Restarting services..."
  (cd "$CURRENT_LINK" && docker compose up -d --force-recreate)
  echo ""
  echo "========================================="
  echo "  ATMOS rolled back to $prev_release"
  echo "========================================="
  echo ""
}

# =============================================================================
# Step 5: Post-install
# =============================================================================
post_install() {
  # Record version in shared dir
  sudo_cmd tee "$SHARED_DIR/.atmos/version" > /dev/null <<< "$VERSION"

  # Write state marker (enables auto-detection on next run)
  local marker="$SHARED_DIR/.atmos_installed"
  sudo_cmd tee "$marker" > /dev/null <<EOF
# ATMOS installation state marker - DO NOT DELETE
version=$VERSION
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  echo ""
  echo "========================================="
  echo "  ATMOS $VERSION deployed to $INSTALL_ROOT"
  echo "  Mode: $MODE"
  echo "  Layout: versioned (current -> releases/$VERSION)"
  echo "========================================="
  echo ""

  # List available releases
  echo "Available releases:"
  for d in "$RELEASES_DIR"/*/; do
    local v="$(basename "$d")"
    if [[ "$v" == "$VERSION" ]]; then
      echo "  * $v  (active)"
    else
      echo "    $v"
    fi
  done
  echo ""

  if [[ "$MODE" == "upgrade" ]]; then
    echo "Upgrade complete. ATMOS will restart now."
    echo ""
    echo "To rollback:  curl -fsSL $SCRIPT_URL | bash -s -- --rollback"
    echo "To upgrade:   curl -fsSL $SCRIPT_URL | bash"
    echo ""
  else
    echo "Install complete. ATMOS will start now."
    echo ""
    echo "Operations:"
    echo "  cd $CURRENT_LINK"
    echo "  ./start.sh status    # System overview"
    echo "  ./start.sh health    # Container health"
    echo "  ./start.sh logs core # Stream engine logs"
    echo "  ./start.sh repair    # Restart stopped containers"
    echo ""
    echo "To upgrade later:  curl -fsSL $SCRIPT_URL | bash"
    echo "To rollback:       curl -fsSL $SCRIPT_URL | bash -s -- --rollback"
  fi
  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  if [[ "$MODE" == "rollback" ]]; then
    log "=== ATMOS VPS Deployer (mode=rollback) ==="
    log ""
    do_rollback
    exit 0
  fi

  log "=== ATMOS VPS Deployer (mode=$MODE) ==="
  log ""

  install_dependencies
  ensure_sudo_ready
  resolve_version
  download_release
  extract_and_install "$TARBALL_PATH" "$TEMP_DIR"
  post_install

  log "Starting ATMOS from ${CURRENT_LINK}..."
  (cd "$CURRENT_LINK" && ATMOS_INSTALL_REEXEC=1 ./start.sh)
}

main "$@"
