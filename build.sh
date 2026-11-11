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

# autobuild prepare can recreate package directories, so the custom
# mac80211 patch is installed again after prepare and feed installation below.
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

# Feed installation can replace package/kernel/mac80211 after autobuild prepare.
# Install the MHI guard only after all feed mutations, immediately before config
# generation/build, so the package's patch series actually sees it.
mkdir -p package/kernel/mac80211/patches/subsys
cp "$REPO/common/patches/wifi/mac80211/0001-mhi-debugfs-config-guard.patch" \
    package/kernel/mac80211/patches/subsys/
test -s package/kernel/mac80211/patches/subsys/0001-mhi-debugfs-config-guard.patch
grep -q 'CONFIG_MHI_BUS_DEBUG' package/kernel/mac80211/patches/subsys/0001-mhi-debugfs-config-guard.patch
echo "Verified MHI guard patch installed after feed installation"

\cp "$REPO/boards/$BOARD/configs/$VARIANT.config" .config
make defconfig
add_config
board_config

# Keep the debug implementation out when the inline stubs are selected.
sed -i 's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' .config

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" build
