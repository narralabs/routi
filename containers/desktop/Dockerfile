# The one desktop machine, with a screen for each bot.
#
# A screen is an X display, not a container: every bot gets its own Xvfb, XFCE session
# and browser, so no two bots share a pointer — while the machine underneath is shared,
# so tools are installed once, downloads land in one place, and bringing a screen up
# takes seconds rather than the tens a container start costs.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24

RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb \
      x11vnc \
      xfce4 \
      xfce4-terminal \
      thunar \
      dbus-x11 \
      chromium \
      chromium-sandbox \
      xdotool \
      xclip \
      scrot \
      imagemagick \
      fonts-liberation \
      fonts-noto-color-emoji \
      ca-certificates \
      procps \
      socat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# A real user plus chromium-sandbox: Debian ships the setuid sandbox separately, and
# without it Chromium exits with "No usable sandbox!". The alternative — passing
# --no-sandbox — turns off the isolation that makes it safe to point a model at the
# open web, so the package is the right fix.
RUN useradd -ms /bin/bash routi
WORKDIR /home/routi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY screenctl /usr/local/bin/screenctl
COPY act /usr/local/bin/act
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/screenctl /usr/local/bin/act

USER routi
EXPOSE 5900
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
