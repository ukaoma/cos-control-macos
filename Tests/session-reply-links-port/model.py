"""0.5.380: a line-for-line Python transliteration of Sources/SessionReplyLinks.swift, on UTF-16 unit lists (JavaScript strings
are UTF-16). Keep it in step with the Swift; harness.py compares it with the server."""
NL, CR, TAB, SPACE = 0x0A, 0x0D, 0x09, 0x20
BANG, QUOTE, HASH, PERCENT, APOS = 0x21, 0x22, 0x23, 0x25, 0x27
OPENP, CLOSEP, DASH, SLASH, COLON = 0x28, 0x29, 0x2D, 0x2F, 0x3A
LT, GT, OPENB, BACKSLASH, CLOSEB = 0x3C, 0x3E, 0x5B, 0x5C, 0x5D
BACKTICK, TILDE = 0x60, 0x7E
SCAN = 128 * 1024
LABEL_SPAN, TARGET_MAX, WORDS_MAX = 250, 4096, 120


def u16(s):
    b = s.encode("utf-16-le", "surrogatepass")
    return [b[k] | (b[k + 1] << 8) for k in range(0, len(b), 2)]


def from16(units):
    """String(decoding:as: UTF16.self): a lone surrogate becomes U+FFFD."""
    return bytes(x for u in units for x in (u & 0xFF, u >> 8)).decode("utf-16-le", "replace")


U = lambda s: u16(s)
COMMENT_OPEN, COMMENT_CLOSE = U("<!--"), U("-->")


def index_of(t, needle, start):
    k = max(start, 0)
    while k + len(needle) <= len(t):
        if starts_with(t, needle, k):
            return k
        k += 1
    return None


def starts_with(t, prefix, k):
    if k < 0 or k + len(prefix) > len(t):
        return False
    return all(t[k + m] == u for m, u in enumerate(prefix))


class NextIndex:
    def __init__(self, text, needle):
        self.text, self.needle, self.frm, self.found = text, needle, float("inf"), None

    def __call__(self, start):
        if start >= self.frm and (True if self.found is None else self.found >= start):
            return self.found
        self.frm = start
        self.found = index_of(self.text, self.needle, start)
        return self.found


def is_js_space(u):
    return 0x09 <= u <= 0x0D or u in (0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF) or 0x2000 <= u <= 0x200A


is_line_term = lambda u: u in (0x0A, 0x0D, 0x2028, 0x2029)
is_control = lambda u: u <= 0x1F or u == 0x7F
is_digit = lambda u: 0x30 <= u <= 0x39
is_space = lambda u: u in (SPACE, TAB)
is_letter = lambda u: 0x41 <= u <= 0x5A or 0x61 <= u <= 0x7A
lower = lambda u: u + 0x20 if 0x41 <= u <= 0x5A else u


def hexv(u):
    if 0x30 <= u <= 0x39: return u - 0x30
    if 0x41 <= u <= 0x46: return u - 0x41 + 10
    if 0x61 <= u <= 0x66: return u - 0x61 + 10
    return None


def may_have_token(t):
    prev = 0
    for u in t:
        if prev == CLOSEB and u == OPENP:
            return True
        prev = u
    return False


def indented(t, i):
    k = 0
    while k < 4 and i + k < len(t) and t[i + k] == SPACE:
        k += 1
    if k == 4:
        return True
    return i + k < len(t) and t[i + k] == TAB


def fence_run(t, i):
    limit = min(len(t), i + 80)
    k = i
    while k < limit and k - i < 3 and t[k] == SPACE:
        k += 1
    if not (k < limit and (t[k] == BACKTICK or t[k] == TILDE)):
        return None
    mark = t[k]
    e = k
    while e < limit and t[e] == mark:
        e += 1
    return t[k:e] if e - k >= 3 else None


def destination(text, start, angle_one_line, next_gt):
    n = len(text)
    j = start
    if j < n and text[j] == LT:
        e = next_gt(j + 1)
        if e is None or not (e + 1 < n) or text[e + 1] != CLOSEP:
            return None
        if angle_one_line and NL in text[j + 1:e]:
            return None
        return text[j + 1:e], e + 2
    depth = 1
    while j < n and j - start <= TARGET_MAX:
        if text[j] == NL: break
        if text[j] == OPENP: depth += 1
        if text[j] == CLOSEP:
            depth -= 1
            if depth == 0:
                return text[start:j], j + 1
        j += 1
    return None


def untitled(t):
    k = 0
    while k < len(t) and not is_js_space(t[k]): k += 1
    if not (k > 0 and k < len(t)): return None
    first = t[0:k]
    while k < len(t) and is_js_space(t[k]): k += 1
    if not (k < len(t) and t[k] == QUOTE and len(t) - k >= 2 and t[-1] == QUOTE): return None
    return None if QUOTE in t[k + 1:len(t) - 1] else first




def link_tokens(raw):
    text = raw[:SCAN]
    n = len(text)
    out = []
    fence, inline = [], 0
    next_close = NextIndex(text, [CLOSEB])
    next_gt = NextIndex(text, [GT])
    i = 0
    while i < n:
        try:
            if i == 0 or text[i - 1] == NL:
                if not fence and indented(text, i):
                    e = index_of(text, [NL], i)
                    if e is None: break
                    i = e; continue
                run = fence_run(text, i)
                if run is not None:
                    if not fence: fence = run
                    elif run[0] == fence[0] and len(run) >= len(fence): fence = []
                    e = index_of(text, [NL], i)
                    if e is None: break
                    i = e; continue
            if fence: continue
            if text[i] == BACKSLASH: i += 1; continue
            if text[i] == BACKTICK:
                r = 1
                while i + r < n and text[i + r] == BACKTICK: r += 1
                if inline == 0: inline = r
                elif inline == r: inline = 0
                i += r - 1; continue
            if inline != 0: continue
            if starts_with(text, COMMENT_OPEN, i):
                e = index_of(text, COMMENT_CLOSE, i + 4)
                if e is None: break
                i = e + 2; continue
            if text[i] != OPENB or (i > 0 and text[i - 1] == BANG): continue
            close = next_close(i + 1)
            if close is None or not (close - i <= LABEL_SPAN) or not (close + 1 < n) or text[close + 1] != OPENP: continue
            label = text[i + 1:close]
            if OPENB in label or NL in label: continue
            dest = destination(text, close + 2, True, next_gt)
            if dest is None: continue
            t, j = dest
            if not t or len(t) > TARGET_MAX or any(is_control(u) for u in t): continue
            ti = untitled(t)
            if ti is not None: t = ti
            out.append((i, j, label, t))
            i = j - 1
        finally:
            i += 1
    return out


def image_tokens(raw):
    text = raw[:SCAN]
    n = len(text)
    out = []
    fence, inline = [], 0
    next_end_label = NextIndex(text, [CLOSEB, OPENP])
    next_gt = NextIndex(text, [GT])
    i = 0
    while i < n:
        try:
            if i == 0 or text[i - 1] == NL:
                if not fence and indented(text, i):
                    e = index_of(text, [NL], i)
                    if e is None: break
                    i = e; continue
                run = fence_run(text, i)
                if run is not None:
                    if not fence: fence = run
                    elif run[0] == fence[0] and len(run) >= len(fence): fence = []
                    e = index_of(text, [NL], i)
                    if e is None: break
                    i = e; continue
            if fence: continue
            if text[i] == BACKSLASH: i += 1; continue
            if text[i] == BACKTICK:
                r = 1
                while i + r < n and text[i + r] == BACKTICK: r += 1
                if inline == 0: inline = r
                elif inline == r: inline = 0
                i += r - 1; continue
            if inline != 0: continue
            if starts_with(text, COMMENT_OPEN, i):
                e = index_of(text, COMMENT_CLOSE, i + 4)
                if e is None: break
                i = e + 2; continue
            if not (text[i] == BANG and i + 1 < n and text[i + 1] == OPENB): continue
            end_label = next_end_label(i + 2)
            if end_label is None or not (end_label - i <= LABEL_SPAN) or NL in text[i:end_label]: continue
            dest = destination(text, end_label + 2, False, next_gt)
            if dest is None: continue
            source, j = dest
            if not source or len(source) > TARGET_MAX or any(is_control(u) for u in source): continue
            if has_scheme(source) or starts_with(source, [SLASH, SLASH], 0) or BACKSLASH in source:
                i = j - 1; continue
            out.append((i, j, text[i + 2:end_label], source))
            i = j - 1
        finally:
            i += 1
    return out


def has_scheme(s):
    if not s or not is_letter(s[0]): return False
    k = 1
    while k < len(s):
        c = s[k]
        if c == COLON: return True
        if not (is_letter(c) or is_digit(c) or c in (0x2B, 0x2E, 0x2D)): return False
        k += 1
    return False


FILE = U("file://")


def starts_with_file_scheme(s):
    if len(s) < len(FILE): return False
    return all(lower(s[k]) == w for k, w in enumerate(FILE))


def is_local_target(t):
    if not t or t[0] == HASH or starts_with(t, [SLASH, SLASH], 0) or BACKSLASH in t: return False
    if starts_with_file_scheme(t): return True
    return not has_scheme(split_line_anchor(t)[0])


def digit_run(s, frm):
    k = frm
    while k < len(s) and is_digit(s[k]): k += 1
    return k - frm


def hash_line_tail(s, p):
    if not (p + 1 < len(s) and s[p] == HASH and s[p + 1] == 0x4C): return None
    d = digit_run(s, p + 2)
    if not (1 <= d <= 7): return None
    q = p + 2 + d
    if q < len(s) and s[q] == 0x43:
        c = digit_run(s, q + 1)
        if c < 1: return None
        q += 1 + c
    if q == len(s): return s[p + 2:p + 2 + d]
    if s[q] != DASH: return None
    r = q + 1
    if r < len(s) and s[r] == 0x4C: r += 1
    e = digit_run(s, r)
    if not (1 <= e <= 7 and r + e == len(s)): return None
    return s[p + 2:p + 2 + d]


def colon_line_tail(s, p):
    if not (p < len(s) and s[p] == COLON): return None
    d = digit_run(s, p + 1)
    if not (1 <= d <= 7): return None
    q = p + 1 + d
    digits = s[p + 1:q]
    if q == len(s): return digits
    e = digit_run(s, q + 1)
    if s[q] == COLON and 1 <= e <= 5 and q + 1 + e == len(s): return digits
    if s[q] == DASH and 1 <= e <= 7 and q + 1 + e == len(s): return digits
    return None


def first_tail(s, tail):
    p = 0
    while p <= len(s):
        d = tail(s, p)
        if d is not None: return p, d
        if p == len(s) or is_line_term(s[p]): return None
        p += 1
    return None


def line_number(digits):
    v = 0
    for d in digits: v = v * 10 + (d - 0x30)
    return None if v == 0 else v


def split_line_anchor(t):
    m = first_tail(t, hash_line_tail)
    if m is not None and m[0] > 0: return t[0:m[0]], line_number(m[1])
    m = first_tail(t, colon_line_tail)
    if m is not None and m[0] > 0 and t[m[0] - 1] != COLON: return t[0:m[0]], line_number(m[1])
    if HASH in t:
        h = t.index(HASH)
        if h > 0: return t[0:h], None
    return t, None


def js_trim(s):
    a, b = 0, len(s)
    while a < b and is_js_space(s[a]): a += 1
    while b > a and is_js_space(s[b - 1]): b -= 1
    return s[a:b]


def base_name(src):
    parts, cur = [], []
    for u in src:
        if u in (SLASH, BACKSLASH):
            if cur: parts.append(cur)
            cur = []
        else:
            cur.append(u)
    if cur: parts.append(cur)
    base = parts[-1] if parts else []
    clean = js_trim([u for u in base if not is_control(u)])
    return (clean if clean else U("File"))[:WORDS_MAX]


ROOTS = [U(r) for r in ("/Users/", "/private/", "/Volumes/", "/var/folders/")]


def names_mac_folder(s):
    for k in range(len(s)):
        if not (k == 0 or is_js_space(s[k - 1]) or s[k - 1] in (OPENP, BACKTICK, APOS, QUOTE)): continue
        if any(starts_with(s, r, k) for r in ROOTS): return True
    return False


def link_label(label, name):
    clean = js_trim([SPACE if is_control(u) else u for u in label])
    if not clean: return name
    if starts_with(clean, FILE, 0) or starts_with(clean, [TILDE, SLASH], 0) or clean[0] == SLASH or names_mac_folder(clean):
        return base_name(clean[len(FILE):] if starts_with(clean, FILE, 0) else clean)
    return clean[:WORDS_MAX]


def link_card_words(label, name, target):
    words = link_label(label, name)
    path, line = split_line_anchor(target)
    if line is None: return words
    own = base_name(path[7:] if starts_with_file_scheme(path) else path)
    return words + [COLON] + U(str(line)) if (words == own or words == name) else words


def has_percent_escape(s):
    if len(s) < 3: return False
    return any(s[k] == PERCENT and hexv(s[k + 1]) is not None and hexv(s[k + 2]) is not None for k in range(len(s) - 2))


def decode_uri_component(s):
    out, k, ln = [], 0, len(s)

    def byte(k):
        if not (k + 2 < ln and s[k] == PERCENT): return None
        h, l = hexv(s[k + 1]), hexv(s[k + 2])
        if h is None or l is None: return None
        return (h << 4) | l

    while k < ln:
        if s[k] != PERCENT:
            out.append(s[k]); k += 1; continue
        b = byte(k)
        if b is None: return None
        k += 3
        if b & 0x80 == 0:
            out.append(b); continue
        count = 0
        while count < 8 and ((b << count) & 0xFF) & 0x80 != 0: count += 1
        if not (count != 1 and count <= 4): return None
        cp = b & (0xFF >> (count + 1))
        for _ in range(1, count):
            c = byte(k)
            if c is None or c & 0xC0 != 0x80: return None
            cp = (cp << 6) | (c & 0x3F)
            k += 3
        minimum = 0x80 if count == 2 else 0x800 if count == 3 else 0x10000
        if not (cp >= minimum and cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF)): return None
        out.extend(U(chr(cp)))
    return out


def card_name(target):
    written = split_line_anchor(target)[0]
    last = written
    if has_percent_escape(written):
        d = decode_uri_component(written)
        if d is not None and d != written: last = d
    return base_name(last)


def card_words(tok):
    return link_card_words(tok[2], card_name(tok[3]), tok[3])


def blank(line):
    return all(is_space(u) or u == CR for u in line)


def emptied(line):
    a, b = 0, len(line)
    while a < b and (is_space(line[a]) or line[a] == CR): a += 1
    while b > a and (is_space(line[b - 1]) or line[b - 1] == CR): b -= 1
    core = line[a:b]
    if not core: return True
    if len(core) == 1: return core[0] in (0x2D, 0x2A, 0x2B)
    if not (core[-1] in (0x2E, 0x29) and len(core) - 1 <= 9): return False
    return all(is_digit(u) for u in core[:-1])


def collapse(units, removals, whole):
    if not removals: return units
    lines, starts, s = [], [], 0
    for k, u in enumerate(units):
        if u == NL:
            lines.append(units[s:k]); starts.append(s); s = k + 1
    lines.append(units[s:]); starts.append(s)
    touched, li = set(), 0
    for r in sorted(removals):
        while li + 1 < len(starts) and starts[li + 1] <= r: li += 1
        touched.add(li)
    kept, dropped = [], False
    for k, line in enumerate(lines):
        if k == len(lines) - 1 and not whole:
            kept.append(line); break
        if k in touched and emptied(line):
            dropped = True; continue
        if dropped and blank(line) and (blank(kept[-1]) if kept else True): continue
        if not blank(line): dropped = False
        kept.append(line)
    if dropped and whole:
        while kept and blank(kept[-1]): kept.pop()
    out = []
    for k, line in enumerate(kept):
        if k > 0: out.append(NL)
        out.extend(line)
    return out


def reader_units(all_):
    """readerText on units; returns None when the Swift returns `text` itself."""
    if not may_have_token(all_): return None
    cut = len(all_)
    if len(all_) > SCAN:
        cut = 0
        k = SCAN - 1
        while k >= 0:
            if all_[k] == NL: cut = k + 1; break
            k -= 1
    scanned = all_[0:cut]
    images = image_tokens(scanned)
    links = [l for l in link_tokens(scanned) if is_local_target(l[3]) and not any(l[0] < c[1] and c[0] < l[1] for c in images)]
    if not images and not links: return None
    edits = [(c[0], c[1], None) for c in images] + [(l[0], l[1], card_words(l)) for l in links]
    edits.sort(key=lambda e: e[0])
    out, removals, end = [], [], 0
    for start, stop, words in edits:
        if start < end: continue
        out.extend(scanned[end:start])
        end = stop
        if words is not None:
            out.extend(words); continue
        prev = out[-1] if out else None
        nxt = scanned[end] if end < len(scanned) else None
        if nxt is not None and is_space(nxt) and (prev is None or prev == NL or is_space(prev)):
            end += 1
        elif nxt is None or nxt == NL or nxt == CR:
            while out and is_space(out[-1]): out.pop()
            removals = [min(r, len(out)) for r in removals]
        removals.append(len(out))
    out.extend(scanned[end:])
    out = collapse(out, removals, cut == len(all_))
    out.extend(all_[cut:])
    return out


def reader_text(text):
    r = reader_units(u16(text))
    return text if r is None else from16(r)
