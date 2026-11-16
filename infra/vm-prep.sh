#!/usr/bin/env bash
# freezes the VM OS between experiment runs: infra/vm-prep.sh [vm...]   (default: all nodes)
# no automatic apt runs, identical pinned kernel on every node; reboots a node only when its kernel changes
# VM_UPGRADE=1 also upgrades all packages (run on every node at once, so they stay identical)
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

prep() {
  local vm=$1
  # unattended-upgrades installed a new kernel on one node only (23.10)
  limactl shell --workdir / "$vm" sudo systemctl disable --now -q \
    unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
  limactl shell --workdir / "$vm" sudo systemctl mask -q \
    unattended-upgrades.service apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer
  [[ $(limactl shell --workdir / "$vm" uname -r) == "$KERNEL_VERSION" && ${VM_UPGRADE:-0} != 1 ]] && return 0

  log "$vm: kernel $KERNEL_VERSION${VM_UPGRADE:+, upgrade all packages}"
  limactl shell --workdir / "$vm" sudo sh -euc "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # the pinned kernel by its versioned package name; the archive keeps only the latest metapackage
    # version, so the metapackages are held where they are: they would pull the next ABI on any upgrade
    apt-mark hold -qq linux-virtual linux-image-virtual linux-headers-virtual linux-headers-generic
    apt-get install -y -qq -o DPkg::Lock::Timeout=300 linux-image-$KERNEL_VERSION linux-modules-$KERNEL_VERSION
    if [ '${VM_UPGRADE:-0}' = 1 ]; then apt-get full-upgrade -y -qq -o DPkg::Lock::Timeout=300; fi
    # grub boots the newest installed kernel; anything newer than the pin must not stay
    dpkg -l 'linux-image-[0-9]*' | awk '/^ii/{print \$2}' | sed 's/^linux-image-//' | sort -V \
      | awk -v k=$KERNEL_VERSION 'f; \$0 == k {f = 1}' | grep -q . && { echo 'kernel newer than pin installed' >&2; exit 1; } || true"
  # a guest reboot ends the vz VM; restart it through Lima
  limactl stop "$vm" >/dev/null
  limactl start --tty=false "$vm" >/dev/null
  [[ $(limactl shell --workdir / "$vm" uname -r) == "$KERNEL_VERSION" ]] || { echo "$vm did not boot $KERNEL_VERSION" >&2; exit 1; }
}

for vm in ${*:-$NODES}; do prep "$vm"; done
