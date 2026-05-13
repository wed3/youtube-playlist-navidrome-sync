# YouTube Playlist to Navidrome Sync

A small Bash automation script for syncing audio from a YouTube playlist to a remote Navidrome music directory.

It uses `yt-dlp` to download/extract audio, embeds metadata and thumbnails, uses a download archive to avoid duplicates, transfers finished files with `rsync`, and deletes local staged files after successful transfer.

## Disclaimer

This project was largely vibecoded and built around a personal Navidrome workflow. Treat it as a practical automation script, not polished production software.

Review the code before running it, especially the browser-cookie handling, SSH/rsync target, deletion behavior, and `yt-dlp` options.

Only use this with media you have the right to download, store, or transfer. YouTube and other platforms may restrict automated downloading in their terms.

## Features

- Downloads audio from a YouTube playlist with `yt-dlp`
- Converts/extracts audio with `ffmpeg`
- Embeds thumbnails and metadata
- Uses `yt-dlp` archive tracking to avoid duplicate downloads
- Transfers each finished file to a remote Navidrome music directory with `rsync`
- Deletes local staged files after successful transfer
- Supports Firefox/LibreWolf cookies for logged-in playlists
- Uses `flock` to prevent overlapping runs
- Supports dry runs and keep-local debugging mode

## Requirements

System packages:

```bash
yt-dlp
ffmpeg
openssh
rsync
util-linux
```

On Arch:

```bash
sudo pacman -S yt-dlp ffmpeg openssh rsync util-linux
```

## Setup

Clone or copy the repo:

```bash
git clone https://github.com/YOUR_USERNAME/youtube-playlist-navidrome-sync.git
cd youtube-playlist-navidrome-sync
```

Create a config:

```bash
cp youtube_sync.conf.example youtube_sync.conf
nano youtube_sync.conf
```

Edit:

```bash
PLAYLIST_URL="https://www.youtube.com/playlist?list=..."
REMOTE_USER="user"
REMOTE_HOST="192.168.1.10"
REMOTE_DIR="/path/to/navidrome/music"
SSH_KEY="$HOME/.ssh/id_ed25519_ytsync"
```

Make the script executable:

```bash
chmod +x youtube_sync.sh
```

## Usage

Normal sync:

```bash
./youtube_sync.sh
```

Use a specific config:

```bash
./youtube_sync.sh --config ./youtube_sync.conf
```

Dry run:

```bash
./youtube_sync.sh --dry-run
```

Keep local files after transfer:

```bash
./youtube_sync.sh --keep-local
```

Use a different playlist once:

```bash
./youtube_sync.sh --playlist "https://www.youtube.com/playlist?list=..."
```

Disable browser cookies:

```bash
./youtube_sync.sh --no-cookies
```

## Browser Cookies

The script can use Firefox/LibreWolf cookies through `yt-dlp`.

By default, it checks common locations:

- Flatpak LibreWolf
- Native LibreWolf
- Firefox

If automatic detection fails, set a cookie path manually in `youtube_sync.conf`:

```bash
COOKIE_SQLITE="$HOME/.mozilla/firefox/xxxxxxxx.default-release/cookies.sqlite"
```

Or disable cookies for public playlists:

```bash
USE_BROWSER_COOKIES=0
```

## SSH

Make sure key-based SSH works before running the script:

```bash
ssh -i ~/.ssh/id_ed25519_ytsync user@192.168.1.10
```

The remote music directory must be writable by the SSH user.

## Scheduling with systemd

Example user service and timer files are included in `systemd/`.

Install them with:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/youtube-sync.service ~/.config/systemd/user/
cp systemd/youtube-sync.timer ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now youtube-sync.timer
```

Check logs:

```bash
journalctl --user -u youtube-sync.service -f
```

## License

MIT


## Chromium / Chrome / Brave Cookies

The script can also use Chromium-family browser cookies through `yt-dlp`.

Supported browser values:

```text
chromium
chrome
brave
edge
opera
vivaldi
whale
```

Examples:

```bash
./youtube_sync.sh --dry-run --browser brave
./youtube_sync.sh --dry-run --browser chromium
./youtube_sync.sh --dry-run --browser chrome
```

In `youtube_sync.conf`:

```bash
COOKIE_BROWSER="brave"
```

If automatic profile detection fails, set a profile directory:

```bash
COOKIE_PROFILE_DIR="$HOME/.config/chromium"
COOKIE_PROFILE_DIR="$HOME/.config/google-chrome"
COOKIE_PROFILE_DIR="$HOME/.config/BraveSoftware/Brave-Browser"
```

For Chromium-family browsers, `COOKIE_SQLITE` is ignored because `yt-dlp` reads browser cookies directly.
