# dmgbuild settings: the BGDesk installer layout (800x400 art, 128px icons at
# (200,190) and (600,190), Finder chrome hidden) for Agent Watcher.
#   dmgbuild -s scripts/dmg-settings.py -D app=build/AgentWatcher.app "Agent Watcher" out.dmg
import os.path

app = defines.get("app", "build/AgentWatcher.app")  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)
assets = os.path.abspath(defines.get("assets", "Resources/dmg"))  # noqa: F821

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it writes Finder info into the signed bundle and breaks
# `codesign --strict`. Finder hides ".app" by default anyway.
icon = os.path.join(assets, "volume-icon.icns")
# background@2x.png next to it is picked up for Retina (combined into a TIFF).
background = os.path.join(assets, "background.png")

# Same frame as the BGDesk layout: 800x480 including the title bar.
window_rect = ((200, 382), (800, 480))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 16
icon_locations = {
    app_name: (200, 190),
    "Applications": (600, 190),
}
