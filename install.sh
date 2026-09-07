#!/usr/bin/env bash
# Latticed - Debian 13 developer workstation bootstrap
set -Eeuo pipefail

readonly LATTICED_VERSION="0.1.0"
readonly REQUIRED_CODENAME="trixie"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_PATH="$(readlink -f "$0")"

log(){ printf '\n[Latticed] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'die "Installation failed near line $LINENO. Fix the error and rerun; completed package steps are safe to repeat."' ERR

# Make sure the invoking user can actually use sudo. A minimal Debian install
# often ships without sudo, or with the first user missing from the sudo group.
# We may also be in a login session that predates the group being added, in
# which case sudo still refuses. In every case we fix it and re-exec with the
# group active (sg), so the user never installs sudo or logs out and in by hand.
ensure_sudo(){
  # Already works (prompts for the password if needed).
  if command -v sudo >/dev/null 2>&1 && sudo -v; then
    return 0
  fi
  # A relaunch has already happened and sudo still refuses: real config problem.
  [[ -z "${LATTICED_SUDO_BOOTSTRAPPED:-}" ]] || die "sudo still refuses for '$TARGET_USER'. Check that /etc/sudoers grants the sudo group (%sudo), then open a new login session and rerun."
  if command -v sudo >/dev/null 2>&1 && id -nG "$TARGET_USER" 2>/dev/null | grep -qw sudo; then
    log "'$TARGET_USER' is in the sudo group but this login session predates it. Relaunching with the group active."
  else
    log "sudo is not set up for '$TARGET_USER'. Configuring it now - enter the ROOT password when prompted."
    su - root -c "apt-get update && apt-get install -y sudo && usermod -aG sudo '$TARGET_USER'" \
      || die "Could not configure sudo. Set a root password (or add '$TARGET_USER' to the sudo group) and rerun."
  fi
  log "Relaunching Latticed with sudo access active."
  exec env LATTICED_SUDO_BOOTSTRAPPED=1 sg sudo -c "bash '$SCRIPT_PATH'"
}

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not root. The script will use sudo when required."
ensure_sudo
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_CODENAME:-}" == "$REQUIRED_CODENAME" ]] || die "Latticed supports Debian 13 (Trixie) only."
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) die "Noctalia's Debian repository currently supports amd64 and arm64 only." ;; esac

log "Installing base desktop and applications"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget gnupg git build-essential procps file unzip labwc chromium filezilla imagemagick network-manager network-manager-gnome pipewire pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-wlr polkitd pkexec dbus-user-session fonts-noto fonts-noto-color-emoji

log "Installing WezTerm"
curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
sudo chmod 644 /usr/share/keyrings/wezterm-fury.gpg
echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | sudo tee /etc/apt/sources.list.d/wezterm.list >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wezterm

log "Installing Noctalia"
tmpdir="$(mktemp -d)"
wget -q -O "$tmpdir/nickh-archive-keyring.deb" https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb
sudo dpkg -i "$tmpdir/nickh-archive-keyring.deb"
sudo wget -q -O /etc/apt/sources.list.d/noctalia-trixie.sources https://pkg.noctalia.dev/deb/noctalia-trixie.sources
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y noctalia
rm -rf "$tmpdir"

log "Installing Brave Origin"
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y brave-origin

log "Installing Homebrew"
if [[ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
BREW=/home/linuxbrew/.linuxbrew/bin/brew
[[ -x "$BREW" ]] || die "Homebrew installation failed."
"$BREW" install ripgrep bat node
PROFILE="$TARGET_HOME/.profile"
touch "$PROFILE"
grep -q 'linuxbrew/.linuxbrew/bin/brew shellenv' "$PROFILE" || cat >> "$PROFILE" <<'BREWEOF'

# Homebrew - managed by Latticed
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF

log "Installing Docker Engine + Compose"
conflicts=()
for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' && conflicts+=("$pkg") || true; done
((${#conflicts[@]})) && sudo apt-get remove -y "${conflicts[@]}"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
ARCH="$(dpkg --print-architecture)"
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF2
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF2
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$TARGET_USER"

log "Installing Portainer CE on localhost:9443"
sudo install -d -m 0755 /opt/latticed/portainer
sudo tee /opt/latticed/portainer/compose.yaml >/dev/null <<'PORTAINER'
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
PORTAINER
sudo docker compose -f /opt/latticed/portainer/compose.yaml up -d

log "Installing Codex CLI"
PATH="/home/linuxbrew/.linuxbrew/bin:$PATH" npm install -g @openai/codex

log "Installing Claude Code"
if ! command -v claude >/dev/null 2>&1; then curl -fsSL https://claude.ai/install.sh | bash; fi

log "Configuring Labwc + Noctalia"
LABWC_DIR="$TARGET_HOME/.config/labwc"
mkdir -p "$LABWC_DIR"
if [[ -f "$LABWC_DIR/autostart" && ! -f "$LABWC_DIR/autostart.latticed-backup" ]]; then cp -a "$LABWC_DIR/autostart" "$LABWC_DIR/autostart.latticed-backup"; fi
cat > "$LABWC_DIR/autostart" <<'AUTOSTART'
#!/bin/sh
noctalia >/tmp/noctalia.log 2>&1 &
AUTOSTART
chmod +x "$LABWC_DIR/autostart"

# Start the Wayland desktop automatically after logging in on tty1. No display
# manager is installed, so this is what brings up labwc (which in turn launches
# Noctalia via the autostart file above). Other TTYs stay plain shells.
grep -q 'Latticed - start the desktop on tty1' "$PROFILE" || cat >> "$PROFILE" <<'DESKTOPEOF'

# Latticed - start the desktop on tty1
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc
fi
DESKTOPEOF

sudo systemctl enable NetworkManager

cat <<EOF3

============================================================
 Latticed ${LATTICED_VERSION} installation complete
============================================================
 Debian 13 + Labwc + Noctalia
 WezTerm | Chromium | Brave Origin | FileZilla | ImageMagick
 Homebrew: rg, bat, Node.js
 Docker Engine + Compose
 Portainer: https://localhost:9443
 Claude Code + OpenAI Codex CLI

Log out/reboot so Docker group membership takes effect.
The desktop starts automatically when you log in on tty1.
(On other TTYs, start it manually with: labwc)

No display manager is installed or replaced in v0.1.0.
============================================================
EOF3

# A reboot is needed for the docker (and sudo) group membership to take effect.
# The parent shell that launched this script still lacks those groups, so offer
# to reboot from here, where we still hold working sudo.
read -rp $'\nReboot now to finish? [y/N] ' answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  log "Rebooting"
  sudo systemctl reboot
else
  log "Skipping reboot. Reboot yourself before starting the desktop so the docker group is active."
fi
