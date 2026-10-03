#!/usr/bin/env bash
#
# build-all.sh — يبني كل شيء مرة واحدة من نفس المصدر:
#
#   out/Fieldwatch.app                          (التطبيق)
#   out/Fieldwatch-unsigned.ipa                 (بلا صلاحيات: للتثبيت العادي/AppSync)
#   out/Fieldwatch-trollstore.ipa               (موقّع بصلاحيات: TrollStore يحفظها)
#   out/Fieldwatch-1.1.17-rootless.deb          (iphoneos-arm64 → /var/jb)
#   out/Fieldwatch-1.1.17-rootful.deb           (iphoneos-arm  → /)
#
# المنطق: نبني التطبيق مرة واحدة، ثم نغيّر الصلاحيات ونعيد التغلّف لكل هدف.
# هكذا لا نبني مرتين ولا تختلف النسخ عن بعضها.
#
# المتطلبات على macOS: xcodegen، واختياريًا ldid (brew install ldid)، و dpkg (brew install dpkg)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${ROOT}/out"
ENT_DIR="${ROOT}/entitlements"
SIGN_ENT="${SIGN_ENT:-${ENT_DIR}/10-unsandbox.entitlements}"

echo "═══════════════════════════════════════════════════════════"
echo " 1/4  بناء التطبيق (بلا صلاحيات) — للإصدار العادي"
echo "═══════════════════════════════════════════════════════════"
ENTITLEMENTS="" APP_OUT="${OUT}" bash scripts/build-app.sh
bash scripts/build-ipa.sh --app "${OUT}/Fieldwatch.app" --out "${OUT}/Fieldwatch-unsigned.ipa"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 2/4  بناء التطبيق موقّعًا بصلاحيات (${SIGN_ENT##*/}) — لـ TrollStore و DEB"
echo "═══════════════════════════════════════════════════════════"
ENTITLEMENTS="${SIGN_ENT}" APP_OUT="${OUT}/signed" bash scripts/build-app.sh
bash scripts/build-ipa.sh --app "${OUT}/signed/Fieldwatch.app" --out "${OUT}/Fieldwatch-trollstore.ipa"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 3/4  حزمة DEB للـ jailbreak الحديث (rootless · iphoneos-arm64 · /var/jb)"
echo "═══════════════════════════════════════════════════════════"
bash scripts/build-deb.sh --app "${OUT}/signed/Fieldwatch.app" --variant rootless

echo
echo "═══════════════════════════════════════════════════════════"
echo " 4/4  حزمة DEB للـ jailbreak القديم (rootful · iphoneos-arm · الجذر)"
echo "═══════════════════════════════════════════════════════════"
bash scripts/build-deb.sh --app "${OUT}/signed/Fieldwatch.app" --variant rootful

echo
echo "═══════════════════════════════════════════════════════════"
echo " الناتج:"
echo "═══════════════════════════════════════════════════════════"
ls -lh "${OUT}"/*.ipa "${OUT}"/*.deb 2>/dev/null | awk '{printf "  %-52s %s\n", $9, $5}'
echo
echo "أي ملف تختار؟ انظر: ios/docs/IPA-vs-DEB-AR.md"
