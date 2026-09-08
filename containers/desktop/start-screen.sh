#!/usr/bin/env bash
# Minimal Grok-Bot-like desktop: no xfce4-panel, bottom Plank only.
set -euo pipefail

: "${DISPLAY:?DISPLAY required}"
: "${HOME:?HOME required}"

log_suffix="${DISPLAY#:}"
log_suffix="${log_suffix%%.*}"

hsetroot -solid '#1b1b1f' 2>/dev/null || xsetroot -solid '#1b1b1f'

xfwm4 --compositor=off >"/tmp/xfwm4-${log_suffix}.log" 2>&1 &

picom --config /dev/null --backend xrender --no-use-damage \
  >"/tmp/picom-${log_suffix}.log" 2>&1 &

# Plank only paints translucent if a compositor already owns _NET_WM_CM_S0.
python3 - "$DISPLAY" <<'PY' || sleep 0.5
import ctypes, sys, time
xlib = ctypes.CDLL("libX11.so.6")
xlib.XOpenDisplay.restype = ctypes.c_void_p
xlib.XInternAtom.restype = ctypes.c_ulong
xlib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
xlib.XGetSelectionOwner.restype = ctypes.c_ulong
xlib.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
dpy = xlib.XOpenDisplay(sys.argv[1].encode())
if not dpy:
    raise SystemExit(0)
sel = xlib.XInternAtom(dpy, b"_NET_WM_CM_S0", False)
deadline = time.monotonic() + 5.0
while not xlib.XGetSelectionOwner(dpy, sel):
    if time.monotonic() >= deadline:
        break
    time.sleep(0.1)
PY

mkdir -p \
  "$HOME/.local/share/applications" \
  "$HOME/.config/plank/dock1/launchers" \
  "$HOME/.config/mimeapps.list.d"

cp -f /usr/share/applications/routi-chrome.desktop \
  "$HOME/.local/share/applications/routi-chrome.desktop"

cat >"$HOME/.config/mimeapps.list" <<'EOFMIME'
[Default Applications]
x-scheme-handler/http=routi-chrome.desktop
x-scheme-handler/https=routi-chrome.desktop
EOFMIME

printf '%s\n' '[PlankDockItemPreferences]' \
  "Launcher=file://${HOME}/.local/share/applications/routi-chrome.desktop" \
  >"$HOME/.config/plank/dock1/launchers/chrome.dockitem"
printf '%s\n' '[PlankDockItemPreferences]' \
  'Launcher=file:///usr/share/applications/thunar.desktop' \
  >"$HOME/.config/plank/dock1/launchers/thunar.dockitem"
printf '%s\n' '[PlankDockItemPreferences]' \
  'Launcher=file:///usr/share/applications/xfce4-terminal.desktop' \
  >"$HOME/.config/plank/dock1/launchers/terminal.dockitem"

dconf write /net/launchpad/plank/docks/dock1/dock-items \
  "['chrome.dockitem', 'thunar.dockitem', 'terminal.dockitem']" 2>/dev/null || true
dconf write /net/launchpad/plank/docks/dock1/position "'bottom'" 2>/dev/null || true
dconf write /net/launchpad/plank/docks/dock1/theme "'Transparent'" 2>/dev/null || true
dconf write /net/launchpad/plank/docks/dock1/icon-size "48" 2>/dev/null || true
dconf write /net/launchpad/plank/docks/dock1/hide-mode "'none'" 2>/dev/null || true

plank --name dock1 >"/tmp/plank-${log_suffix}.log" 2>&1 &
