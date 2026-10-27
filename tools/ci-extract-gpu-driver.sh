#!/usr/bin/env bash
set -euo pipefail

# Only a fresh GitHub-hosted Linux runner may execute this preparation job.
[[ "$GITHUB_ACTIONS" == true && "$RUNNER_OS" == Linux && "$RUNNER_ENVIRONMENT" == github-hosted && $(id -u) == 0 ]]
RUNNER_TEMP=$(realpath -e "$RUNNER_TEMP")
[[ -d "$RUNNER_TEMP" && "$RUNNER_TEMP" != / ]]
[[ $(findmnt -n -o FSTYPE -T "$RUNNER_TEMP") != tmpfs ]]
umask 022
ulimit -c 0
WORK=$(mktemp -d "$RUNNER_TEMP/vphone-gpu.XXXXXX")
OUT="$GITHUB_WORKSPACE/artifacts"
LOG="$WORK/logs"
PREFIX="$WORK/prefix"
mkdir -p "$OUT/logs" "$LOG" "$PREFIX"
exec > >(tee "$LOG/main.log") 2>&1

VPHONE=f839de562aac9ebeb6b2f922ff0e54fc28d1f8fc
CLI=a9e42c2c31d4d76b4cfe398b7bec9b5cbb3f0ff9
QEMU_REF=3ed85774c2989addec3056a866991762b60c4b5c
USBMUXD_REF=3ded00c9985a5108cfc7591a309f9a23d57a8cba
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz
NETTLE_SHA=fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5
CLOUD_SHA=c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64
CLOUD_URL=https://updates.cdn-apple.com/private-cloud-compute/$CLOUD_SHA
SWIFT_URL=https://download.swift.org/swift-6.4.1-release/ubuntu2204/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-ubuntu22.04.tar.gz
SWIFT_SHA=e9ec2ff05ac0fc89bf2e7cecdee5da4d398898a768d7ee2b86a59d2a7f01c44b
SEVEN_URL=https://github.com/ip7z/7zip/releases/download/26.05/7z2605-linux-x64.tar.xz
SEVEN_SHA=22cf82fcc6eb7474f1d5bb4f02c0f8ebd573a718089d6833dc30f8350a3b232e
export WORK OUT PREFIX VPHONE CLI QEMU_REF USBMUXD_REF NETTLE_URL NETTLE_SHA CLOUD_SHA CLOUD_URL SWIFT_URL SWIFT_SHA SEVEN_URL SEVEN_SHA
export DEBIAN_FRONTEND=noninteractive
export http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= all_proxy= NO_PROXY='*'
qemu_pid= mux_pid= exporter_pid= attacher_pid= restore_pid= restore_log_pid= guard_pid=
ROOT="$WORK/vphone-linux"
VM="$ROOT/vms/gpu-recovery"
SOCK="$WORK/qmp.sock"
python3 - <<'PY' > "$OUT/inputs.json"
import json,os
keys=['VPHONE','CLI','QEMU_REF','USBMUXD_REF','NETTLE_URL','NETTLE_SHA','CLOUD_URL','CLOUD_SHA','SWIFT_URL','SWIFT_SHA','SEVEN_URL','SEVEN_SHA','GITHUB_RUN_ID','GITHUB_SHA']
print(json.dumps({k:os.environ[k] for k in keys},indent=2))
PY

qmp() {
    python3 - "$SOCK" "$1" <<'PY'
import json,socket,sys
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(10); s.connect(sys.argv[1]); f=s.makefile('rw'); f.readline()
    for op in ('qmp_capabilities',sys.argv[2]):
        f.write(json.dumps({'execute':op})+'\n'); f.flush()
        while True:
            reply=json.loads(f.readline())
            print(json.dumps(reply))
            if 'error' in reply: raise SystemExit(1)
            if 'return' in reply: break
PY
}

stop_vm() {
    [[ -n "$qemu_pid" ]] || return 0
    if kill -0 "$qemu_pid" 2>/dev/null; then
        qmp quit >> "$LOG/qmp.log" 2>&1 || true
        for _ in $(seq 1 10); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$qemu_pid" 2>/dev/null; then
            echo 'QEMU quit timeout; terminating own PID' >> "$LOG/lifecycle.log"
            kill -TERM "$qemu_pid" 2>/dev/null || true
            for _ in $(seq 1 10); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 1; done
            kill -0 "$qemu_pid" 2>/dev/null && kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
    fi
    local rc=0
    wait "$qemu_pid" || rc=$?
    printf 'QEMU exit=%s UTC=%s\n' "$rc" "$(date -u +%FT%TZ)" >> "$LOG/lifecycle.log"
    qemu_pid=
    sync
    echo 'Host sync complete' >> "$LOG/lifecycle.log"
    [[ "$rc" == 0 ]]
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    for pid in "$guard_pid" "$restore_log_pid" "$restore_pid" "$attacher_pid" "$exporter_pid" "$mux_pid"; do
        [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
    done
    stop_vm || rc=1
    if command -v usbip >/dev/null; then
        port=$(usbip port 2>/dev/null | sed -nE 's/^Port ([0-9]+): <Port in Use>.*/\1/p' | head -1)
        [[ -z "$port" ]] || usbip detach -p "$port" || true
    fi
    for file in "$LOG"/*.log; do
        [[ ! -f "$file" ]] || tail -c 262144 "$file" > "$OUT/logs/$(basename "$file")"
    done
    [[ ! -f "$LOG/restore.log" ]] || grep -E 'boot-args|Restore Finished|Failed|Error:' "$LOG/restore.log" | tail -c 262144 > "$OUT/logs/restore-summary.log" || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

stage() { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fetch() { curl --noproxy '*' -fL --retry 3 --connect-timeout 30 -C - "$1" -o "$2"; echo "$3  $2" | sha256sum -c -; }
clone() {
    stage "Fetch pinned source: $1 ($2)"
    git init -q "$3"
    git -C "$3" remote add origin "$1"
    git -C "$3" -c http.proxy= -c http.version=HTTP/1.1 fetch -q --depth 1 origin "$2"
    git -C "$3" checkout -q --detach FETCH_HEAD
    [[ $(git -C "$3" rev-parse HEAD) == "$2" ]]
}
check_resources() {
    local mem disk
    mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    disk=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
    printf 'MemAvailableKiB=%s DiskAvailableKiB=%s\n' "$mem" "$disk"
    (( mem >= 7*1024*1024 && disk >= 25*1024*1024 ))
}

# These are fixed preinstalled SDK directories on the disposable hosted VM.
stage 'Free space on the disposable runner and install build dependencies'
rm -rf -- /usr/local/lib/android /usr/share/dotnet /opt/hostedtoolcache
apt-get update -qq 2>&1 | tee "$LOG/apt.log"
apt-get install -y --no-install-recommends build-essential clang cmake ninja-build pkg-config autoconf automake libtool git curl xz-utils unzip python3-venv libglib2.0-dev libpixman-1-dev libfdt-dev libusb-1.0-0-dev libusbmuxd-dev libarchive-dev libssl-dev libcurl4-openssl-dev zlib1g-dev libbz2-dev liblzma-dev libxml2-dev libicu-dev libblocksruntime-dev libncurses-dev libedit-dev libsqlite3-dev libtasn1-6-dev libgmp-dev linux-tools-generic 2>&1 | tee -a "$LOG/apt.log"
pkg-config --print-errors --exists libtasn1
stage 'Check USB/IP kernel modules'
if ! modprobe usbip_core || ! modprobe vhci_hcd; then
    stage "Install missing USB/IP modules for kernel $(uname -r)"
    apt-get install -y --no-install-recommends "linux-modules-extra-$(uname -r)" 2>&1 | tee -a "$LOG/apt.log"
    modprobe usbip_core
    modprobe vhci_hcd
fi
lsmod | awk 'NR==1 || $1 ~ /^(usbip_core|vhci_hcd)$/' | tee "$LOG/modules.log"
stage 'USB/IP modules loaded successfully'
USBIP=$(find -L /usr/lib/linux-tools -maxdepth 2 -name usbip -type f -executable | sort -V | tail -1)
[[ -n "$USBIP" ]]
mkdir -p "$PREFIX/bin"
ln -s "$USBIP" "$PREFIX/bin/usbip"
export PATH="$PREFIX/bin:$PATH"
usbip version
check_resources

clone https://github.com/YahiaAngelo/vphone-linux.git "$VPHONE" "$ROOT"
clone https://github.com/Lakr233/vphone-cli.git "$CLI" "$WORK/vphone-cli"
git -C "$ROOT" submodule update --init qemu
[[ $(git -C "$ROOT/qemu" rev-parse HEAD) == "$QEMU_REF" ]]
git -C "$ROOT/qemu" submodule update --init util/mlib

stage 'Download and unpack the pinned Swift toolchain'
fetch "$SWIFT_URL" "$WORK/swift.tar.gz" "$SWIFT_SHA"
mkdir "$WORK/swift"
tar -xzf "$WORK/swift.tar.gz" -C "$WORK/swift" --strip-components=1
export PATH="$WORK/swift/usr/bin:$PATH"
stage 'Install pinned Meson'
python3 -m venv "$WORK/python"
"$WORK/python/bin/pip" install meson==1.9.1 2>&1 | tee "$LOG/meson.log"
export PATH="$WORK/python/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib:$WORK/swift/usr/lib/swift/linux"
export C_INCLUDE_PATH="$PREFIX/include" LIBRARY_PATH="$PREFIX/lib"

stage 'Build pinned Nettle for the guest AES device'
fetch "$NETTLE_URL" "$WORK/nettle.tar.gz" "$NETTLE_SHA"
mkdir "$WORK/nettle" "$WORK/nettle-build"
tar -xzf "$WORK/nettle.tar.gz" -C "$WORK/nettle" --strip-components=1
(cd "$WORK/nettle-build"; "$WORK/nettle/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-documentation --disable-static --enable-shared; make -j2; make install) 2>&1 | tee "$LOG/nettle.log"
pkg-config --atleast-version=3.10 nettle

clone https://github.com/lzfse/lzfse.git e634ca58b4821d9f3d560cdc6df5dec02ffc93fd "$WORK/lzfse"
stage 'Build and install LZFSE'
cmake -S "$WORK/lzfse" -B "$WORK/lzfse-build" -G Ninja -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" 2>&1 | tee "$LOG/lzfse.log"
cmake --build "$WORK/lzfse-build" -j2 2>&1 | tee -a "$LOG/lzfse.log"
cmake --install "$WORK/lzfse-build" 2>&1 | tee -a "$LOG/lzfse.log"
for spec in libplist:fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4 libimobiledevice-glue:10ddafa16458a012bcbd3e83a6ab36a032dc84d8 libtatsu:e7d6ad13ef928aa609d0ccdfc586f7d6e8e049bf libimobiledevice:fa0f79190142bc309307967c058f89c1b36eb6b8; do
    name=$(echo "$spec" | cut -d: -f1); ref=$(echo "$spec" | cut -d: -f2)
    clone "https://github.com/libimobiledevice/$name.git" "$ref" "$WORK/$name"
    stage "Build and install $name"
    (cd "$WORK/$name"; ./autogen.sh --prefix="$PREFIX" --without-cython; make -j2; make install) 2>&1 | tee "$LOG/$name.log"
done

# Reproducible Linux-only changes are inserted below, never the Windows port.
stage 'Apply checked Linux source changes'
python3 - "$ROOT" <<'PY'
import pathlib,sys
r=pathlib.Path(sys.argv[1]); q=r/'qemu'
def replace(path, old, new):
    text=path.read_text()
    assert text.count(old)==1, f'Unexpected patch anchor: {path}: {old!r}'
    path.write_text(text.replace(old,new))
p=q/'hw/arm/apple-silicon/meson.build'
replace(p,"    'a13_gxf.c',\n",'')
with p.open('a') as f:
    f.write("\nif config_all_devices.has_key('CONFIG_APPLE_SOC') or config_all_devices.has_key('CONFIG_VRESEARCH101')\n  arm_common_ss.add(files('a13_gxf.c'))\nendif\n")
p=q/'configs/devices/aarch64-softmmu/vphone.mak'
assert not p.exists()
p.write_text('CONFIG_VRESEARCH101=y\nCONFIG_ARM_GIC=y\nCONFIG_VIRTIO_PCI=y\nCONFIG_VIRTIO_BLK=y\nCONFIG_VIRTIO_NET=y\nCONFIG_USB=y\nCONFIG_USB_XHCI=y\nCONFIG_USB_XHCI_PCI=y\nCONFIG_USB_HUB=y\nCONFIG_USB_HID=y\n')
replace(q/'monitor/hmp-cmds-target.c', "if (format == 'i') {\n        assert_not_reached();", "if (format == 'i') {\n        monitor_printf(mon, \"Instruction disassembly is not supported by this build\\n\");\n        return;")
p=q/'hw/virtio/virtio-qmp.c'
text=p.read_text(); marker='VirtioDeviceFeatures *qmp_decode_features('
assert text.count(marker)==1
start=text.index(marker); end=text.index('    features->has_unknown_dev_features',start)
old='default:\n        assert_not_reached();'
assert text[start:end].count(old)==1
p.write_text(text[:start]+text[start:end].replace(old,'default:\n        /* Keep vendor-specific feature bits in unknown_dev_features below. */\n        break;')+text[end:])
replace(r/'linux-create/Shims/LinuxSys/include/linuxsys.h', '#endif', 'void *vl_memmem(const void *, size_t, const void *, size_t);\n#endif')
p=r/'linux-create/Shims/LinuxSys/linuxsys.c'
text=p.read_text(); assert 'vl_memmem' not in text and text.startswith('#define _GNU_SOURCE\n')
p.write_text(text+'\n#include <string.h>\nvoid *vl_memmem(const void *h, size_t n, const void *p, size_t m) { return memmem(h,n,p,m); }\n')
p=r/'linux-create/Shims/VLDarwin/VLDarwin.swift'
text=p.read_text(); assert 'public func memmem(' not in text and 'import LinuxSys' in text
p.write_text(text+'\npublic func memmem(_ h: UnsafeRawPointer?, _ n: Int, _ p: UnsafeRawPointer?, _ m: Int) -> UnsafeMutableRawPointer? { vl_memmem(h,n,p,m) }\n')
replace(r/'run-vphone.sh', '  -serial mon:stdio', '  -serial "file:$CI_SERIAL_LOG"\n  -monitor none')
p=r/'linux-create/overlay/MobileRestoreCore/Recovery/vphone_linux_bootargs.h'
text=p.read_text(); assert 'vphone_linux_boot_args(const char *base)' in text and 'vphone_linux_set_boot_args' not in text
p.write_text('/* vphone-linux: restore boot-args plus VPHONE_RESTORE_BOOT_ARGS_EXTRA (diagnostics, e.g. serial=3). */\n#ifndef VPHONE_LINUX_BOOTARGS_H\n#define VPHONE_LINUX_BOOTARGS_H\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <libirecovery.h>\n#include "idevicerestore.h"\n\nstatic inline char *vphone_linux_boot_args(const char *base)\n{\n    const char *extra = getenv("VPHONE_RESTORE_BOOT_ARGS_EXTRA");\n    if (!extra || !*extra) {\n        return strdup(base);\n    }\n    size_t n = strlen(base) + strlen(extra) + 2;\n    char *s = malloc(n);\n    if (s) {\n        snprintf(s, n, "%s %s", base, extra);\n    }\n    return s;\n}\n\nstatic inline irecv_error_t vphone_linux_set_boot_args(irecv_client_t client, const char *command, const char *requested)\n{\n    irecv_error_t result = irecv_send_command(client, command);\n    const char *extra = getenv("VPHONE_RESTORE_BOOT_ARGS_EXTRA");\n    if (extra) {\n        logger(LL_INFO, "[vphone-linux] restore boot-args requested: %s (set result %d)\\n", requested, result);\n    }\n    if (result != IRECV_E_SUCCESS) {\n        logger(LL_ERROR, "Unable to set restore boot-args (%d)\\n", result);\n        return result;\n    }\n    if (extra) {\n        char *actual = NULL;\n        irecv_error_t observed = irecv_getenv(client, "boot-args", &actual);\n        logger(LL_INFO, "[vphone-linux] restore boot-args observed: %s (get result %d)\\n", actual ? actual : "(unavailable)", observed);\n        free(actual);\n    }\n    return result;\n}\n#endif\n')
replace(r/'linux-create/edits/MobileRestoreCore.txt', "# Scale idevicerestore's device-event waits for emulation (Core/vphone_linux_timeout.h).\n", "Recovery/recovery.c\ts/recovery_error = irecv_send_command\\(client->recovery->client, setba\\);/recovery_error = vphone_linux_set_boot_args(client->recovery->client, setba, client->restore_boot_args);\\n\\t\\tif (recovery_error != IRECV_E_SUCCESS) {\\n\\t\\t\\treturn -1;\\n\\t\\t}/\n# Scale idevicerestore's device-event waits for emulation (Core/vphone_linux_timeout.h).\n")
PY
mkdir "$WORK/qemu-build"
stage 'Configure and build CPU-only QEMU'
(cd "$WORK/qemu-build"; "$ROOT/qemu/configure" --python="$WORK/python/bin/python" --target-list=aarch64-softmmu --with-devices-aarch64=vphone --without-default-devices --without-default-features --enable-tcg --enable-lzfse --enable-pixman --enable-fdt=system --enable-nettle --disable-pvg --disable-tools --disable-werror; ninja -j2 qemu-system-aarch64) 2>&1 | tee "$LOG/qemu-build.log"
grep -Eq '^#define CONFIG_NETTLE([[:space:]]+1)?[[:space:]]*$' "$WORK/qemu-build/config-host.h"
cp "$WORK/qemu-build/qemu-system-aarch64" "$PREFIX/bin/"
export QEMU="$PREFIX/bin/qemu-system-aarch64"
cp "$GITHUB_WORKSPACE/tools/Package.resolved" "$ROOT/linux-create/Package.resolved"
stage 'Build the pinned Linux firmware CLI with Swift'
(cd "$ROOT/linux-create"; VPHONE_CLI="$WORK/vphone-cli" bash sync-sources.sh; rm Shims/libarchive/lib/libarchive.so; ln -s /usr/lib/x86_64-linux-gnu/libarchive.so.13 Shims/libarchive/lib/libarchive.so; swift build -c release -j2 --force-resolved-versions --build-system swiftbuild --scratch-path .build/out -Xcc "-I$PREFIX/include" -Xlinker "-L$PREFIX/lib") 2>&1 | tee "$LOG/swift-build.log"
cp "$ROOT/linux-create/.build/out/out/Products/Release-linux-x86_64/vphone-cli" "$PREFIX/bin/"
VC="$PREFIX/bin/vphone-cli"
clone https://github.com/libimobiledevice/usbmuxd.git "$USBMUXD_REF" "$ROOT/.build/usbmuxd-32k/src"
stage 'Build usbmuxd with the 32 KiB USB MTU'
(cd "$ROOT"; bash tools/build-usbmuxd-32k.sh) 2>&1 | tee "$LOG/usbmuxd-build.log"
mkdir "$WORK/7zip"
fetch "$SEVEN_URL" "$WORK/7zip.tar.xz" "$SEVEN_SHA"
tar -xJf "$WORK/7zip.tar.xz" -C "$WORK/7zip" 7zz
mkdir -p "$ROOT/OpenAVB" "$ROOT/OpenSEP"
cp "$WORK/vphone-cli/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/OpenAVB.bin" "$ROOT/OpenAVB/"
cp "$WORK/vphone-cli/VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/OpenSEP.bin" "$ROOT/OpenSEP/"
echo "bbcabe73fd39fb92b96fbb4c661c1a15b0f9e5d9411468f7954c4f433911cb9c  $ROOT/OpenAVB/OpenAVB.bin" | sha256sum -c -
echo "92690b9c7e900ec0054271dbbc0444ee2d8567c8d41d3a2e491ba011e2b08b12  $ROOT/OpenSEP/OpenSEP.bin" | sha256sum -c -
stage 'Download the pinned cloudOS IPSW and prepare a fresh 4 GiB VM'
fetch "$CLOUD_URL" "$WORK/cloudOS.ipsw" "$CLOUD_SHA"
(cd "$ROOT"; MEM_GIB=4 CPUS=8 bash tools/new-vm.sh vms/gpu-recovery)
unzip -q "$WORK/cloudOS.ipsw" -d "$VM/iPhonePCC_Restore"
python3 - "$VM/iPhonePCC_Restore/BuildManifest.plist" "$VM/config.plist" <<'PY'
import plistlib,sys
config=plistlib.load(open(sys.argv[2],'rb'))
assert config['memorySize']==4<<30 and config['cpuCount']==8
p=sys.argv[1]; m=plistlib.load(open(p,'rb')); t=m.get('SupportedProductTypes',[])
if 'iPhone99,11' not in t: m['SupportedProductTypes']=t+['iPhone99,11']; plistlib.dump(m,open(p,'wb'))
PY
rm -rf -- "$WORK/qemu-build" "$ROOT/linux-create/.build" "$WORK/swift.tar.gz"
check_resources
stage 'Start the temporary cloudOS VM and USB helpers'
systemctl stop usbmuxd.service 2>/dev/null || true
[[ ! -e /var/run/usbmuxd ]]
"$ROOT/.build/usbmuxd-32k/usbmuxd" -f -v -S /var/run/usbmuxd -P "$WORK/usbmuxd.pid" -l "$LOG/usbmuxd.log" & mux_pid=$!
cd "$ROOT"
CID=0 SMP=8 MEM=4G TB_SIZE=512 GFX=0 WINDOW=0 CI_SERIAL_LOG="$LOG/serial.log" LOG="$LOG/qemu.log" DFLAGS=guest_errors bash run-vphone.sh "$VM" -qmp "unix:$SOCK,server=on,wait=off" -chardev "socket,id=vusb,path=$WORK/vusb.sock,server=on,wait=off" -global vresearch-vusb.chardev=vusb > "$LOG/qemu-stdout.log" 2> "$LOG/qemu-stderr.log" & qemu_pid=$!
echo "$qemu_pid" > "$WORK/qemu.pid"
(
    minimum=999999999
    while kill -0 "$qemu_pid" 2>/dev/null; do
        available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        (( available >= minimum )) || minimum=$available
        printf '%s availableKiB=%s minimumKiB=%s\n' "$(date -u +%FT%TZ)" "$available" "$minimum" >> "$LOG/memory.log"
        if (( available < 2304*1024 )); then
            echo 'Host reserve breached' >> "$LOG/memory.log"
            kill -TERM "$qemu_pid"
            [[ ! -f "$WORK/restore.pid" ]] || kill -TERM "$(cat "$WORK/restore.pid")"
            exit 1
        fi
        sleep 2
    done
) & guard_pid=$!
for _ in $(seq 1 30); do [[ ! -S "$WORK/vusb.sock" ]] || break; sleep 1; done
[[ -S "$WORK/vusb.sock" ]]
qmp query-status > "$LOG/qmp.log"
sleep 20
VUSB_URB_TIMEOUT=300 python3 -u tools/vusb-usbip.py "$WORK/vusb.sock" > "$LOG/usbip.log" 2>&1 & exporter_pid=$!
bash tools/usbip-autoattach.sh > "$LOG/attach.log" 2>&1 & attacher_pid=$!
for _ in $(seq 1 60); do "$VC" recovery-probe > "$LOG/probe.log" 2>&1 && break; sleep 3; done
"$VC" recovery-probe >> "$LOG/probe.log" 2>&1
stage 'Restore stock cloudOS (up to 65 minutes; streaming restore.log)'
VPHONE_RESTORE_TIMEOUT_SCALE=30 VPHONE_RESTORE_BOOT_ARGS_EXTRA='-restore serial=3 -v' timeout --kill-after=15s 65m "$VC" restore -l "$ROOT/vms" gpu-recovery -v > "$LOG/restore.log" 2>&1 & restore_pid=$!
echo "$restore_pid" > "$WORK/restore.pid"
tail --pid="$restore_pid" -n +1 -F "$LOG/restore.log" & restore_log_pid=$!
wait "$restore_pid"
wait "$restore_log_pid"
restore_log_pid=
restore_pid=
grep -q 'Restore Finished' "$LOG/restore.log"
stage 'Restore finished; stop the VM and extract the GPU driver'
kill -TERM "$guard_pid"; wait "$guard_pid" 2>/dev/null || true; guard_pid=
stop_vm
mkdir "$WORK/extracted"
BUNDLE=Volume1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle
"$WORK/7zip/7zz" x "$VM/Disk.img" -o"$WORK/extracted" "$BUNDLE" -r -y 2>&1 | tee "$LOG/7zip.log"
[[ -f "$WORK/extracted/$BUNDLE/AppleParavirtGPUMetalIOGPUFamily" ]]
tar -cf "$OUT/AppleParavirtGPUMetalIOGPUFamily.bundle.tar" -C "$WORK/extracted/Volume1/System/Library/Extensions" AppleParavirtGPUMetalIOGPUFamily.bundle
(cd "$OUT"; sha256sum AppleParavirtGPUMetalIOGPUFamily.bundle.tar inputs.json > SHA256SUMS)
echo 'Driver extracted; only bundle tar, checksums, manifest, and bounded logs will be uploaded.'
