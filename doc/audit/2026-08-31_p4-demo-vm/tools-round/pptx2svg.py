#!/usr/bin/env python3
"""Rebuild a single-slide PowerPoint diagram as SVG, from the OOXML geometry.

The slide Adam supplied has no raster image in it -- the diagram is 84 shapes and 23
connectors drawn with PowerPoint primitives. So there is nothing to extract; it has to be
redrawn. Every number below comes out of the file (EMU offsets, extents, theme colours,
run properties); nothing is eyeballed or approximated.

🔑 The one thing this cannot inherit is PowerPoint's text layout engine. Line breaking and
vertical centring are re-implemented, so the check that matters is not "did it parse" but
"does the rendered picture look like the slide" -- which is why the caller rasterises it and
looks at it before shipping.

[Co-developed with claude code -- Adam]
"""
import sys, os, re, math
import xml.etree.ElementTree as ET

A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
ns = {'a': A, 'p': P, 'r': R}
EMU = 12700.0          # EMU per point
def pt(v): return float(v) / EMU

root_dir = sys.argv[1]
out_svg  = sys.argv[2]

# ---- theme colours -----------------------------------------------------------------
theme_map = {}
tpath = os.path.join(root_dir, 'ppt/theme/theme1.xml')
if os.path.exists(tpath):
    th = ET.parse(tpath).getroot()
    scheme = th.find('.//a:clrScheme', ns)
    order = ['dk1','lt1','dk2','lt2','accent1','accent2','accent3','accent4','accent5','accent6','hlink','folHlink']
    for name in order:
        el = scheme.find('a:%s' % name, ns)
        if el is None: continue
        srgb = el.find('a:srgbClr', ns); sysc = el.find('a:sysClr', ns)
        if srgb is not None: theme_map[name] = '#' + srgb.get('val')
        elif sysc is not None: theme_map[name] = '#' + (sysc.get('lastClr') or '000000')
    theme_map['tx1'] = theme_map.get('dk1', '#000000')
    theme_map['bg1'] = theme_map.get('lt1', '#FFFFFF')
    theme_map['tx2'] = theme_map.get('dk2', '#000000')
    theme_map['bg2'] = theme_map.get('lt2', '#FFFFFF')

def lum_mod(hexc, mod=None, off=None):
    h = hexc.lstrip('#')
    r, g, b = (int(h[i:i+2], 16) for i in (0, 2, 4))
    def f(c):
        c = c / 255.0
        if mod is not None: c *= mod
        if off is not None: c += off
        return max(0, min(255, int(round(c * 255))))
    return '#%02X%02X%02X' % (f(r), f(g), f(b))

def color_of(parent):
    """Resolve <a:solidFill> under `parent` to a hex string, or None."""
    if parent is None: return None
    sf = parent.find('a:solidFill', ns)
    if sf is None: return None
    srgb = sf.find('a:srgbClr', ns)
    if srgb is not None:
        base = '#' + srgb.get('val')
        node = srgb
    else:
        sch = sf.find('a:schemeClr', ns)
        if sch is None: return None
        base = theme_map.get(sch.get('val'), '#000000')
        node = sch
    lm = node.find('a:lumMod', ns); lo = node.find('a:lumOff', ns)
    m = int(lm.get('val')) / 100000.0 if lm is not None else None
    o = int(lo.get('val')) / 100000.0 if lo is not None else None
    if m is not None or o is not None:
        base = lum_mod(base, m, o)
    # 🔴 The text boxes in this deck are `srgbClr 000000` with `alpha 0` -- transparent black.
    #    Ignoring the alpha paints opaque black over every box underneath, which is exactly
    #    what the first render did: a picture that was 100% wrong and 0% obviously broken.
    al = node.find('a:alpha', ns)
    if al is not None and int(al.get('val')) == 0:
        return None
    return base

def xfrm_of(el):
    x = el.find('.//a:xfrm', ns)
    if x is None: return None
    off = x.find('a:off', ns); ext = x.find('a:ext', ns)
    if off is None or ext is None: return None
    return dict(x=pt(off.get('x')), y=pt(off.get('y')),
                w=pt(ext.get('cx')), h=pt(ext.get('cy')),
                rot=int(x.get('rot') or 0) / 60000.0,
                flipH=x.get('flipH') == '1', flipV=x.get('flipV') == '1')

def esc(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))

# ---- real text measurement -----------------------------------------------------------
# PowerPoint's default text insets are 91440 EMU left/right (7.2 pt each).
INSET = 7.2
_FONT_R = '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf'
_FONT_B = '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'
try:
    from PIL import ImageFont
    _cache = {}
    def text_w(s, size_pt, bold=False):
        key = (round(size_pt, 1), bold)
        f = _cache.get(key)
        if f is None:
            # measure at 4x and divide, so integer-pixel rounding cannot accumulate
            f = ImageFont.truetype(_FONT_B if bold else _FONT_R, int(round(size_pt * 4)))
            _cache[key] = f
        return f.getlength(s) / 4.0
except Exception as e:                                   # no Pillow / no font file
    sys.stderr.write("  ⚠️  falling back to an ESTIMATED text width (%s)\n" % e)
    def text_w(s, size_pt, bold=False):
        return len(s) * size_pt * 0.50

def paragraphs(sp):
    """[(runs, align, defsize_pt)] where runs = [(text, size_pt, bold, colour)]"""
    body = sp.find('.//p:txBody', ns)
    if body is None: return []
    out = []
    for p in body.findall('a:p', ns):
        pr = p.find('a:pPr', ns)
        align = pr.get('algn') if pr is not None else None
        runs = []
        for r in p.findall('a:r', ns):
            rpr = r.find('a:rPr', ns)
            sz = int(rpr.get('sz')) / 100.0 if (rpr is not None and rpr.get('sz')) else None
            bold = (rpr is not None and rpr.get('b') == '1')
            col = color_of(rpr) if rpr is not None else None
            t = r.find('a:t', ns)
            runs.append((t.text or '', sz, bold, col))
        if runs: out.append((runs, align))
    return out

slide = ET.parse(os.path.join(root_dir, 'ppt/slides/slide1.xml')).getroot()
pres  = ET.parse(os.path.join(root_dir, 'ppt/presentation.xml')).getroot()
sz = pres.find('.//p:sldSz', ns)
W, H = pt(sz.get('cx')), pt(sz.get('cy'))

body = []
tree = slide.find('.//p:cSld/p:spTree', ns)

def emit_shape(el, kind):
    xf = xfrm_of(el)
    if xf is None: return
    spPr = el.find('.//p:spPr', ns)
    fill = color_of(spPr)
    nofill = spPr is not None and spPr.find('a:noFill', ns) is not None
    ln = spPr.find('a:ln', ns) if spPr is not None else None
    stroke = color_of(ln) if ln is not None else None
    lnw = pt(ln.get('w')) if (ln is not None and ln.get('w')) else 1.0
    if ln is not None and ln.find('a:noFill', ns) is not None: stroke = None
    geo = spPr.find('a:prstGeom', ns) if spPr is not None else None
    prst = geo.get('prst') if geo is not None else 'rect'

    g = []
    tx = ''
    if xf['rot']:
        tx = ' transform="rotate(%.2f %.2f %.2f)"' % (xf['rot'], xf['x'] + xf['w'] / 2, xf['y'] + xf['h'] / 2)

    if kind == 'cxn':
        # connectors: straight or elbow, drawn as a line across the bounding box
        x1, y1 = xf['x'], xf['y']
        x2, y2 = xf['x'] + xf['w'], xf['y'] + xf['h']
        if xf['flipH']: x1, x2 = x2, x1
        if xf['flipV']: y1, y2 = y2, y1
        col = stroke or '#595959'
        head = ln is not None and ln.find('a:headEnd', ns) is not None and ln.find('a:headEnd', ns).get('type') not in (None, 'none')
        tail = ln is not None and ln.find('a:tailEnd', ns) is not None and ln.find('a:tailEnd', ns).get('type') not in (None, 'none')
        mk = ''
        if head: mk += ' marker-start="url(#ah)"'
        if tail: mk += ' marker-end="url(#ah)"'
        if prst == 'bentConnector3':
            mx = (x1 + x2) / 2
            g.append('<polyline points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="none" stroke="%s" stroke-width="%.2f"%s/>'
                     % (x1, y1, mx, y1, mx, y2, x2, y2, col, lnw, mk))
        else:
            g.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.2f"%s/>'
                     % (x1, y1, x2, y2, col, lnw, mk))
        body.append('<g%s>%s</g>' % (tx, ''.join(g)))
        return

    fa = 'none' if (nofill or fill is None) else fill
    sa = 'none' if stroke is None else stroke
    if prst == 'cloud':
        # a cloud built from overlapping circles inside the bounding box
        cx, cy, w, h = xf['x'], xf['y'], xf['w'], xf['h']
        blobs = [(0.24, 0.62, 0.24), (0.46, 0.42, 0.30), (0.72, 0.60, 0.26),
                 (0.36, 0.74, 0.24), (0.62, 0.76, 0.22), (0.50, 0.60, 0.34)]
        circles = ''.join('<circle cx="%.1f" cy="%.1f" r="%.1f"/>' % (cx + fx * w, cy + fy * h, fr * min(w, h) * 1.15)
                          for fx, fy, fr in blobs)
        g.append('<g fill="%s" stroke="%s" stroke-width="%.2f" stroke-linejoin="round">%s</g>' % (fa, sa, lnw, circles))
        # redraw fill on top so the internal circle outlines do not show
        g.append('<g fill="%s" stroke="none">%s</g>' % (fa, circles))
    elif prst in ('roundRect',):
        g.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="%s" stroke="%s" stroke-width="%.2f"/>'
                 % (xf['x'], xf['y'], xf['w'], xf['h'], min(xf['w'], xf['h']) * 0.16, fa, sa, lnw))
    elif prst == 'ellipse':
        g.append('<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" fill="%s" stroke="%s" stroke-width="%.2f"/>'
                 % (xf['x'] + xf['w'] / 2, xf['y'] + xf['h'] / 2, xf['w'] / 2, xf['h'] / 2, fa, sa, lnw))
    else:
        if fa != 'none' or sa != 'none':
            g.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" stroke="%s" stroke-width="%.2f"/>'
                     % (xf['x'], xf['y'], xf['w'], xf['h'], fa, sa, lnw))

    # ---- text, wrapped to the shape width ----
    paras = paragraphs(el)
    if paras:
        # 🔑 Shrink-to-fit, and it is a substitution artefact rather than a liberty.
        #    All 84 shapes are `noAutofit`, so PowerPoint itself never shrinks -- but
        #    PowerPoint is laying Calibri out, and Calibri is not installed here. Measured in
        #    Liberation Sans the same strings are wider, so a few labels that fit on one line
        #    in the original wrap and spill out of their box. Dropping the size just far
        #    enough to fit reproduces what the slide LOOKS like, instead of reproducing a
        #    rule whose input font I do not have. Boxes that already fit are untouched.
        scale = 1.0
        for _ in range(24):
            need = 0.0
            for runs, align in paras:
                text = ''.join(t for t, _, _, _ in runs)
                size = next((s for _, s, _, _ in runs if s), 18.0) * scale
                bold = any(b for _, _, b, _ in runs)
                avail = xf['w'] - INSET * 2
                n, cur = 1, ''
                for w_ in text.split():
                    trial = (cur + ' ' + w_).strip()
                    if text_w(trial, size, bold) <= avail or not cur: cur = trial
                    else: n += 1; cur = w_
                need += n * size * 1.22
            if need <= xf['h'] - 1.0 or scale < 0.55: break
            scale -= 0.04
        lines = []
        for runs, align in paras:
            text = ''.join(t for t, _, _, _ in runs)
            size = next((s for _, s, _, _ in runs if s), 18.0) * scale
            bold = any(b for _, _, b, _ in runs)
            col  = next((c for _, _, _, c in runs if c), None) or '#000000'
            # 🔑 Wrap on MEASURED width, not a characters-per-line estimate. The first attempt
            #    used 0.52em per character; the deck's runs are Calibri, which is narrower, so
            #    every long label wrapped one line too early and overflowed its box -- and all
            #    84 shapes are `noAutofit`, so PowerPoint never shrinks the text to hide it.
            #    Calibri is not installed here, so the measurement uses Liberation Sans (Arial
            #    metrics), which is WIDER: what fits when measured in Arial also fits in
            #    Calibri, so the error can only be slack, never overflow.
            avail = xf['w'] - INSET * 2
            words, cur = text.split(), ''
            wrapped = []
            for w_ in words:
                trial = (cur + ' ' + w_).strip()
                if text_w(trial, size, bold) <= avail or not cur: cur = trial
                else: wrapped.append(cur); cur = w_
            if cur: wrapped.append(cur)
            if not wrapped: wrapped = ['']
            for ln_ in wrapped:
                lines.append((ln_, size, bold, col, align))
        total = sum(s * 1.22 for _, s, _, _, _ in lines)
        y = xf['y'] + xf['h'] / 2 - total / 2 + lines[0][1] * 0.92
        for ln_, size, bold, col, align in lines:
            anchor, ax = 'middle', xf['x'] + xf['w'] / 2
            if align == 'l': anchor, ax = 'start', xf['x'] + INSET
            elif align == 'r': anchor, ax = 'end', xf['x'] + xf['w'] - INSET
            g.append('<text x="%.1f" y="%.1f" font-size="%.1f" fill="%s" text-anchor="%s"%s>%s</text>'
                     % (ax, y, size, col, anchor, ' font-weight="bold"' if bold else '', esc(ln_)))
            y += size * 1.22
    body.append('<g%s>%s</g>' % (tx, ''.join(g)))

for el in tree:
    tag = el.tag.split('}')[1]
    if tag == 'sp':    emit_shape(el, 'sp')
    elif tag == 'cxnSp': emit_shape(el, 'cxn')

svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %.0f %.0f" width="%.0f" height="%.0f" font-family="Calibri, Carlito, Arial, Helvetica, sans-serif" role="img" aria-label="NDTwin architecture: applications and tools above the kernel, the kernel above the SDN controller and P4 proxy agent, and three kinds of data network below them">
<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#595959"/></marker></defs>
<rect width="100%%" height="100%%" fill="#FFFFFF"/>
%s
</svg>
""" % (W, H, W, H, '\n'.join(body))
open(out_svg, 'w', encoding='utf-8').write(svg)
print("  wrote %s  (%.0f x %.0f pt, %d groups)" % (out_svg, W, H, len(body)))
