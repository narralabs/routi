# The shared desktop every bot drives.
#
# One container, one X display. Bots take turns on it, which is the point: a login to
# Booking.com or a Gmail session made by one bot is there for the next. Per-bot
# containers would mean signing in again for every bot you create.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
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
      xdotool \
      scrot \
      imagemagick \
      fonts-liberation \
      fonts-noto-color-emoji \
      ca-certificates \
      procps \
      socat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# A real user: Chromium refuses to run as root without --no-sandbox, and running a
# browser as root inside a container the model can drive is a bad default.
RUN useradd -ms /bin/bash krog
WORKDIR /home/krog

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY act /usr/local/bin/act
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/act

USER krog
EXPOSE 5900
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
