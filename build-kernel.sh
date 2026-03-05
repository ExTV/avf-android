#!/bin/bash
# Build script for Android16 AVF guest kernel with Docker support
# Produces vmlinuz (arm64 Image) to copy to phone

set -e

# ─── Paths ───────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${ROOT_DIR}/common"
OUT_DIR="${ROOT_DIR}/out/kernel_build"

CLANG_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r536225/bin"
RUST_DIR="${ROOT_DIR}/prebuilts/rust/linux-x86/1.82.0/bin"
RUST_LIB_SRC="${ROOT_DIR}/prebuilts/rust/linux-x86/1.82.0/lib/rustlib/src/rust/library"
BINDGEN="${ROOT_DIR}/prebuilts/clang-tools/linux-x86/bin/bindgen"
BUILD_TOOLS="${ROOT_DIR}/prebuilts/build-tools/linux-x86/bin"
SCRIPTS_CONFIG="${KERNEL_DIR}/scripts/config"

# ─── Tool checks ─────────────────────────────────────────────────────────────
for f in "${CLANG_DIR}/clang" "${RUST_DIR}/rustc" "${BINDGEN}" "${SCRIPTS_CONFIG}"; do
    [[ -x "$f" ]] || { echo "ERROR: missing tool: $f"; exit 1; }
done

export PATH="${CLANG_DIR}:${RUST_DIR}:${BUILD_TOOLS}:${PATH}"

# ─── Build variables ─────────────────────────────────────────────────────────
ARCH=arm64
LLVM="${CLANG_DIR}/"
JOBS=$(nproc)

MAKE_ARGS=(
    -C "${KERNEL_DIR}"
    O="${OUT_DIR}"
    ARCH="${ARCH}"
    LLVM="${LLVM}"
    LLVM_IAS=1
    RUSTC="${RUST_DIR}/rustc"
    BINDGEN="${BINDGEN}"
    RUST_LIB_SRC="${RUST_LIB_SRC}"
)

# ─── Step 1: Output directory ────────────────────────────────────────────────
echo "==> [1/5] Creating output directory: ${OUT_DIR}"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# ─── Step 2: Seed .config from phone's original config ───────────────────────
echo "==> [2/5] Seeding .config from original phone config..."

if [[ ! -f "${ROOT_DIR}/original-config-from-phone.txt" ]]; then
    echo ""
    echo "ERROR: original-config-from-phone.txt not found."
    echo ""
    echo "  To get it, do the following:"
    echo ""
    echo "  1. Open the Terminal app on your phone"
    echo "  2. Run inside the VM:"
    echo "       zcat /proc/config.gz > /mnt/shared/Download/kernel-config.txt"
    echo ""
    echo "  3. Then on this machine:"
    echo "       adb pull /sdcard/Download/kernel-config.txt ${ROOT_DIR}/original-config-from-phone.txt"
    echo ""
    exit 1
fi

cp "${ROOT_DIR}/original-config-from-phone.txt" "${OUT_DIR}/.config"

# ─── Step 3: Apply all Docker configs via scripts/config ─────────────────────
# scripts/config is the kernel's own .config editor — it correctly handles the
# "# CONFIG_X is not set" syntax and overwrites rather than just appending,
# which prevents olddefconfig from silently reverting our additions.
echo "==> [3/5] Applying Docker configs via scripts/config..."

SC="${SCRIPTS_CONFIG} --file ${OUT_DIR}/.config"

# ── Dependencies (must come before the configs that need them) ────────────────

# CGROUP_HUGETLB depends on HUGETLBFS which is not set in the phone config
$SC --enable HUGETLBFS

# IP_VS deps — NF_CONNTRACK already =y, NETFILTER_ADVANCED already =y

# ── Namespace support ─────────────────────────────────────────────────────────
$SC --enable  PID_NS
$SC --enable  IPC_NS
$SC --enable  USER_NS

# ── Cgroup extensions ─────────────────────────────────────────────────────────
$SC --enable  CGROUP_DEVICE
$SC --enable  CGROUP_PIDS
$SC --enable  CGROUP_PERF
$SC --enable  CGROUP_HUGETLB
$SC --enable  BLK_DEV_THROTTLING

# ── POSIX message queues ──────────────────────────────────────────────────────
$SC --enable  POSIX_MQUEUE

# ── Bridge / overlay / tunnel networking ─────────────────────────────────────
$SC --enable  BRIDGE_NETFILTER
$SC --enable  BRIDGE_VLAN_FILTERING
$SC --enable  VXLAN
$SC --enable  IPVLAN
$SC --enable  MACVLAN

# ── SCTP ─────────────────────────────────────────────────────────────────────
$SC --module  IP_SCTP

# ── IPVS (virtual server / load balancing) ───────────────────────────────────
$SC --module  IP_VS
$SC --enable  IP_VS_NFCT
$SC --enable  IP_VS_PROTO_TCP
$SC --enable  IP_VS_PROTO_UDP
$SC --module  IP_VS_RR
$SC --module  NETFILTER_XT_MATCH_IPVS

# ── nftables ─────────────────────────────────────────────────────────────────
$SC --enable  NF_TABLES
$SC --enable  NF_TABLES_IPV4
$SC --enable  NF_TABLES_IPV6
$SC --enable  NF_TABLES_INET
$SC --module  NFT_NAT
$SC --enable  NFT_MASQ
$SC --enable  NFT_CT
$SC --module  NFT_FIB
$SC --module  NFT_FIB_IPV4
$SC --module  NFT_FIB_IPV6

# ── IPv6 NAT / masquerade ─────────────────────────────────────────────────────
$SC --enable  IP6_NF_NAT
$SC --enable  IP6_NF_TARGET_MASQUERADE

# ── Netfilter XT matches ─────────────────────────────────────────────────────
$SC --enable  NETFILTER_XT_MATCH_ADDRTYPE

# ── AppArmor ─────────────────────────────────────────────────────────────────
$SC --enable  SECURITY_APPARMOR

# ── Filesystems ──────────────────────────────────────────────────────────────
$SC --module  BTRFS_FS
$SC --enable  BTRFS_FS_POSIX_ACL

# ── Build hygiene ─────────────────────────────────────────────────────────────
$SC --disable LOCALVERSION_AUTO
$SC --disable WERROR

# ─── Step 4: Resolve config dependencies ─────────────────────────────────────
echo "==> [4/5] Running olddefconfig to resolve dependencies..."
make "${MAKE_ARGS[@]}" olddefconfig

# ── Verify every config made it through ──────────────────────────────────────
echo ""
echo "--- Config verification ---"
MISSING=0
check_cfg() {
    local cfg="$1" expected="$2"
    local line
    line=$(grep "^CONFIG_${cfg}=" "${OUT_DIR}/.config" 2>/dev/null \
           || grep "^# CONFIG_${cfg} is not set" "${OUT_DIR}/.config" 2>/dev/null \
           || echo "ABSENT")
    local actual
    if [[ "$line" == *"is not set"* ]] || [[ "$line" == "ABSENT" ]]; then
        actual="n"
    else
        actual="${line##*=}"
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo "  FAIL  CONFIG_${cfg}: wanted=${expected}  got=${actual}"
        MISSING=1
    else
        echo "  OK    CONFIG_${cfg}=${actual}"
    fi
}

check_cfg PID_NS               y
check_cfg IPC_NS               y
check_cfg USER_NS              y
check_cfg CGROUP_DEVICE        y
check_cfg CGROUP_PIDS          y
check_cfg CGROUP_PERF          y
check_cfg CGROUP_HUGETLB       y
check_cfg BLK_DEV_THROTTLING   y
check_cfg POSIX_MQUEUE         y
check_cfg BRIDGE_NETFILTER     y
check_cfg BRIDGE_VLAN_FILTERING y
check_cfg VXLAN                y
check_cfg IPVLAN               y
check_cfg MACVLAN              y
check_cfg IP_SCTP              m
check_cfg IP_VS                m
check_cfg IP_VS_NFCT           y
check_cfg IP_VS_PROTO_TCP      y
check_cfg IP_VS_PROTO_UDP      y
check_cfg IP_VS_RR             m
check_cfg NETFILTER_XT_MATCH_IPVS m
check_cfg NF_TABLES            y
check_cfg NFT_NAT              m
check_cfg NFT_MASQ             y
check_cfg NFT_CT               y
check_cfg NFT_FIB              m
check_cfg NFT_FIB_IPV4         m
check_cfg NFT_FIB_IPV6         m
check_cfg IP6_NF_NAT           y
check_cfg IP6_NF_TARGET_MASQUERADE y
check_cfg NETFILTER_XT_MATCH_ADDRTYPE y
check_cfg SECURITY_APPARMOR    y
check_cfg BTRFS_FS             m
check_cfg BTRFS_FS_POSIX_ACL   y
echo ""

if [[ $MISSING -eq 1 ]]; then
    echo "ERROR: One or more configs did not make it through olddefconfig."
    echo "       The FAILed entries above have unmet dependencies."
    echo "       Add the missing dependency to the scripts/config block in this"
    echo "       script (step 3) and re-run."
    exit 1
fi

# ─── Step 5: Build kernel Image ──────────────────────────────────────────────
echo "==> [5/5] Building kernel (using ${JOBS} threads)..."
echo "    This will take 20-60 minutes depending on your CPU."
echo ""

make "${MAKE_ARGS[@]}" -j"${JOBS}" Image

# ─── Copy output ─────────────────────────────────────────────────────────────
KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
VMLINUZ="${ROOT_DIR}/vmlinuz"

[[ -f "${KERNEL_IMAGE}" ]] || { echo "ERROR: Image not found at ${KERNEL_IMAGE}"; exit 1; }

cp "${KERNEL_IMAGE}" "${VMLINUZ}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Build complete!                                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Output:  ${VMLINUZ}"
echo "  Size:    $(du -h "${VMLINUZ}" | cut -f1)"
echo ""
echo "  Push to phone via adb:"
echo "    adb push vmlinuz /sdcard/Download/vmlinuz-docker"
echo ""
echo "  Then inside the Terminal VM:"
echo "    sudo su"
echo "    cp /mnt/shared/Download/vmlinuz-docker /tmp/vmlinuz-docker"
echo "    cp /tmp/vmlinuz-docker /mnt/internal/linux/vmlinuz-docker"
echo "    sed -i 's|\"\$PAYLOAD_DIR/vmlinuz\"|\"\$PAYLOAD_DIR/vmlinuz-docker\"|' /mnt/internal/linux/vm_config.json"
echo "  Then close and reopen the Terminal app."
echo ""
