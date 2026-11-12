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

# Patch the actual mac80211 preparation recipe. Feed/autobuild stages can
# replace package patch directories, so make the guard part of Build/Prepare
# itself, after upstream patches are applied and before compilation begins.
python3 - <<'PY'
from pathlib import Path
p = Path("package/kernel/mac80211/Makefile")
s = p.read_text()
start_marker = "define Build/Prepare\n"
start = s.find(start_marker)
if start < 0:
    raise SystemExit("Could not find mac80211 Build/Prepare definition")
end = s.find("\nendef", start)
if end < 0:
    raise SystemExit("Could not find end of mac80211 Build/Prepare definition")
block = s[start:end]
needle = "\t$(Build/Patch)\n"
guard = """\t# Keep MHI debugfs implementation consistent with inline stubs in internal.h.
\t@python3 -c 'from pathlib import Path; p=Path("$(PKG_BUILD_DIR)/drivers/bus/mhi/host/debugfs.c"); s=p.read_text(); p.write_text(s if s.startswith("#ifdef CONFIG_MHI_BUS_DEBUG\n") else "#ifdef CONFIG_MHI_BUS_DEBUG\n" + s + "\n#endif /* CONFIG_MHI_BUS_DEBUG */\n")'
"""
if "Keep MHI debugfs implementation consistent" not in block:
    if block.count(needle) != 1:
        raise SystemExit("Expected exactly one Build/Patch call inside Build/Prepare")
    block = block.replace(needle, needle + guard, 1)
    s = s[:start] + block + s[end:]
    p.write_text(s)
print("Verified MHI guard is installed inside mac80211 Build/Prepare")
PY
grep -q 'Keep MHI debugfs implementation consistent' package/kernel/mac80211/Makefile

\cp "$REPO/boards/$BOARD/configs/$VARIANT.config" .config
make defconfig
add_config
board_config

# Keep the debug implementation out when the inline stubs are selected.
sed -i 's/^CONFIG_MHI_BUS_DEBUG=y$/# CONFIG_MHI_BUS_DEBUG is not set/' .config

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" build
