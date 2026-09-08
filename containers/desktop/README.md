# Routi shared desktop

One Docker Linux machine for every bot screen.

- Build: `docker build -t routi-desktop:latest containers/desktop`
- Published convenience tag: `narralabs/routi-desktop:minimal`
- Screens: `screenctl start <bot-id>` → Xvfb + xfwm4 + picom + Plank (no XFCE top panel)
- Canvas: 1280×800
- Required run flags (already set by the daemon): `--shm-size=…` and `--security-opt seccomp=unconfined`
