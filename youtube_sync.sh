#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  youtube_sync.sh [options]

options:
  -c, --config PATH       config file path
  --playlist URL          override PLAYLIST_URL
  --dry-run               show playlist entries without downloading/transferring
  --keep-local            do not delete local files after rsync
  --no-cookies            do not use browser cookies
  -h, --help              show help

example:
  ./youtube_sync.sh --config ./youtube_sync.conf
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 1
  }
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config="${YTSYNC_CONFIG:-$script_dir/youtube_sync.conf}"

override_playlist=""
dry_run="${YTSYNC_DRY_RUN:-0}"
keep_local="${YTSYNC_KEEP_LOCAL:-0}"
no_cookies=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      config="${2:-}"
      [[ -n "$config" ]] || { echo "missing value for $1" >&2; exit 2; }
      shift 2
      ;;
    --playlist)
      override_playlist="${2:-}"
      [[ -n "$override_playlist" ]] || { echo "missing value for --playlist" >&2; exit 2; }
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --keep-local)
      keep_local=1
      shift
      ;;
    --no-cookies)
      no_cookies=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$config" ]]; then
  echo "missing config: $config" >&2
  echo "copy youtube_sync.conf.example to youtube_sync.conf and edit it" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$config"

playlist="${override_playlist:-${PLAYLIST_URL:-}}"
basedir="${BASE_DIR:-$script_dir}"
outdir="${OUT_DIR:-$basedir/staging}"
archive="${ARCHIVE_FILE:-$basedir/archive.txt}"
log="${LOG_FILE:-$basedir/yt-dlp.log}"
lock_file="${LOCK_FILE:-$basedir/.youtube_sync.lock}"

remote_user="${REMOTE_USER:-}"
remote_host="${REMOTE_HOST:-}"
remote_dir="${REMOTE_DIR:-}"
ssh_key="${SSH_KEY:-}"

audio_format="${AUDIO_FORMAT:-mp3}"
audio_quality="${AUDIO_QUALITY:-0}"
sleep_interval="${SLEEP_INTERVAL:-2}"
max_sleep_interval="${MAX_SLEEP_INTERVAL:-5}"
output_template="${OUTPUT_TEMPLATE:-%(artist,creator,uploader)s - %(title)s.%(ext)s}"

use_browser_cookies="${USE_BROWSER_COOKIES:-1}"
cookies_required="${COOKIES_REQUIRED:-1}"
cookie_browser="${COOKIE_BROWSER:-firefox}"
cookie_sqlite="${COOKIE_SQLITE:-auto}"
cookie_profile_dir="${COOKIE_PROFILE_DIR:-}"

if [[ -z "$playlist" ]]; then
  echo "PLAYLIST_URL is required" >&2
  exit 1
fi

if [[ "$dry_run" != "1" ]]; then
  [[ -n "$remote_user" ]] || { echo "REMOTE_USER is required" >&2; exit 1; }
  [[ -n "$remote_host" ]] || { echo "REMOTE_HOST is required" >&2; exit 1; }
  [[ -n "$remote_dir" ]] || { echo "REMOTE_DIR is required" >&2; exit 1; }
  [[ -n "$ssh_key" ]] || { echo "SSH_KEY is required" >&2; exit 1; }
fi

need yt-dlp
need ffmpeg
need grep
need mktemp
need rm
need cp
need flock
need tee

if [[ "$dry_run" != "1" ]]; then
  need ssh
  need rsync
fi

mkdir -p "$basedir" "$outdir"
touch "$archive" "$log"

exec 9>"$lock_file"
flock -n 9 || {
  echo "another sync is already running; exiting"
  exit 0
}

runlog="$(mktemp)"
cookie_dir="$(mktemp -d)"

cleanup() {
  rm -f "$runlog"
  rm -rf "$cookie_dir"
}
trap cleanup EXIT

find_browser_cookies() {
  shopt -s nullglob

  local candidates=(
    "$HOME/.var/app/io.gitlab.librewolf-community/.librewolf/"*/cookies.sqlite
    "$HOME/.config/librewolf/librewolf/"*/cookies.sqlite
    "$HOME/.librewolf/"*/cookies.sqlite
    "$HOME/.mozilla/firefox/"*/cookies.sqlite
  )

  local p
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  return 1
}

cookie_args=()

if [[ "$no_cookies" == "1" ]]; then
  use_browser_cookies=0
fi

if [[ "$use_browser_cookies" == "1" ]]; then
  if [[ -n "$cookie_profile_dir" ]]; then
    if [[ ! -d "$cookie_profile_dir" ]]; then
      echo "COOKIE_PROFILE_DIR does not exist: $cookie_profile_dir" >&2
      exit 1
    fi
    cookie_args=(--cookies-from-browser "${cookie_browser}:${cookie_profile_dir}")
  else
    if [[ "$cookie_sqlite" == "auto" ]]; then
      found_cookie="$(find_browser_cookies || true)"
    else
      found_cookie="$cookie_sqlite"
    fi

    if [[ -z "${found_cookie:-}" || ! -f "$found_cookie" ]]; then
      if [[ "$cookies_required" == "1" ]]; then
        echo "could not find browser cookies.sqlite" >&2
        echo "set COOKIE_SQLITE=/path/to/cookies.sqlite, COOKIE_PROFILE_DIR=/path/to/profile, or USE_BROWSER_COOKIES=0" >&2
        exit 1
      else
        echo "warning: could not find browser cookies; continuing without cookies" >&2
      fi
    else
      cp -f "$found_cookie" "$cookie_dir/cookies.sqlite"
      cookie_args=(--cookies-from-browser "${cookie_browser}:${cookie_dir}")
    fi
  fi
fi

if [[ "$dry_run" == "1" ]]; then
  echo "dry run"
  echo "playlist: $playlist"
  echo "config:   $config"
  yt-dlp "${cookie_args[@]}" --simulate --flat-playlist --ignore-errors "$playlist"
  exit 0
fi

ssh_opts=(-i "$ssh_key" -o IdentitiesOnly=yes)
ssh "${ssh_opts[@]}" "${remote_user}@${remote_host}" "mkdir -p '$remote_dir'"

export YTSYNC_REMOTE_USER="$remote_user"
export YTSYNC_REMOTE_HOST="$remote_host"
export YTSYNC_REMOTE_DIR="$remote_dir"
export YTSYNC_SSH_KEY="$ssh_key"
export YTSYNC_KEEP_LOCAL="$keep_local"

yt_dlp_status=0

set +e
yt-dlp \
  "${cookie_args[@]}" \
  --extract-audio \
  --audio-format "$audio_format" \
  --audio-quality "$audio_quality" \
  --embed-thumbnail \
  --embed-metadata \
  --add-metadata \
  --download-archive "$archive" \
  --sleep-interval "$sleep_interval" \
  --max-sleep-interval "$max_sleep_interval" \
  --ignore-errors \
  --no-abort-on-error \
  --output "$outdir/$output_template" \
  --exec 'after_move:bash -c '"'"'
    set -euo pipefail

    f="$1"

    rsync -av -s \
      -e "ssh -i ${YTSYNC_SSH_KEY} -o IdentitiesOnly=yes" \
      -- "$f" "${YTSYNC_REMOTE_USER}@${YTSYNC_REMOTE_HOST}:${YTSYNC_REMOTE_DIR%/}/"

    if [[ "${YTSYNC_KEEP_LOCAL}" != "1" ]]; then
      rm -f -- "$f"
    fi

    sleep 1
  '"'"' bash {}' \
  "$playlist" 2>&1 | tee "$runlog" | tee -a "$log"

yt_dlp_status=${PIPESTATUS[0]}
set -e

if grep -qiE "cookies are no longer valid|sign in|confirm you.?re not a bot|please log in|authorization|429|too many requests" "$runlog"; then
  echo "auth/cookie failure detected. aborting." >&2
  exit 1
fi

echo "done"
exit "$yt_dlp_status"
  --no-abort-on-error \
  --output "$outdir/$output_template" \
  --exec 'after_move:bash -c '"'"'
    set -euo pipefail

    f="$1"

    rsync -av -s \
      -e "ssh -i ${YTSYNC_SSH_KEY} -o IdentitiesOnly=yes" \
      -- "$f" "${YTSYNC_REMOTE_USER}@${YTSYNC_REMOTE_HOST}:${YTSYNC_REMOTE_DIR%/}/"

    if [[ "${YTSYNC_KEEP_LOCAL}" != "1" ]]; then
      rm -f -- "$f"
    fi

    sleep 1
  '"'"' bash {}' \
  "$playlist" 2>&1 | tee "$runlog" | tee -a "$log"

yt_dlp_status=${PIPESTATUS[0]}
set -e

if grep -qiE "cookies are no longer valid|sign in|confirm you.?re not a bot|please log in|authorization|429|too many requests" "$runlog"; then
  echo "auth/cookie failure detected. aborting." >&2
  exit 1
fi

echo "done"
exit "$yt_dlp_status"
