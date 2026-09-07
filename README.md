# Latticed

Single-script bootstrap that turns a fresh **Debian 13 (Trixie)** install into a developer workstation: a Wayland desktop (Labwc + Noctalia), everyday apps, container tooling, and AI coding CLIs.

> **v0.1.0** - no display manager is installed or replaced. You start the desktop from a TTY.

## What it installs

| Category | Packages |
|----------|----------|
| Desktop | Labwc (Wayland compositor), Noctalia shell, PipeWire audio, xdg-desktop-portal-wlr, PolicyKit, NetworkManager |
| Apps | WezTerm, Chromium, Brave Origin, FileZilla, ImageMagick |
| Fonts | Noto + Noto Color Emoji |
| CLI tools | Homebrew, then `ripgrep`, `bat`, Node.js via brew |
| Containers | Docker Engine + Compose plugin, Portainer CE on `https://localhost:9443` |
| AI CLIs | Claude Code, OpenAI Codex CLI |

## Requirements

- Debian 13 (Trixie) only - script aborts on anything else.
- Architecture `amd64` or `arm64` (Noctalia repo limit).
- Run as your **normal user** (not root). `sudo` required; script calls it when needed.
- Network access to Debian, Noctalia, Brave, Docker, and Homebrew repos.

> **Use a minimal Debian base.** Latticed installs the entire Wayland stack itself (Labwc, Noctalia, PipeWire, portals) and no display manager. Start from a **netinst ISO** with every desktop task unchecked in `tasksel` (keep "standard system utilities"), or a cloud/minimal image. A preinstalled GNOME/KDE desktop only duplicates and conflicts with what this script sets up. If `sudo` is missing or your user is not in the `sudo` group, the script bootstraps it for you using the root account (you enter the root password once) and relaunches itself - no manual `usermod` or logout needed.

## Usage

A fresh minimal Debian usually has no `git` yet, and installing it needs root. Do that one bootstrap step as root:

```bash
su -
apt update && apt install -y git
exit
```

Then, as your **normal user**, clone and run:

```bash
git clone https://github.com/RicardoVcore/latticed.git
cd latticed
bash install.sh
```

> Clone the repo - don't pipe the script through `curl … | bash`. The sudo bootstrap re-execs the script as a real file, which a piped stream can't provide.

Completed package steps are safe to repeat - rerun after fixing any failure.

## After install

1. **Log out or reboot** so `docker` group membership takes effect. The installer offers to reboot for you at the end.
2. Log in on **tty1** - the desktop (labwc + Noctalia) starts automatically. On any other TTY, start it manually with `labwc`.
3. Portainer waits at `https://localhost:9443` (bound to localhost only).

## Notes

- Homebrew shellenv is appended to `~/.profile` (idempotent).
- A tty1 autostart guard is appended to `~/.profile` (idempotent): on tty1 with no Wayland session, it `exec labwc`.
- Existing `~/.config/labwc/autostart` is backed up to `autostart.latticed-backup` before being replaced.
- Portainer compose file lives at `/opt/latticed/portainer/compose.yaml`.
- `set -Eeuo pipefail` + `ERR` trap: the script stops at the first failure and tells you the line.

## License

MIT - see [LICENSE](LICENSE).
