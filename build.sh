#!/bin/bash
# Build one board and variant:
#
#   ./build.sh <board> <variant>
#     board:   bpi-r4 | bpi-r4-pro-8x     (boards/<board>/board.sh)
#     variant: standard (Wi-Fi) | wired   (boards/<board>/configs/<variant>.config)
#
# Run from the repository root. The OpenWrt tree is created in ./openwrt and
# the MTK feed in ./mtk-openwrt-feeds; both are deleted first. Images end up
# in openwrt/bin/targets/mediatek/filogic.
#
# What is shared by both boards lives in common/, what is not in boards/.
# The upstream revisions are in pins.conf.
set -euo pipefail

usage() { echo "usage: $0 <bpi-r4|bpi-r4-pro-8x> <standard|wired>" >&2; exit 1; }

BOARD=${1:-}
VARIANT=${2:-}
[ -f "boards/$BOARD/board.sh" ] || usage
[ -f "boards/$BOARD/configs/$VARIANT.config" ] || usage

REPO=$(pwd)
. "$REPO/scripts/common.sh"
. "$REPO/boards/$BOARD/board.sh"

load_pins "$REPO/pins.conf"

case $VARIANT in
standard) PROFILE=filogic-mac80211-mt798x_rfb-wifi7_nic ;;
wired)    PROFILE=filogic ;;
esac

fetch_sources

add_kernel_patches

cd openwrt

# Install the MHI guard patch BEFORE autobuild prepare unpacks/patches mac80211.
mkdir -p package/kernel/mac80211/patches/subsys
cp "$REPO/common/patches/wifi/mac80211/0001-mhi-debugfs-config-guard.patch" \
    package/kernel/mac80211/patches/subsys/

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" prepare

# Apply this after fetching and preparing sources: the earlier workflow step
# ran before fetch_sources, which deletes and reclones the OpenWrt tree.
find . -type f -name 'config-*' -exec sed -i \
    's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' {} + || true

[ "$VARIANT" = standard ] && add_wifi_patches


board_tree
add_packages
add_files
board_packages

./scripts/feeds update -a
./scripts/feeds install -a

board_after_feeds
add_after_feeds

\cp "$REPO/boards/$BOARD/configs/$VARIANT.config" .config
make defconfig
add_config
board_config

# Patch the actual extracted source immediately before the build. Do not rely
# on Build/Prepare hooks: autobuild may reuse an existing prepared stamp.
python3 - <<'PY'
from pathlib import Path
import sys

root = Path("build_dir")
matches = list(root.glob("target-*/linux-mediatek_filogic/mac80211-regular/backports*/drivers/bus/mhi/host/debugfs.c"))
if not matches:
    matches = list(root.glob("**/mac80211-regular/backports*/drivers/bus/mhi/host/debugfs.c"))
if not matches:
    sys.exit("ERROR: MHI debugfs.c not found after autobuild prepare; refusing to launch a full build.")

for p in matches:
    s = p.read_text()
    if "MHI_DEBUGFS_CONFIG_GUARD_BEGIN" in s:
        print(f"MHI guard already present: {p}")
        continue
    p.write_text("#ifdef CONFIG_MHI_BUS_DEBUG\n#define MHI_DEBUGFS_CONFIG_GUARD_BEGIN 1\n" + s + "\n#endif /* CONFIG_MHI_BUS_DEBUG */\n")
    check = p.read_text()
    if not check.startswith("#ifdef CONFIG_MHI_BUS_DEBUG\n#define MHI_DEBUGFS_CONFIG_GUARD_BEGIN 1"):
        sys.exit(f"ERROR: MHI guard verification failed: {p}")
    print(f"Applied and verified MHI guard: {p}")
PY

# Ensure the active build configuration disables MHI debug after all config merges.
sed -i 's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' .config

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" build
