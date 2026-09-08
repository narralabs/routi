# Routi minimal desktop — Grok Bot–style simplicity (no XFCE top panel).
# One shared machine; screens started per bot via screenctl.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb \
        x11vnc \
        xfwm4 \
        picom \
        plank \
        hsetroot \
        x11-xserver-utils \
        x11-utils \
        xfce4-terminal \
        thunar \
        dbus-x11 \
        chromium \
        chromium-sandbox \
        dconf-cli \
        libglib2.0-bin \
        xdotool \
        xclip \
        scrot \
        imagemagick \
        fonts-liberation \
        fonts-noto-color-emoji \
        ca-certificates \
        procps \
        socat \
        python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Prefer wrapper over stock Chromium launcher for dock WM class matching.
RUN useradd -ms /bin/bash routi \
    && mkdir -p /home/routi/Downloads /home/routi/.local/share/applications \
    && chown -R routi:routi /home/routi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY screenctl /usr/local/bin/screenctl
COPY start-screen.sh /usr/local/bin/start-screen.sh
COPY chrome-wrapper.sh /usr/local/bin/chrome-wrapper.sh
COPY act /usr/local/bin/act
RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/screenctl \
              /usr/local/bin/start-screen.sh \
              /usr/local/bin/chrome-wrapper.sh \
              /usr/local/bin/act \
    && printf '%s\n' \
        '[Desktop Entry]' \
        'Type=Application' \
        'Name=Chrome' \
        'Comment=Chromium (Routi wrapper)' \
        'Exec=/usr/local/bin/chrome-wrapper.sh %U' \
        'Icon=chromium' \
        'Terminal=false' \
        'Categories=Network;WebBrowser;' \
        'StartupWMClass=routi-chrome' \
        'MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;' \
        > /usr/share/applications/routi-chrome.desktop \
    && mkdir -p /etc/chromium.d \
    && printf '%s\n' \
        'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-dev-shm-usage --password-store=basic --no-first-run --no-default-browser-check"' \
        > /etc/chromium.d/routi-flags

USER routi
WORKDIR /home/routi
EXPOSE 5900
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
