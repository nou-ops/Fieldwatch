import re, glob, sys

core_src = "\n".join(open(p, encoding='utf-8').read() for p in glob.glob('FieldwatchCore/Sources/FieldwatchCore/*.swift'))
app_files = sorted(glob.glob('FieldwatchApp/Sources/*.swift'))

# ── 1) فهرسة أنواع النواة (public init) ──
core_types = {}
for p in glob.glob('FieldwatchCore/Sources/FieldwatchCore/*.swift'):
    s = open(p, encoding='utf-8').read()
    for m in re.finditer(r'public (?:struct|final class|class|enum) (\w+)', s):
        name, rest = m.group(1), s[m.end():]
        im = re.search(r'public init\s*\(', rest)
        if not im: continue
        i, depth, buf = im.end(), 1, ''
        while i < len(rest) and depth > 0:
            c = rest[i]
            if c == '(': depth += 1
            if c == ')': depth -= 1
            if depth > 0: buf += c
            i += 1
        d, cur, chunks = 0, '', []
        for ch in buf:
            if ch in '([{<': d += 1
            elif ch in ')]}>': d -= 1
            if ch == ',' and d == 0: chunks.append(cur); cur = ''
            else: cur += ch
        chunks.append(cur)
        labels = []
        for c in chunks:
            lm = re.match(r'\s*(\w+)\s*:', c)
            labels.append(lm.group(1) if lm else '_')
        if labels and labels[-1] == '_': labels.pop()   # trailing closure
        core_types[name] = labels

# ── 2) فهرسة أنواع التطبيق المحلية (memberwise) ──
def local_types(path):
    s = open(path, encoding='utf-8').read()
    out = {}
    for m in re.finditer(r'(?:^|\n)\s*(?:struct|final class|class)\s+(\w+)[^{]*\{', s):
        name, rest = m.group(1), s[m.end():]
        body = rest.split('\nfunc ')[0]
        props = re.findall(r'^\s*(?:public |private |fileprivate |internal )?(?:var|let)\s+(\w+)\s*:\s*[^={\n]+$', body, re.M)
        if props: out[name] = props
    return out

def calls(text, name):
    res = []
    for m in re.finditer(r'(?<![\w.])' + re.escape(name) + r'\s*\(', text):
        i, depth, buf = m.end(), 1, ''
        while i < len(text) and depth > 0:
            c = text[i]
            if c in '([{': depth += 1
            elif c in ')]}': depth -= 1
            if depth > 0: buf += c
            i += 1
        res.append((m.start(), buf))
    return res

problems = []
for p in app_files:
    s = open(p, encoding='utf-8').read()
    ltypes = local_types(p)
    for name, decl in core_types.items():
        if not decl or name in ltypes: continue
        for pos, buf in calls(s, name):
            d, cur, chunks = 0, '', []
            for ch in buf:
                if ch in '([{': d += 1
                elif ch in ')]}': d -= 1
                if ch == ',' and d == 0: chunks.append(cur); cur = ''
                else: cur += ch
            chunks.append(cur)
            got = []
            for c in chunks:
                lm = re.match(r'\s*(\w+)\s*:', c)
                got.append(lm.group(1) if lm else None)
            got = [g for g in got if g]
            if not got: continue
            line = s[:pos].count('\n') + 1
            unknown = [g for g in got if g not in decl]
            if unknown:
                problems.append(f'{p}:{line}  {name}(…)  وسائط غير معروفة: {unknown}')
                continue
            idx = -1; ok = True
            for g in got:
                j = decl.index(g)
                if j < idx: ok = False
                idx = max(idx, j)
            if not ok:
                problems.append(f'{p}:{line}  {name}(…)  ترتيب مخالف | المُرسَل: {got} | التعريف: {decl}')

# ── 3) أنواع محلية: تحقق العدد (فائض/نقص) ──
for p in app_files:
    s = open(p, encoding='utf-8').read()
    for name, props in local_types(p).items():
        for pos, buf in calls(s, name):
            d, cur, chunks = 0, '', []
            for ch in buf:
                if ch in '([{': d += 1
                elif ch in ')]}': d -= 1
                if ch == ',' and d == 0: chunks.append(cur); cur = ''
                else: cur += ch
            chunks.append(cur)
            got = [re.match(r'\s*(\w+)\s*:', c).group(1) for c in chunks if re.match(r'\s*(\w+)\s*:', c)]
            if not got: continue
            line = s[:pos].count('\n') + 1
            bad = [g for g in got if g not in props]
            if bad:
                problems.append(f'{p}:{line}  {name}(…) [محلي] وسائط غير معروفة: {bad} | المتوقع: {props}')

# ── 4) متطلبات بروتوكولات SwiftUI: .sheet(item:) ⇒ النوع يحقق Identifiable ──
all_src = {p: open(p, encoding='utf-8').read() for p in app_files}
core_all = core_src
def conforms(tname):
    pat = rf'(?:struct|final class|class|enum)\s+{re.escape(tname)}\b[^{{\n]*\bIdentifiable\b|extension\s+(?:\w+\.)?{re.escape(tname)}\s*:[^{{\n]*\bIdentifiable\b'
    return bool(re.search(pat, "\n".join(all_src.values()) + "\n" + core_all))
for p, s in all_src.items():
    for m in re.finditer(r'\.(sheet|fullScreenCover|popover)\(item:\s*\$(\w+)', s):
        var = m.group(2)
        tm = re.search(rf'(?:var|let)\s+{re.escape(var)}\s*:\s*([\w\.]+)\??', s)
        tname = tm.group(1).split('.')[-1] if tm else None
        line = s[:m.start()].count('\n') + 1
        if not tname:
            problems.append(f'{p}:{line}  {m.group(1)}(item: ${var}) — لم أستطع تحديد النوع')
        elif not conforms(tname):
            problems.append(f'{p}:{line}  {m.group(1)}(item: ${var}) — النوع {tname} لا يحقق Identifiable')

# ── 5) واجهات أحدث من هدف iOS 16 ──
NEW_APIS = {
    'containerRelativeFrame': 'iOS 17', 'symbolEffect': 'iOS 17', 'ContentUnavailableView': 'iOS 17',
    'scrollBounceBehavior': 'iOS 16.4', 'fontDesign': 'iOS 16.1', 'fontWidth': 'iOS 16.0',
    'MapCameraPosition': 'iOS 17', 'onChange(of:initial:)': 'iOS 17', 'topBarTrailing': 'iOS 17',
    'topBarLeading': 'iOS 17', 'inspector': 'iOS 17', 'SwiftData': 'iOS 17', 'Observable()': 'iOS 17',
}
for p in app_files:
    for i, ln in enumerate(open(p, encoding='utf-8'), 1):
        for api, ver in NEW_APIS.items():
            if api in ln and not ln.strip().startswith('//'):
                problems.append(f'{p}:{i}  واجهة {api} تحتاج {ver} (هدفنا iOS 16)')

# ── 6) وصول لأعضاء النواة غير العامة ──
for p in app_files:
    s = open(p, encoding='utf-8').read()
    for m in re.finditer(r'\b([A-Z]\w{3,})\.(\w+)', s):
        t, mem = m.group(1), m.group(2)
        if t not in core_types: continue
        pat = rf'(public\s+)?(?:static\s+)?(?:func|var|let)\s+{re.escape(mem)}\b'
        hits = re.findall(pat, core_src)
        if hits and not any(h == 'public ' for h in hits):
            line = s[:m.start()].count('\n') + 1
            problems.append(f'{p}:{line}  {t}.{mem} غير عام (internal) في النواة')

print(f'أنواع النواة: {len(core_types)} | ملفات التطبيق: {len(app_files)}')
if problems:
    print(f'⚠️ {len(problems)} نتيجة:')
    for x in problems: print('  •', x)
else:
    print('✅ لا نتائج')
