#!/bin/bash
# فحص ما قبل البناء — يمنع بناء حزمة قديمة أو ناقصة.
# يُشغّله Xcode تلقائيًا (preBuildScripts) ويمكن تشغيله يدويًا:  bash scripts/preflight.sh
set -u
cd "${SRCROOT:-$(dirname "$0")/..}" 2>/dev/null || true

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
fail=0

VER="$(sed -n 's/^الإصدار:[[:space:]]*//p' PAYLOAD-VERSION.txt 2>/dev/null | head -1)"
echo "────────────────────────────────────────────────────────"
echo " فحص الحزمة قبل البناء — PREFLIGHT"
echo " الإصدار: ${VER:-لا يوجد PAYLOAD-VERSION.txt}"
echo " الـcommit: $(git log -1 --format='%h %ci %s' 2>/dev/null || echo '(مستودع بلا .git أو نسخة مضغوطة)')"
echo "────────────────────────────────────────────────────────"

# 1) بصمة الإصدار: يجب أن تكون fix3 أو أحدث (تحوي إصلاحات طبقة التطبيق)
case "${VER}" in
  *fix3*|*fix4*|*fix5*|*fix6*|*fix7*|*fix8*|*fix9*) : ;;
  "")  echo -e "${RED}✗ الحزمة قديمة: لا يوجد PAYLOAD-VERSION.txt${NC}"; fail=1 ;;
  *)   echo -e "${RED}✗ الحزمة قديمة: الإصدار '${VER}' أقدم من fix3 (إصلاحات طبقة التطبيق)${NC}"; fail=1 ;;
esac

# 2) علامات الإصلاح الأساسية
check() { # $1=وصف  $2=ملف  $3=نص يجب وجوده
  if [ ! -f "$2" ]; then echo -e "${RED}✗ ناقص: $2${NC}"; fail=1; return; fi
  if grep -qF "$3" "$2"; then echo -e "${GRN}✓${NC} $1"
  else echo -e "${RED}✗ الحزمة قديمة: '$2' لا يحوي '$3'${NC}"; fail=1; fi
}
check 'وسائط LogRadio بأسمائها الصحيحة (hits:)' FieldwatchApp/Sources/FieldwatchStore.swift 'hits: $0.hitCount'
check 'Sighting من النواة يحقق Identifiable'      FieldwatchApp/Sources/FieldwatchStore.swift 'extension FieldwatchCore.Sighting: Identifiable'
check 'لا تعارض أسماء: النوع المحلي BleRow'        FieldwatchApp/Sources/BleScanner.swift      'struct BleRow'
check 'إصلاح count(where:) — Swift 5 على CI'       FieldwatchCore/Sources/FieldwatchCore/SignatureCandidates.swift 'usable.filter'

# 3) مطابقة البصمة الرقمية لكل ملف (تكشف رفعًا ناقصًا أو مختلطًا)
if [ -f PAYLOAD-MANIFEST.sha256 ]; then
  if shasum -a 256 -c PAYLOAD-MANIFEST.sha256 > /tmp/preflight-manifest.log 2>&1; then
    echo -e "${GRN}✓${NC} بصمة كل ملفات الحزمة مطابقة ($(grep -c . PAYLOAD-MANIFEST.sha256) ملفًا)"
  else
    echo -e "${RED}✗ ملفات الحزمة لا تطابق البصمة — الرفع ناقص أو مختلط:${NC}"
    grep -v ': OK$' /tmp/preflight-manifest.log | head -12 | sed 's/^/    /'
    fail=1
  fi
else
  echo -e "${YEL}⚠ لا يوجد PAYLOAD-MANIFEST.sha256 (لن أتحقق من تطابق الملفات)${NC}"
fi

echo "────────────────────────────────────────────────────────"
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}✗✗ فشل فحص الحزمة: هذه ليست الحزمة الصحيحة.${NC}"
  echo    "    ارفع fieldwatch-payload.zip الأحدث إلى جذر المستودع ثم شغّل من الـcommit الجديد."
  echo    "    (تأكد أن الحزمة القديمة حُذفت/استُبدلت وأنك لا تعيد تشغيل commit قديم)"
  echo "PREFLIGHT-FAILED"
  exit 1
fi
echo -e "${GRN}✓✓ الحزمة الصحيحة. متابعة البناء.${NC}"
echo "PREFLIGHT-OK ${VER}"
exit 0
