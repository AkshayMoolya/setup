#!/usr/bin/env bash
# =============================================================================
#  CloudLCMS - one-shot developer machine setup
#
#  Installs everything a blank laptop needs to run CloudLCMS locally:
#    git, GitHub CLI, Node.js 22 (+ grunt-cli, pm2, nodemon, adapt-cli),
#    Python 3.11 (+ a virtualenv with docling, python-pptx, bs4, pillow),
#    MongoDB 8.0, Redis, pandoc, LibreOffice, ImageMagick, Ghostscript,
#    Poppler, ffmpeg, Docker and Claude Code.
#  If it can see an app checkout (the folder this setup/ sits in, or
#  --app-dir), it then installs every npm package (app + the doctocourse
#  sibling repo), writes conf/config.json, builds the frontend and runs
#  install.js. It never clones: copied onto a blank laptop on its own, it
#  sets up the machine and tells you how to finish once the code is there.
#
#  Supported:  Windows 10/11 (Git Bash), macOS (Intel + Apple Silicon),
#              Ubuntu 22.04/24.04 and Debian 12 (incl. WSL2).
#
#  Usage:      bash setup/setup.sh [options]          (see --help)
#  Safe to re-run: every step checks first and skips what is already done.
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------- settings --
NODE_MAJOR=22
PYTHON_VERSION=3.11
MONGO_SERIES=8.0
VENV_DIR="${CLOUDLCMS_VENV:-$HOME/.venvs/cloudlcms}"
APP_DIR=""
NPM_GLOBALS=(grunt-cli pm2 nodemon adapt-cli)

SKIP_SYSTEM=0 SKIP_CLAUDE=0 SKIP_DOCKER=0 SKIP_APP_INSTALL=0 SKIP_BUILD=0 ASSUME_YES=0 VERIFY_ONLY=0

usage() {
  cat <<'USAGE'
Usage: bash setup/setup.sh [options]

  --verify              Only check what is installed; change nothing.
  --app-dir PATH        The CloudLCMS checkout to set up (default: the folder
                        containing this setup/ folder, if it is one).
  --skip-system         Skip OS packages (git, node, python, mongo, ...).
  --skip-claude         Do not install Claude Code.
  --skip-docker         Do not install Docker.
  --skip-build          Do not run `grunt build:dev`.
  --skip-app-install    Do not run `node install.js` (DB, master tenant, super admin).
  -y, --yes             Do not ask questions; take the default answer.
  -h, --help            Show this help.

Environment override: CLOUDLCMS_VENV (python venv dir, default ~/.venvs/cloudlcms).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY_ONLY=1 ;;
    --app-dir) [ $# -ge 2 ] || { echo "--app-dir needs a path" >&2; exit 2; }; APP_DIR="$2"; shift ;;
    --skip-system) SKIP_SYSTEM=1 ;;
    --skip-claude) SKIP_CLAUDE=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-app-install) SKIP_APP_INSTALL=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------ helpers --
if [ -t 1 ]; then
  C_B=$'\033[1m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_C=$'\033[36m' C_0=$'\033[0m'
else
  C_B='' C_G='' C_Y='' C_R='' C_C='' C_0=''
fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s==> [%d] %s%s\n' "$C_B$C_C" "$STEP" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARNINGS+=("$*"); }
die()  { printf '\n%s✗ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
WARNINGS=()

trap 'die "Failed at line $LINENO: $BASH_COMMAND  (fix the cause and re-run; finished steps are skipped)"' ERR

confirm() { # confirm "question" default(Y|N)
  local q="$1" def="${2:-Y}" ans
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then [ "$def" = Y ]; return; fi
  read -r -p "    $q [$( [ "$def" = Y ] && echo Y/n || echo y/N )] " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

port_open() { # port_open host port  (uses bash /dev/tcp, falls back to node)
  (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1 && return 0
  have node && node -e "const s=require('net').connect($2,'$1',()=>process.exit(0));s.on('error',()=>process.exit(1));setTimeout(()=>process.exit(1),2000)" 2>/dev/null
}

wait_port() { # wait_port host port seconds
  local i=0
  while [ $i -lt "$3" ]; do port_open "$1" "$2" && return 0; sleep 1; i=$((i + 1)); done
  return 1
}

# ---------------------------------------------------------------- detect OS --
case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux) OS=linux ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac

if [ "$OS" = linux ]; then
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*) : ;;
    *) die "Only Ubuntu/Debian are automated on Linux (found ${PRETTY_NAME:-unknown}). Follow setup/README.md manually." ;;
  esac
  DISTRO="$ID"; CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
fi

if [ "$OS" = windows ]; then
  have cygpath || die "Run this from Git Bash (it ships cygpath). See setup/README.md."
fi

# Windows: re-read PATH from the registry so tools installed by winget a
# moment ago are visible to this already-running shell.
refresh_path() {
  case "$OS" in
    windows)
      local raw p new="" IFS=';'
      raw="$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')" | tr -d '\r')"
      for p in $raw; do [ -n "$p" ] && new="$new:$(cygpath -u "$p")"; done
      # Append, never prepend: System32 holds WSL's bash.exe and other tools
      # that would shadow Git Bash's own bash/grep/find.
      export PATH="$PATH$new"
      ;;
    mac)
      for p in /opt/homebrew/bin /usr/local/bin; do [ -x "$p/brew" ] && eval "$("$p/brew" shellenv)" && break; done
      have brew && [ -d "$(brew --prefix)/opt/node@$NODE_MAJOR/bin" ] && export PATH="$(brew --prefix)/opt/node@$NODE_MAJOR/bin:$PATH"
      ;;
  esac
  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
  hash -r
}

# Windows: append a directory to the *user* PATH permanently.
add_user_path_windows() {
  local dir="$1"
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "\$d='$dir'; \$p=[Environment]::GetEnvironmentVariable('Path','User'); if (-not \$p) { \$p='' }; if ((\$p -split ';') -notcontains \$d) { [Environment]::SetEnvironmentVariable('Path', ((\$p.TrimEnd(';') + ';' + \$d).TrimStart(';')), 'User'); 'added' }" | tr -d '\r'
}

# mac: make a line part of every new login shell.
persist_profile_line() {
  local line="$1" f
  for f in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    touch "$f"; grep -qxF "$line" "$f" || printf '%s\n' "$line" >> "$f"
  done
}

refresh_path

# =============================================================================
#  System packages
# =============================================================================
winget_install() { # winget_install <id> [extra winget args...]
  local id="$1"; shift
  if winget list --id "$id" --exact --accept-source-agreements >/dev/null 2>&1; then
    ok "$id already installed"; return 0
  fi
  info "installing $id ..."
  if winget install --id "$id" --exact --silent --accept-package-agreements --accept-source-agreements "$@"; then
    ok "$id installed"
  else
    warn "winget could not install $id (exit $?) - install it by hand, then re-run"
  fi
}

install_ghostscript_windows() {
  if ls "/c/Program Files/gs"/*/bin/gswin64c.exe >/dev/null 2>&1; then ok "Ghostscript already installed"; return; fi
  info "Ghostscript is not on winget - downloading the official installer from GitHub ..."
  local url tmp
  url="$(curl -fsSL https://api.github.com/repos/ArtifexSoftware/ghostpdl-downloads/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]*gs[0-9]+w64\.exe"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')" || true
  [ -n "$url" ] || { warn "Could not find the Ghostscript download. Get gs*w64.exe from https://ghostscript.com/releases/gsdnld.html"; return; }
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/gs-setup.exe" "$url"
  info "running the Ghostscript installer (accept the Windows admin prompt) ..."
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "Start-Process -FilePath '$(cygpath -w "$tmp/gs-setup.exe")' -ArgumentList '/S' -Verb RunAs -Wait"
  rm -rf "$tmp"
  ls "/c/Program Files/gs"/*/bin/gswin64c.exe >/dev/null 2>&1 && ok "Ghostscript installed" || warn "Ghostscript install did not complete"
}

install_system_windows() {
  have winget || die "winget is missing. Install 'App Installer' from the Microsoft Store, then re-run."
  info "Windows may show several admin (UAC) prompts - click Yes on each."

  winget_install Git.Git
  winget_install GitHub.cli
  # Two Node MSIs fight over C:\Program Files\nodejs, so keep an existing >= 20.
  if have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then
    ok "node $(node -v) already installed"
  else
    winget_install "OpenJS.NodeJS.$NODE_MAJOR"
  fi
  winget_install "Python.Python.$PYTHON_VERSION"

  # MongoDB: pin the 8.0 series (winget's newest may be a newer major).
  local mver
  mver="$(winget show --id MongoDB.Server --exact --versions --accept-source-agreements 2>/dev/null | tr -d '\r' \
          | awk -v s="$MONGO_SERIES." 'index($0, s) == 1 && $0 ~ /^[0-9.]+$/ { print; exit }')" || true
  if [ -n "$mver" ]; then winget_install MongoDB.Server --version "$mver"; else winget_install MongoDB.Server; fi
  winget_install MongoDB.Shell

  winget_install Memurai.MemuraiDeveloper        # Redis-compatible server for Windows
  winget_install JohnMacFarlane.Pandoc
  winget_install TheDocumentFoundation.LibreOffice
  winget_install ImageMagick.ImageMagick
  winget_install oschwartz10612.Poppler
  winget_install Gyan.FFmpeg
  install_ghostscript_windows

  # doctocourse calls soffice.exe and magick.exe by name, so both must be on PATH.
  local d
  for d in "C:\\Program Files\\LibreOffice\\program"; do
    [ -d "$(cygpath -u "$d")" ] && [ "$(add_user_path_windows "$d")" = added ] && ok "added $d to your PATH"
  done
  for d in /c/Program\ Files/gs/*/bin; do
    [ -d "$d" ] && [ "$(add_user_path_windows "$(cygpath -w "$d")")" = added ] && ok "added $(cygpath -w "$d") to your PATH"
  done

  refresh_path

  # The MongoDB MSI registers a "MongoDB" service; make sure it is running.
  if ! port_open 127.0.0.1 27017; then
    info "starting the MongoDB service ..."
    MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "Start-Process -FilePath sc.exe -ArgumentList 'start MongoDB' -Verb RunAs -Wait" >/dev/null 2>&1 || true
  fi
}

install_system_mac() {
  if ! xcode-select -p >/dev/null 2>&1; then
    info "installing the Xcode Command Line Tools (a dialog will open) ..."
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  fi
  ok "Xcode Command Line Tools present"

  if ! have brew; then
    info "installing Homebrew (it will ask for your Mac password) ..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    refresh_path
    persist_profile_line "eval \"\$($(brew --prefix)/bin/brew shellenv)\""
  fi
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

  brew tap mongodb/brew >/dev/null
  local f
  for f in git gh "node@$NODE_MAJOR" "python@$PYTHON_VERSION" pandoc imagemagick ghostscript poppler ffmpeg redis mongosh "mongodb/brew/mongodb-community@$MONGO_SERIES"; do
    if brew list --formula "${f##*/}" >/dev/null 2>&1; then ok "$f already installed"; else info "brew install $f ..."; brew install "$f"; fi
  done
  if [ -d /Applications/LibreOffice.app ]; then ok "LibreOffice already installed"; else brew install --cask libreoffice; fi

  persist_profile_line "export PATH=\"$(brew --prefix)/opt/node@$NODE_MAJOR/bin:\$PATH\""
  refresh_path

  brew services start "mongodb-community@$MONGO_SERIES" >/dev/null || true
  brew services start redis >/dev/null || true
}

install_system_linux() {
  export DEBIAN_FRONTEND=noninteractive
  info "updating apt (sudo may ask for your password) ..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y build-essential curl wget git gnupg ca-certificates unzip lsb-release \
    "python3" python3-venv python3-pip python3-dev \
    pandoc libreoffice libreoffice-java-common fonts-liberation \
    imagemagick ghostscript poppler-utils ffmpeg redis-server
  [ "$DISTRO" = ubuntu ] && { $SUDO apt-get install -y fonts-ubuntu || true; }

  # Node.js from NodeSource (distro packages are too old).
  if ! have node || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | $SUDO -E bash -
    $SUDO apt-get install -y nodejs
  fi
  ok "node $(node -v)"

  # GitHub CLI
  if ! have gh; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update -y && $SUDO apt-get install -y gh
  fi

  # MongoDB 8.0 from mongodb.org
  if ! have mongod; then
    local repo
    curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_SERIES}.asc" | $SUDO gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg"
    if [ "$DISTRO" = debian ]; then
      repo="deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGO_SERIES} main"
    else
      case "$CODENAME" in focal|jammy|noble) : ;; *) CODENAME=noble ;; esac
      repo="deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/${MONGO_SERIES} multiverse"
    fi
    echo "$repo" | $SUDO tee "/etc/apt/sources.list.d/mongodb-org-${MONGO_SERIES}.list" >/dev/null
    $SUDO apt-get update -y && $SUDO apt-get install -y mongodb-org
  fi
  ok "mongod $(mongod --version | head -1 | awk '{print $3}')"

  # ImageMagick ships with PDF reading disabled; slide rendering needs it.
  local pol
  for pol in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml; do
    [ -f "$pol" ] && $SUDO sed -i 's|<policy domain="coder" rights="none" pattern="PDF" />|<policy domain="coder" rights="read\|write" pattern="PDF" />|' "$pol"
  done

  # Services (WSL without systemd gets a plain background start instead).
  if [ -d /run/systemd/system ]; then
    $SUDO systemctl enable --now mongod redis-server
  else
    port_open 127.0.0.1 6379 || $SUDO service redis-server start || true
    if ! port_open 127.0.0.1 27017; then
      $SUDO mkdir -p /var/lib/mongodb /var/log/mongodb
      $SUDO mongod --dbpath /var/lib/mongodb --logpath /var/log/mongodb/mongod.log --fork --bind_ip 127.0.0.1 || true
      warn "No systemd: MongoDB was started by hand. After a reboot run: sudo mongod --dbpath /var/lib/mongodb --logpath /var/log/mongodb/mongod.log --fork"
    fi
  fi
}

# =============================================================================
#  Docker
# =============================================================================
install_docker_windows() {
  # Docker Desktop runs its engine inside WSL 2.
  if ! wsl.exe --status >/dev/null 2>&1; then
    info "enabling WSL 2 for Docker Desktop (accept the admin prompt) ..."
    MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command "Start-Process -FilePath wsl.exe -ArgumentList '--install --no-distribution' -Verb RunAs -Wait" || true
    warn "WSL 2 was just enabled - REBOOT Windows before you start Docker Desktop"
  fi
  winget_install Docker.DockerDesktop
  info "start Docker Desktop once from the Start menu and accept its terms; the engine runs while it is open"
}

install_docker_mac() {
  if [ -d /Applications/Docker.app ]; then ok "Docker Desktop already installed"; return; fi
  brew install --cask docker-desktop 2>/dev/null || brew install --cask docker
  info "open Docker from Applications once and accept its terms; the engine runs while it is open"
}

install_docker_linux() {
  if ! have docker; then
    local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO $codename stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if [ -d /run/systemd/system ]; then $SUDO systemctl enable --now docker; else $SUDO service docker start || true; fi
  if [ "$(id -u)" -ne 0 ] && ! id -nG "$USER" | grep -qw docker; then
    $SUDO usermod -aG docker "$USER"
    warn "added $USER to the 'docker' group - log out and back in to use docker without sudo"
  fi
  ok "docker engine installed"
}

# =============================================================================
#  Verification table (also the --verify mode)
# =============================================================================
version_of() { "$@" 2>&1 | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }

verify_all() {
  local fails=0 py
  row() { # row label status detail
    if [ "$2" = ok ]; then printf '    %s✓%s %-24s %s\n' "$C_G" "$C_0" "$1" "$3"
    else printf '    %s✗%s %-24s %s\n' "$C_R" "$C_0" "$1" "$3"; fails=$((fails + 1)); fi
  }
  check_cmd() { local label="$1"; shift; local c="$1"; shift
    if have "$c"; then row "$label" ok "$(version_of "$c" "$@")"; else row "$label" bad "not found on PATH"; fi; }

  check_cmd git git --version
  check_cmd "GitHub CLI (gh)" gh --version
  check_cmd node node --version
  check_cmd npm npm --version
  local g; for g in grunt pm2 nodemon adapt; do check_cmd "$g (npm -g)" "$g" --version; done
  check_cmd pandoc pandoc --version
  check_cmd ffmpeg ffmpeg -version
  check_cmd "pdfinfo (poppler)" pdfinfo -v
  case "$OS" in
    windows) if have soffice.exe; then row "soffice (LibreOffice)" ok "on PATH"; else row "soffice (LibreOffice)" bad "not on PATH (C:\\Program Files\\LibreOffice\\program)"; fi
             check_cmd "magick (ImageMagick)" magick.exe -version
             if ls "/c/Program Files/gs"/*/bin/gswin64c.exe >/dev/null 2>&1; then row Ghostscript ok "installed"; else row Ghostscript bad "not installed"; fi ;;
    mac)     if [ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]; then row LibreOffice ok "$(version_of /Applications/LibreOffice.app/Contents/MacOS/soffice --version)"; else row LibreOffice bad "not in /Applications"; fi
             check_cmd "convert (ImageMagick)" convert -version
             check_cmd "gs (Ghostscript)" gs --version ;;
    linux)   check_cmd "libreoffice" libreoffice --version
             check_cmd "convert (ImageMagick)" convert -version
             check_cmd "gs (Ghostscript)" gs --version ;;
  esac
  check_cmd mongosh mongosh --version
  check_cmd "claude (Claude Code)" claude --version
  check_cmd docker docker --version
  if have docker; then
    if timeout 20 docker info >/dev/null 2>&1; then row "docker engine" ok "running"
    else row "docker engine" bad "not running (start Docker Desktop / sudo systemctl start docker)"; fi
  fi

  py="$(venv_python)"
  if [ -x "$py" ] || [ -f "$py" ]; then
    if "$py" -c "import bs4, PIL, pptx, docling" >/dev/null 2>&1; then row "python venv + libs" ok "$("$py" --version 2>&1)  ($VENV_DIR)"
    else row "python venv + libs" bad "venv exists but imports fail - re-run setup"; fi
  else row "python venv + libs" bad "no venv at $VENV_DIR"; fi

  if port_open 127.0.0.1 27017; then row "MongoDB :27017" ok "listening"; else row "MongoDB :27017" bad "not running"; fi
  if port_open 127.0.0.1 6379; then row "Redis :6379" ok "listening"; else row "Redis :6379" bad "not running (search indexing only)"; fi

  if [ -n "${REPO_ROOT:-}" ]; then
    [ -d "$REPO_ROOT/node_modules" ] && row "app node_modules" ok "$REPO_ROOT" || row "app node_modules" bad "run npm install"
    [ -d "$DOC_DIR/node_modules" ] && row "doctocourse" ok "$DOC_DIR" || row "doctocourse" bad "missing at $DOC_DIR"
    [ -f "$REPO_ROOT/conf/config.json" ] && row "conf/config.json" ok "present" || row "conf/config.json" bad "missing"
    [ -f "$REPO_ROOT/frontend/src/templates/templates.js" ] && row "frontend build" ok "built" || row "frontend build" bad "run: npx grunt build:dev"
  fi
  return $fails
}

venv_python() {
  if [ "$OS" = windows ]; then echo "$VENV_DIR/Scripts/python.exe"; else echo "$VENV_DIR/bin/python"; fi
}

# =============================================================================
#  Locate the repositories (this script never clones)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
is_app_checkout() { [ -f "$1/package.json" ] && grep -q '"name": *"adapt_authoring"' "$1/package.json"; }
# The app checkout is --app-dir if given, else the folder this setup/ sits in.
# Neither is required: a setup/ folder copied onto a blank laptop on its own
# still sets up the whole machine and skips only the app-specific steps.
REPO_ROOT=""
if [ -n "$APP_DIR" ]; then
  is_app_checkout "$APP_DIR" || die "--app-dir $APP_DIR is not a CloudLCMS checkout (no adapt_authoring package.json there)"
  REPO_ROOT="$(cd "$APP_DIR" && pwd)"
elif is_app_checkout "$SCRIPT_DIR/.."; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
# plugins/output/adapt/{ppt,docx}/index.js require ../../../../../doctocourse,
# so doctocourse must sit NEXT TO the app folder.
DOC_DIR=""
[ -n "$REPO_ROOT" ] && DOC_DIR="$(dirname "$REPO_ROOT")/doctocourse"

if [ "$VERIFY_ONLY" = 1 ]; then
  printf '%sCloudLCMS setup check (%s)%s\n' "$C_B" "$OS" "$C_0"
  if verify_all; then printf '\n%sEverything is in place.%s\n' "$C_G" "$C_0"; exit 0
  else printf '\n%sSome items are missing - run: bash setup/setup.sh%s\n' "$C_Y" "$C_0"; exit 1; fi
fi

printf '%sCloudLCMS developer setup%s  (%s)\n' "$C_B" "$C_0" "$OS"
if [ -n "$REPO_ROOT" ]; then
  info "App checkout: $REPO_ROOT"
  if [ -d "$DOC_DIR" ]; then info "doctocourse:  $DOC_DIR"
  else warn "doctocourse not found at $DOC_DIR - PowerPoint/Word import+export need it there (the rest of setup continues)"; fi
else
  info "No app checkout found - setting up the machine only. After cloning, run this again"
  info "with --app-dir <path to cloudlcms checkout> (or from <checkout>/setup) to finish the app."
fi

# ---------------------------------------------------------------- 1. system --
if [ "$SKIP_SYSTEM" = 0 ]; then
  step "System packages (git, gh, Node.js $NODE_MAJOR, Python $PYTHON_VERSION, MongoDB $MONGO_SERIES, Redis, pandoc, LibreOffice, ImageMagick, Ghostscript, Poppler, ffmpeg)"
  "install_system_$OS"
else
  step "System packages - skipped (--skip-system)"
fi
refresh_path
have git  || die "git is still not on PATH. Open a new terminal and re-run."
have node || die "node is still not on PATH. Open a new terminal and re-run."
NODE_V="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_V" -ge 20 ] || die "Node $(node -v) is too old; the app needs >= 20 (22 recommended)."
ok "node $(node -v), npm $(npm -v), git $(version_of git --version)"

# ---------------------------------------------------------------- 2. git ----
step "Git configuration"
if [ -z "$(git config --global user.name || true)" ] && [ -t 0 ] && [ "$ASSUME_YES" = 0 ]; then
  read -r -p "    Your name for git commits: " GN; [ -n "$GN" ] && git config --global user.name "$GN"
fi
if [ -z "$(git config --global user.email || true)" ] && [ -t 0 ] && [ "$ASSUME_YES" = 0 ]; then
  read -r -p "    Your email for git commits: " GE; [ -n "$GE" ] && git config --global user.email "$GE"
fi
if [ "$OS" = windows ]; then
  git config --global core.longpaths true      # node_modules + adapt_framework paths exceed 260 chars
  ok "core.longpaths = true"
fi
ok "user: $(git config --global user.name || echo '(unset)') <$(git config --global user.email || echo unset)>"

# ---------------------------------------------------------------- 3. global npm
step "Global npm tools: ${NPM_GLOBALS[*]}"
NPM_G=(npm install -g --no-fund --no-audit)
[ "$OS" = linux ] && [ "$(id -u)" -ne 0 ] && [ "$(npm config get prefix)" = /usr ] && NPM_G=(sudo "${NPM_G[@]}")
missing=()
for t in "${NPM_GLOBALS[@]}"; do
  bin="$t"; [ "$t" = grunt-cli ] && bin=grunt; [ "$t" = adapt-cli ] && bin=adapt
  have "$bin" && ok "$t present" || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then "${NPM_G[@]}" "${missing[@]}"; ok "installed ${missing[*]}"; fi
refresh_path

# ---------------------------------------------------------------- 4. claude -
if [ "$SKIP_CLAUDE" = 0 ]; then
  step "Claude Code"
  if have claude; then
    ok "claude $(version_of claude --version) already installed"
  elif [ "$OS" = windows ]; then
    winget_install Anthropic.ClaudeCode
  else
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  refresh_path
  have claude && ok "run 'claude' in the repo folder and sign in on first use" || warn "claude is not on PATH yet - open a new terminal"
fi

# ---------------------------------------------------------------- 5. docker -
if [ "$SKIP_DOCKER" = 0 ]; then
  step "Docker"
  install_docker_"$OS"
  refresh_path
  if have docker; then ok "docker $(version_of docker --version)"; else warn "docker is not on PATH yet - open a new terminal (Windows/mac: start Docker Desktop once)"; fi
fi

# ---------------------------------------------------------------- 6. python -
step "Python $PYTHON_VERSION virtualenv + libraries (docling, python-pptx, beautifulsoup4, pillow)"
find_base_python() {
  local c
  case "$OS" in
    windows)
      if have py && py "-$PYTHON_VERSION" -c "1" >/dev/null 2>&1; then echo "py -$PYTHON_VERSION"; return; fi
      c="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")/Programs/Python/Python${PYTHON_VERSION/./}/python.exe"
      [ -x "$c" ] && { echo "$c"; return; } ;;
    mac)
      c="$(brew --prefix 2>/dev/null)/opt/python@$PYTHON_VERSION/bin/python$PYTHON_VERSION"
      [ -x "$c" ] && { echo "$c"; return; } ;;
  esac
  for c in "python$PYTHON_VERSION" python3 python; do
    have "$c" && "$c" -c 'import sys; sys.exit(0 if (3,9) <= sys.version_info[:2] <= (3,13) else 1)' 2>/dev/null && { echo "$c"; return; }
  done
  return 1
}
PY="$(venv_python)"
if [ ! -f "$PY" ]; then
  BASE_PY="$(find_base_python)" || die "No Python 3.9-3.13 found. Install Python $PYTHON_VERSION and re-run."
  info "creating venv with: $BASE_PY"
  mkdir -p "$(dirname "$VENV_DIR")"
  # shellcheck disable=SC2086
  $BASE_PY -m venv "$VENV_DIR"
fi
"$PY" -m pip install --quiet --upgrade pip setuptools wheel
if ! "$PY" -c "import torch" >/dev/null 2>&1 && [ "$OS" = linux ]; then
  info "installing CPU-only PyTorch first (avoids a multi-GB CUDA download) ..."
  "$PY" -m pip install --quiet torch torchvision --index-url https://download.pytorch.org/whl/cpu
fi
# doctocourse owns the list; setup/requirements.txt is a pinned copy for when
# that repo is not checked out yet (and for the PDF import's docling scripts).
REQ="$SCRIPT_DIR/requirements.txt"
[ -n "$DOC_DIR" ] && [ -f "$DOC_DIR/requirement.txt" ] && REQ="$DOC_DIR/requirement.txt"
info "pip install -r $REQ  (docling is large - this can take several minutes) ..."
"$PY" -m pip install --quiet -r "$REQ"
"$PY" -c "import bs4, PIL, pptx, docling" || die "The python libraries installed but do not import - see the error above."
ok "python libraries import cleanly ($("$PY" --version 2>&1))"

if [ "$OS" = windows ]; then PYTHON_VAR="$(cygpath -m "$PY")"; else PYTHON_VAR="$PY"; fi

# ---------------------------------------------------------------- 7. services
step "Checking MongoDB and Redis"
if wait_port 127.0.0.1 27017 20; then ok "MongoDB answers on 127.0.0.1:27017"
else warn "MongoDB is not running on 127.0.0.1:27017 - start it (README: Troubleshooting) before running the app"; fi
if port_open 127.0.0.1 6379; then ok "Redis answers on 127.0.0.1:6379"
else warn "Redis is not running on 127.0.0.1:6379 - course search indexing will be unavailable"; fi

# Everything below needs the app source. Without it, stop here cleanly.
if [ -z "$REPO_ROOT" ]; then
  step "App steps (npm install, config, build, install.js) - skipped: no checkout yet"
else

# ---------------------------------------------------------------- 8. npm ----
step "Node packages (app, auth plugins, doctocourse)"
npm_in() {
  local d="$1"
  [ -f "$d/package.json" ] || return 0
  info "npm install in ${d#"$(dirname "$REPO_ROOT")/"} ..."
  # First time: npm ci (exact lockfile). Re-runs: npm install (fast no-op).
  if [ -f "$d/package-lock.json" ] && [ ! -d "$d/node_modules" ]; then
    (cd "$d" && npm ci --no-fund --no-audit --loglevel=error) || (cd "$d" && npm install --no-fund --no-audit --loglevel=error)
  else
    (cd "$d" && npm install --no-fund --no-audit --loglevel=error)
  fi
}
npm_in "$REPO_ROOT"
for p in local google saml; do npm_in "$REPO_ROOT/plugins/auth/$p"; done
npm_in "$DOC_DIR"
ok "node_modules installed"

# ---------------------------------------------------------------- 9. config -
step "Runtime folders + conf/config.json"
mkdir -p "$REPO_ROOT"/{temp,conf,data,logs}
CONFIG="$REPO_ROOT/conf/config.json"
if [ -f "$CONFIG" ]; then
  ok "conf/config.json already exists - left untouched"
  CURRENT_PY="$(node -p "require(process.argv[1]).PYTHON_VAR || ''" "$CONFIG" 2>/dev/null || true)"
  [ "$CURRENT_PY" != "$PYTHON_VAR" ] && warn "conf/config.json has PYTHON_VAR=\"$CURRENT_PY\"; the venv with docling is $PYTHON_VAR"
else
  if [ "$OS" = windows ]; then APP_ROOT="$(cygpath -w "$REPO_ROOT")"; else APP_ROOT="$REPO_ROOT"; fi
  APP_ROOT="$APP_ROOT" PYTHON_VAR="$PYTHON_VAR" node - "$CONFIG" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const config = {
  outputPlugin: "adapt",
  dbType: "mongoose",
  auth: "local",
  root: process.env.APP_ROOT,
  sessionSecret: crypto.randomBytes(64).toString("hex"),
  serverPort: 9080,
  serverName: "localhost",
  dataRoot: "data",
  authoringToolRepository: "https://github.com/adaptlearning/adapt_authoring.git",
  frameworkRepository: "https://github.com/adaptlearning/adapt_framework.git",
  frameworkRevision: "tags/v5.2.0",
  dbName: "cloudlcms",
  shouldDatabaseUseSSL: false,
  useConnectionUri: false,
  dbHost: "127.0.0.1",
  dbPort: 27017,
  dbUser: "",
  dbPass: "",
  dbAuthSource: "",
  useSmtp: false,
  useSmtpConnectionUrl: false,
  fromAddress: "noreply@cloudlcms.com",
  maxLoginAttempts: 3,
  maxFileUploadSize: "800MB",
  masterTenantName: "master",
  isProduction: false,
  PYTHON_VAR: process.env.PYTHON_VAR,
  searchIndexUrl: "redis://127.0.0.1:6379",
  searchIndexPrefix: "adapt",
  searchIndexSyncInterval: "1m",
  searchIndexSyncOnStartup: true,
  searchResultsPerPage: 10,
  enableTenantSettings: true
};
fs.writeFileSync(process.argv[2], JSON.stringify(config, null, 2) + "\n");
NODE
  ok "wrote conf/config.json (db: cloudlcms on 127.0.0.1:27017, port 9080, PYTHON_VAR -> venv)"
fi

# ---------------------------------------------------------------- 10. build -
if [ "$SKIP_BUILD" = 0 ]; then
  step "Building the frontend (grunt build:dev)"
  (cd "$REPO_ROOT" && npx grunt build:dev)
  ok "frontend built (dev mode: isProduction=false, sources served from frontend/src)"
fi

# ---------------------------------------------------------------- 11. install.js
if [ "$SKIP_APP_INSTALL" = 0 ]; then
  step "First-time application install (database, master tenant, super admin, Adapt framework)"
  if node -e "process.exit(require(process.argv[1]).masterTenantID ? 0 : 1)" "$CONFIG" 2>/dev/null; then
    ok "conf/config.json already has a masterTenantID - install.js has run before; skipping"
  elif ! port_open 127.0.0.1 27017; then
    warn "Skipped install.js because MongoDB is not running. Start MongoDB, then: cd \"$REPO_ROOT\" && node install.js"
  elif confirm "Run 'node install.js' now? It asks for the super-admin email + password." Y; then
    info "When asked 'use the values in config.json?' answer  Y"
    # In Git Bash's mintty window node.exe gets no real console, so its prompts
    # (and the hidden password input) misbehave; winpty gives it one.
    RUN_NODE=(node); [ "$OS" = windows ] && [ "${TERM_PROGRAM:-}" = mintty ] && have winpty && RUN_NODE=(winpty node)
    (cd "$REPO_ROOT" && "${RUN_NODE[@]}" install.js) || warn "install.js did not finish - re-run it with: cd \"$REPO_ROOT\" && node install.js"
  else
    info "Later: cd \"$REPO_ROOT\" && node install.js"
  fi
fi

fi # end of app steps (REPO_ROOT set)

# ---------------------------------------------------------------- summary ---
step "Summary"
trap - ERR
verify_all || true

if [ ${#WARNINGS[@]} -gt 0 ]; then
  printf '\n%sWarnings:%s\n' "$C_Y" "$C_0"; for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
fi

if [ -z "$REPO_ROOT" ]; then
cat <<DONE

${C_B}Machine ready. Next steps${C_0}
  1. Open a NEW terminal (so PATH changes apply everywhere).
  2. Clone both repos SIDE BY SIDE into one folder, e.g.:
       mkdir -p ~/dev/cloudlcms && cd ~/dev/cloudlcms
       gh auth login            # once - the repos are private
       git clone https://github.com/SRRInternational/adapt_authoring.git cloudlcms-2025
       git clone https://github.com/SRRInternational/doctocourse.git
  3. Finish the app setup (installed tools are skipped, takes a few minutes):
       bash cloudlcms-2025/setup/setup.sh
     or, with this copy of the folder:
       bash "$SCRIPT_DIR/setup.sh" --app-dir ~/dev/cloudlcms/cloudlcms-2025
DONE
else
cat <<DONE

${C_B}Next steps${C_0}
  1. Open a NEW terminal (so PATH changes apply everywhere).
  2. cd "$REPO_ROOT"
  3. node server.js            # or: npm run debug   (nodemon + inspector)
  4. Browse to http://localhost:9080 and sign in with the super-admin you just created.

  Re-check the machine any time with:  bash setup/setup.sh --verify
  AI/PDF course generation needs a Gemini key in plugins/output/adapt/pdf/scripts/configAPI.json
DONE
fi
