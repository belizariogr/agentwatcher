#!/usr/bin/env python3
"""Draw the Agent Watcher app icon (a sparkle inside a usage ring) as SVG.

  scripts/app_icon.py <palette> <out.svg>
  scripts/app_icon.py --list
"""
import math, sys

PALETTES = {
  # name: (gradient stops for sparkle and ring, background center, background edge)
  "oceano": (("#22d3ee", "#3b82f6", "#6366f1"), "#13254a", "#03060e"),
  "aurora": (("#bef264", "#2dd4bf", "#06b6d4"), "#0f2e2e", "#020909"),
  "lilas":  (("#f5d0fe", "#c084fc", "#6366f1"), "#2a1846", "#07040e"),
  "ambar":  (("#fde68a", "#fb923c", "#e11d48"), "#33190c", "#0a0503"),
  "gelo":   (("#ffffff", "#bae6fd", "#60a5fa"), "#1e2a44", "#020617"),
}

def pt(cx, cy, r, a):
  a = math.radians(a)
  return cx + r * math.sin(a), cy - r * math.cos(a)

def arc(cx, cy, r, a0, a1):
  x0, y0 = pt(cx, cy, r, a0); x1, y1 = pt(cx, cy, r, a1)
  large = 1 if (a1 - a0) % 360 > 180 else 0
  return f"M{x0:.2f} {y0:.2f} A{r} {r} 0 {large} 1 {x1:.2f} {y1:.2f}"

def sparkle(cx, cy, s, fill):
  k = s * 0.22
  return (f'<path fill="{fill}" d="M{cx} {cy-s} C{cx+k*0.6} {cy-k} {cx+k} {cy-k*0.6} {cx+s} {cy} '
          f'C{cx+k} {cy+k*0.6} {cx+k*0.6} {cy+k} {cx} {cy+s} C{cx-k*0.6} {cy+k} {cx-k} {cy+k*0.6} {cx-s} {cy} '
          f'C{cx-k} {cy-k*0.6} {cx-k*0.6} {cy-k} {cx} {cy-s}Z"/>')

def svg(palette):
  (c0, c1, c2), bg0, bg1 = PALETTES[palette]
  return f'''<svg viewBox="0 0 1024 1024" width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">
<defs>
<radialGradient id="bg" cx=".5" cy=".35" r=".8"><stop offset="0" stop-color="{bg0}"/><stop offset="1" stop-color="{bg1}"/></radialGradient>
<linearGradient id="shine" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="sp" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c0}"/><stop offset=".5" stop-color="{c1}"/><stop offset="1" stop-color="{c2}"/></linearGradient>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-opacity=".35"/></filter>
<filter id="glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="22" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#shadow)"/>
<circle cx="512" cy="512" r="290" fill="none" stroke="#fff" stroke-opacity=".08" stroke-width="22"/>
<path d="{arc(512, 512, 290, 0, 250)}" fill="none" stroke="url(#sp)" stroke-width="22" stroke-linecap="round" filter="url(#glow)"/>
<g filter="url(#glow)">{sparkle(512, 512, 210, "url(#sp)")}</g>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#shine)"/>
</svg>
'''

if __name__ == "__main__":
  if sys.argv[1:] == ["--list"]:
    print("\n".join(PALETTES)); sys.exit()
  palette, out = sys.argv[1], sys.argv[2]
  open(out, "w").write(svg(palette))
