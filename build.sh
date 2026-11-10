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
bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" prepare

# Apply this after fetching and preparing sources: the earlier workflow step
# ran before fetch_sources, which deletes and reclones the OpenWrt tree.
find . -type f -name 'config-*' -exec sed -i \
    's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' {} + || true

[ "$VARIANT" = standard ] && add_wifi_patches

# The MHI debugfs implementation in the pinned mac80211 backports tree needs
# the same CONFIG_MHI_BUS_DEBUG guard as the kernel-side patch. Apply it to
# mac80211 for both standard and wired variants.
mkdir -p package/kernel/mac80211/patches/subsys
cp "$REPO/common/patches/wifi/mac80211/0001-mhi-debugfs-config-guard.patch" \
    package/kernel/mac80211/patches/subsys/

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

# Patch the extracted mac80211 backports source directly. Its patch directory
# was not applying our earlier guard patch, so enforce the guard in Build/Prepare.
python3 - <<'PY'
p = "package/kernel/mac80211/Makefile"
s = open(p).read()
needle = "\t$(Build/Patch)\n"
replacement = needle + "\t sed -i '1i\\#ifdef CONFIG_MHI_BUS_DEBUG' $(PKG_BUILD_DIR)/drivers/bus/mhi/host/debugfs.c\n\t echo '#endif /* CONFIG_MHI_BUS_DEBUG */' >> $(PKG_BUILD_DIR)/drivers/bus/mhi/host/debugfs.c\n"
if "CONFIG_MHI_BUS_DEBUG */" not in s:
    if needle not in s:
        raise SystemExit("Could not find mac80211 Build/Patch hook")
    s = s.replace(needle, replacement, 1)
    open(p, "w").write(s)
PY

# Ensure the active build configuration disables MHI debug after all config merges.
sed -i 's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' .config

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" build
