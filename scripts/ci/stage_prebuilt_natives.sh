#!/bin/bash
# Stage Husk's heavy native parts from a published Husk IPA, so the app can be built without compiling them.
#
# QEMU, ANGLE, MoltenVK, the PS4 layer, the Android system files, the Java runtime and the guest kernel take hours and
# tens of gigabytes to build (scripts/ci_build.sh), which a hosted GitHub runner cannot give. None of them is the app:
# the app's own Swift and C (src/app, src/translation-layer*, src/rppairing-ios) are still built from this checkout.
# This puts each prebuilt part where project.yml and scripts/package_ipa.sh look for it.
#
# Usage: scripts/ci/stage_prebuilt_natives.sh path/to/Husk.ipa
set -euo pipefail

IPA="${1:?usage: $0 Husk.ipa}"
HUSK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking $(basename "$IPA")"
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/Husk.app"
[ -d "$APP" ] || { echo "no Payload/Husk.app in $IPA" >&2; exit 1; }

LIB="$HUSK_ROOT/build/ios-arm64/lib"
SYSLIB="$HUSK_ROOT/build/ios-arm64/sysroot/lib"
GUEST="$HUSK_ROOT/guests/phase0"
BIOS="$HUSK_ROOT/third_party/build/qemu-10.0.12-utm/pc-bios"
mkdir -p "$LIB" "$SYSLIB" "$GUEST" "$BIOS"

need() { [ -e "$1" ] || { echo "the IPA has no ${1#$APP/}" >&2; exit 1; }; }

# Dylibs: QEMU is linked, ANGLE and the PS4 layer are only embedded. Their old signatures are dropped; package_ipa.sh
# signs everything again.
for f in libqemu-aarch64-softmmu.dylib libANGLE-shared.dylib libhuskps4.dylib; do need "$APP/Frameworks/$f"; done
cp "$APP/Frameworks/libqemu-aarch64-softmmu.dylib" "$LIB/"
cp "$APP/Frameworks/libhuskps4.dylib" "$LIB/"
cp "$APP/Frameworks/libANGLE-shared.dylib" "$SYSLIB/"
for f in "$LIB/libqemu-aarch64-softmmu.dylib" "$LIB/libhuskps4.dylib" "$SYSLIB/libANGLE-shared.dylib"; do
    codesign --remove-signature "$f" 2>/dev/null || true
done

# MoltenVK ships in the app as a framework; project.yml embeds it from an xcframework.
need "$APP/Frameworks/MoltenVK.framework"
FW="$WORK/MoltenVK.framework"
ditto "$APP/Frameworks/MoltenVK.framework" "$FW"
rm -rf "$FW/_CodeSignature"
codesign --remove-signature "$FW/MoltenVK" 2>/dev/null || true
rm -rf "$LIB/MoltenVK.xcframework"
xcodebuild -create-xcframework -framework "$FW" -output "$LIB/MoltenVK.xcframework" >/dev/null

# The Phase 0 guest kernel, and QEMU's option ROMs and UEFI firmware (the project's pre-build script copies these).
need "$APP/vmlinuz-virt"; need "$APP/initramfs-virt"; need "$APP/edk2-aarch64-code.fd"
cp "$APP/vmlinuz-virt" "$APP/initramfs-virt" "$GUEST/"
cp "$APP"/pc-bios/*.rom "$BIOS/"
bzip2 -c "$APP/edk2-aarch64-code.fd" > "$BIOS/edk2-aarch64-code.fd.bz2"

# Android's fonts and certificates, and the Dalvik runtime with Husk's Java framework.
need "$APP/android-system"; need "$APP/java-runtime/husk-framework.dex"
rm -rf "$HUSK_ROOT/build/android-system" "$HUSK_ROOT/build/java-runtime"
ditto "$APP/android-system" "$HUSK_ROOT/build/android-system"
ditto "$APP/java-runtime" "$HUSK_ROOT/build/java-runtime"

echo "==> staged:"
du -sh "$LIB"/* "$SYSLIB/libANGLE-shared.dylib" "$GUEST" "$BIOS" \
       "$HUSK_ROOT/build/android-system" "$HUSK_ROOT/build/java-runtime" | sed 's|'"$HUSK_ROOT"'/||'
