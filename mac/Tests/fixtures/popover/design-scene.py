#!/usr/bin/env python3
"""design-scene.py: copy docs/design/share-bar-redesign.html (revision 8) with one scene opened on load.

Usage: design-scene.py <design.html> <out.html> <scene> <light|dark>
The scene JS uses only the prototype's own state and render functions (the way its Scenario and
Dragging buttons do), then marks the popover or Quick Look panel's corners (see `box`) for the sampler.
"""
import sys

src, out, scene, theme = sys.argv[1:5]
calm = "document.getElementById('a-%s').click();document.getElementById('s-calm').click();" % theme
extra_links = {
    "ql-pdf": ("{t:'doc',n:'Q4-plan.pdf',who:'You',where:'this Mac',exp:'27d',ago:'1d',id:'pd0001'}", "pd0001"),
    "ql-folder": (None, "89f402"),
    "ql-port": ("{t:'live',n:'localhost:3000',who:'You',where:'this Mac',exp:'live',ago:'3d',id:'lv0001'}", "lv0001"),
    "ql-cloud": ("{t:'doc',n:'board-deck.pdf',who:'You',where:'cloud',exp:'27d',views:12,ago:'8d',id:'cl0001'}", "cl0001"),
}
if scene == "drop":
    js = "dragging=true;renderPop();"
elif scene == "uploading":
    js = "uploading={n:'Q4-plan.pdf',p:50};renderPop();"
elif scene == "flashed":
    js = "flashId=SCN_LINKS[cur][0].id;toast('Link copied: Q4-plan.pdf');renderPop();"
elif scene == "dragout":
    js = "internalDrag=true;dragHint='posture-routine.html';renderPop();renderFootOnly();"
elif scene == "hotkey":
    js = "view='list';renderPop();document.getElementById('q').focus();"
elif scene in extra_links:
    link, ident = extra_links[scene]
    js = ("SCN_LINKS[cur].unshift(%s);renderPop();" % link if link else "") + "ql='%s';renderQL();" % ident
else:
    sys.exit("unknown scene " + scene)
sel = ".qlp" if scene.startswith("ql-") else "#pop"
# Two magenta 2 css px marks inside the panel, 6 px in from its top-left corner and 8 px above its bottom
# edge, so the sampler finds the panel in the screenshot itself (they travel with the panel when the page
# reflows; the bounding box of a separate DOM dump would not).
box = ("var el=document.querySelector('%s'); if(el){ if(getComputedStyle(el).position==='static') el.style.position='relative';"
       "var h=el.getBoundingClientRect().height;"
       "[6,h-8].forEach(function(t){var m=document.createElement('i');"
       "m.style.cssText='position:absolute;z-index:99999;width:2px;height:2px;background:#ff00ff;left:6px;top:'+t+'px';"
       "el.appendChild(m);});}") % sel
html = open(src, encoding="utf-8").read()
tail = "renderPop(); renderWin(); applyAppearance();"
assert html.count(tail) == 1, "the page's last line changed"
# Late, so web fonts have settled and the page has its final layout when the panel is measured.
html = html.replace(tail, tail + " setTimeout(function(){" + calm + js + "setTimeout(function(){" + box + "},600);},1200);")
open(out, "w", encoding="utf-8").write(html)
