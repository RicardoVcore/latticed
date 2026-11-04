#!/usr/bin/env bash
# Build a Latticed ISO from an official Debian 13 (trixie) netinst ISO.
# Usage: ./build-iso.sh <netinst.iso> [out.iso]
# Required env: LATTICED_USER, LATTICED_PASSWORD_HASH
# Optional env: LATTICED_TIMEZONE (default Europe/Lisbon), LATTICED_HOSTNAME (default latticed),
#               LATTICED_SHA512SUMS (path to Debian SHA512SUMS for input verification)
# Password hash: openssl passwd -6  (paste into LATTICED_PASSWORD_HASH, never store it)
set -Eeuo pipefail

die() { echo "build-iso.sh: $*" >&2; exit 1; }

# Escape a value for use in a sed replacement with | as delimiter.
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

usage() {
  cat >&2 <<'EOF'
Usage: ./build-iso.sh <netinst.iso> [out.iso]

Required env:
  LATTICED_USER           login name of the user to create
  LATTICED_PASSWORD_HASH  SHA-512 crypt hash ($6$...); make one with: openssl passwd -6
Optional env:
  LATTICED_TIMEZONE       default Europe/Lisbon
  LATTICED_HOSTNAME       default latticed
  LATTICED_SHA512SUMS     Debian SHA512SUMS file to verify the input ISO (no download)
EOF
  exit 2
}

IN_ISO=${1:-}
OUT_ISO=${2:-}
# Repo-relative paths (staging, dist/, .gitignore) assume the script lives at repo root.
cd "$(dirname "$0")"
LATTICED_TIMEZONE=${LATTICED_TIMEZONE:-Europe/Lisbon}
LATTICED_HOSTNAME=${LATTICED_HOSTNAME:-latticed}

[[ $# -ge 1 ]] || usage
[[ -n ${LATTICED_USER:-} && $LATTICED_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || die "LATTICED_USER must be set and match [a-z_][a-z0-9_-]{0,31}"
[[ -n ${LATTICED_PASSWORD_HASH:-} && $LATTICED_PASSWORD_HASH == '$6$'* ]] \
  || die "LATTICED_PASSWORD_HASH must be set and start with \$6\$ (make one with: openssl passwd -6)"
[[ -n $IN_ISO ]] || usage
[[ -f $IN_ISO ]] || die "input ISO not found: $IN_ISO"

for tool in xorriso rsync sha512sum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH (not installing anything)"
done

IN_ISO=$(readlink -f "$IN_ISO")

# Optional integrity check against Debian's SHA512SUMS.
if [[ -n ${LATTICED_SHA512SUMS:-} ]]; then
  [[ -f $LATTICED_SHA512SUMS ]] || die "LATTICED_SHA512SUMS not found: $LATTICED_SHA512SUMS"
  want=$(grep -E " $(basename "$IN_ISO")\$" "$LATTICED_SHA512SUMS" | awk '{print $1}') \
    || die "no entry for $(basename "$IN_ISO") in $LATTICED_SHA512SUMS"
  got=$(sha512sum "$IN_ISO" | awk '{print $1}')
  [[ $want == "$got" ]] || die "SHA512 mismatch for $(basename "$IN_ISO")"
  echo "SHA512 OK: $(basename "$IN_ISO")"
fi

# Default output: dist/latticed-<debian version>.iso
if [[ -z $OUT_ISO ]]; then
  ver=$(basename "$IN_ISO" | sed -n -E 's/^debian-([0-9.]+)-.*/\1/p')
  [[ -n $ver ]] || die "cannot derive Debian version from '$(basename "$IN_ISO")', pass out.iso"
  OUT_ISO="dist/latticed-$ver.iso"
fi
mkdir -p "$(dirname "$OUT_ISO")"
OUT_ISO=$(readlink -f "$OUT_ISO")
[[ $OUT_ISO != "$IN_ISO" ]] || die "output must differ from input"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'echo "build-iso.sh: failed at line $LINENO" >&2' ERR

# Extract the ISO read-only into the work dir.
xorriso -osirrox on -indev "$IN_ISO" -extract / "$WORK/iso" >/dev/null 2>&1 \
  || die "failed to extract $(basename "$IN_ISO")"
# The image carries read-only dirs; make them writable for patching and cleanup.
chmod -R u+w "$WORK/iso"

# Stage the repo copy that goes onto the ISO; placeholders are fixed only here.
mkdir -p "$WORK/latticed"
rsync -a --exclude .git --exclude dist ./ "$WORK/latticed/"

SEED="$WORK/latticed/preseed/preseed.cfg"
UNIT="$WORK/latticed/preseed/firstboot/latticed-firstboot.service"
[[ -f $SEED && -f $UNIT ]] || die "staged preseed files missing from repo"

# Substitute placeholders in the staged copies only (| delimiter, values escaped).
sed -i \
  -e "s|d-i time/zone string .*|d-i time/zone string $(sed_esc "$LATTICED_TIMEZONE")|" \
  -e "s|d-i netcfg/get_hostname string .*|d-i netcfg/get_hostname string $(sed_esc "$LATTICED_HOSTNAME")|" \
  -e "s|d-i passwd/username string .*|d-i passwd/username string $(sed_esc "$LATTICED_USER")|" \
  -e "s|d-i passwd/user-password-crypted string .*|d-i passwd/user-password-crypted string $(sed_esc "$LATTICED_PASSWORD_HASH")|" \
  -e "s|echo \"CHANGEME ALL|echo \"$(sed_esc "$LATTICED_USER") ALL|" \
  "$SEED"
sed -i "s|^User=CHANGEME$|User=$(sed_esc "$LATTICED_USER")|" "$UNIT"

# Fail if any real placeholder remains (ignore CHANGEME in prose comments).
if grep -n CHANGEME "$SEED" | grep -vE '^[0-9]+:#' ; then
  die "unsubstituted CHANGEME left in staged preseed.cfg"
fi
grep -n CHANGEME "$UNIT" && die "unsubstituted CHANGEME left in staged firstboot unit"

# Preseed at ISO root, repo at ISO root (/cdrom/latticed during install).
cp "$SEED" "$WORK/iso/preseed.cfg"
rsync -a "$WORK/latticed/" "$WORK/iso/latticed/"

# Append preseed boot params to the default entries only: txt.cfg (serial/text),
# gtk.cfg (the BIOS vesamenu default), and grub's first menuentry (UEFI default).
TXT="$WORK/iso/isolinux/txt.cfg"
GTK="$WORK/iso/isolinux/gtk.cfg"
GRUB="$WORK/iso/boot/grub/grub.cfg"
PRESEED_ARGS="auto=true priority=critical file=/cdrom/preseed.cfg"
sed -i '0,/^\s*append /s| --- | '"$PRESEED_ARGS"' --- |' "$TXT"
sed -i '0,/^\s*append /s| --- | '"$PRESEED_ARGS"' --- |' "$GTK"
sed -i '0,/^\s*linux\s/{/^\s*linux\s/s|$| '"$PRESEED_ARGS"'|}' "$GRUB"
grep -q 'file=/cdrom/preseed.cfg' "$TXT" || die "failed to patch isolinux/txt.cfg"
grep -q 'file=/cdrom/preseed.cfg' "$GTK" || die "failed to patch isolinux/gtk.cfg"
grep -q 'file=/cdrom/preseed.cfg' "$GRUB" || die "failed to patch boot/grub/grub.cfg"

# Rebuild keeping the original boot records; keep the original volume label.
VOLID=$(xorriso -indev "$IN_ISO" -toc 2>/dev/null | sed -n 's/^ISO session  : *[0-9]* *, *[0-9]*s *, *[0-9]*s *, *//p' | head -1)
REBUILD_OUT=$(xorriso -indev "$IN_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  ${VOLID:+-volid "$VOLID"} \
  -map "$WORK/iso/preseed.cfg" /preseed.cfg \
  -map "$WORK/iso/latticed" /latticed \
  -map "$TXT" /isolinux/txt.cfg \
  -map "$GTK" /isolinux/gtk.cfg \
  -map "$GRUB" /boot/grub/grub.cfg \
  2>&1 | tail -5) || die "xorriso rebuild failed: $REBUILD_OUT"

# Verify the output image.
xorriso -indev "$OUT_ISO" -find /preseed.cfg -type f 2>/dev/null | grep -q '/preseed.cfg' \
  || die "verification failed: /preseed.cfg not in output"
xorriso -indev "$OUT_ISO" -find /latticed/install.sh -type f 2>/dev/null | grep -q '/latticed/install.sh' \
  || die "verification failed: /latticed/install.sh not in output"
xorriso -osirrox on -indev "$OUT_ISO" -extract /isolinux/txt.cfg "$WORK/check.txt.cfg" >/dev/null 2>&1 \
  && grep -q 'file=/cdrom/preseed.cfg' "$WORK/check.txt.cfg" \
  || die "verification failed: preseed boot param missing from isolinux/txt.cfg"
xorriso -osirrox on -indev "$OUT_ISO" -extract /isolinux/gtk.cfg "$WORK/check.gtk.cfg" >/dev/null 2>&1 \
  && grep -q 'file=/cdrom/preseed.cfg' "$WORK/check.gtk.cfg" \
  || die "verification failed: preseed boot param missing from isolinux/gtk.cfg"
xorriso -osirrox on -indev "$OUT_ISO" -extract /boot/grub/grub.cfg "$WORK/check.grub.cfg" >/dev/null 2>&1 \
  && grep -q 'file=/cdrom/preseed.cfg' "$WORK/check.grub.cfg" \
  || die "verification failed: preseed boot param missing from boot/grub/grub.cfg"

# Record dist/ so builds never land in git; done once, at the end.
if [[ -f .gitignore ]]; then
  grep -qxF 'dist/' .gitignore || echo 'dist/' >> .gitignore
else
  echo 'dist/' > .gitignore
fi

echo "OK: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
