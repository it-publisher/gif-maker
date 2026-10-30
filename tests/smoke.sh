#!/usr/bin/env bash
# smoke.sh — end-to-end checks for make-gif.sh using synthetic ffmpeg sources.
#
# Runs on macOS (bash 3.2) and Linux (bash 4+). Requires ffmpeg/ffprobe;
# gifsicle is optional — the GIF-optimization checks adapt when it is missing.
#
# Usage: bash tests/smoke.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.claude/skills/gif-maker/scripts/make-gif.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"
  shift
  if [[ $# -gt 0 ]]; then printf '  %s\n' "$*" >&2; fi
}

eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else no "$3" "expected [$2], got [$1]"; fi; }

le() {
  if awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<=b)}'; then ok "$3"
  else no "$3" "expected <= $2, got $1"; fi
}

between() {
  if awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; then ok "$4"
  else no "$4" "expected $2..$3, got $1"; fi
}

contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "expected [$2] in: $1" ;;
  esac
}

fails_with() {
  local name="$1" needle="$2" log="$3"
  shift 3
  if "$@" >"$log" 2>&1; then
    no "$name" "expected a non-zero exit"
  else
    ok "$name"
    contains "$(cat "$log")" "$needle" "$name (message)"
  fi
}

probe() { ffprobe -v error -select_streams v:0 -show_entries "$2" -of csv=p=0 "$1"; }
fps_of() {
  probe "$1" stream=avg_frame_rate \
    | awk -F/ '{if ($2 && $2 != 0) printf "%.3f", $1/$2; else print $1}'
}
duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
size() { wc -c <"$1" | tr -d '[:space:]'; }

# center pixel of a given frame as "r g b"
pixel() {
  ffmpeg -v error -i "$1" -vf "select=eq(n\,$2),crop=1:1:$3:$4" -frames:v 1 \
    -f rawvideo -pix_fmt rgb24 - 2>/dev/null | od -An -tu1 -N3
}

# ---------- fixtures ----------
ffmpeg -v error -f lavfi -i testsrc2=s=320x240:r=25 -t 2 -pix_fmt yuv420p "$TMP/video.mp4"
mkdir -p "$TMP/photos"
ffmpeg -v error -f lavfi -i color=c=red:s=800x400 -frames:v 1 "$TMP/photos/1.png"
ffmpeg -v error -f lavfi -i color=c=green:s=400x800 -frames:v 1 "$TMP/photos/2.png"
ffmpeg -v error -f lavfi -i color=c=blue:s=400x400 -frames:v 1 "$TMP/photos/10.png"
touch "$TMP/photos/notes.txt"
mkdir -p "$TMP/out"

# ---------- video ----------
"$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/out/video.gif" -w 160 -r 8 -m 300K \
  >"$TMP/video.log" 2>&1
[[ -f "$TMP/out/video.gif" ]] && ok "video: output created" || no "video: output created"
eq "$(probe "$TMP/out/video.gif" stream=width)" 160 "video: width honoured"
le "$(size "$TMP/out/video.gif")" 307200 "video: stays within 300K"
between "$(duration "$TMP/out/video.gif")" 1.8 2.2 "video: duration preserved"

# -t is applied before --speed: 1s at 2x -> ~0.5s
"$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/out/speed.gif" -w 100 -r 8 -t 1 --speed 2 \
  -m 200K >/dev/null 2>&1
between "$(duration "$TMP/out/speed.gif")" 0.35 0.75 "speed: -t 1 --speed 2 gives ~0.5s"

# ---------- photos ----------
"$SCRIPT" -i "$TMP/photos" -o "$TMP/out/slides.gif" -w 320 -p 0.5 -m 200K \
  >/dev/null 2>&1
eq "$(probe "$TMP/out/slides.gif" stream=width)" 320 "photos: canvas width"
eq "$(probe "$TMP/out/slides.gif" stream=height)" 160 "photos: canvas follows first photo aspect"
eq "$(probe "$TMP/out/slides.gif" stream=nb_frames)" 3 "photos: one frame per photo"
between "$(fps_of "$TMP/out/slides.gif")" 1.9 2.1 "photos: -p 0.5 -> 2 fps output"

read -r r g b <<<"$(pixel "$TMP/out/slides.gif" 0 160 80)"
[[ "$r" -gt 200 && "$g" -lt 40 && "$b" -lt 40 ]] && ok "photos: frame 1 is red (1.png)" \
  || no "photos: frame 1 is red (1.png)" "got $r $g $b"
read -r r g b <<<"$(pixel "$TMP/out/slides.gif" 1 160 80)"
[[ "$g" -gt 100 && "$r" -lt 40 && "$b" -lt 40 ]] && ok "photos: frame 2 is green (2.png)" \
  || no "photos: frame 2 is green (2.png)" "got $r $g $b"
read -r r g b <<<"$(pixel "$TMP/out/slides.gif" 2 160 80)"
[[ "$b" -gt 200 && "$r" -lt 40 && "$g" -lt 40 ]] && ok "photos: frame 3 is blue (10.png)" \
  || no "photos: frame 3 is blue (10.png)" "got $r $g $b"

# glob input: non-image matches are ignored
"$SCRIPT" -i "$TMP/photos/*" -o "$TMP/out/glob.gif" -w 100 -p 0.3 -m 100K \
  >/dev/null 2>&1
eq "$(probe "$TMP/out/glob.gif" stream=nb_frames)" 3 "glob: notes.txt ignored"

# uppercase extensions are photos too, not "non-image" glob matches
mkdir -p "$TMP/upper"
cp "$TMP/photos/1.png" "$TMP/upper/SHOT.PNG"
"$SCRIPT" -i "$TMP/upper/*" -o "$TMP/out/upper.gif" -w 50 -p 0.5 -m 50K \
  >/dev/null 2>&1
eq "$(probe "$TMP/out/upper.gif" stream=nb_frames)" 1 "glob: uppercase .PNG accepted"

# ---------- budget and reference ----------
"$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/out/budget.gif" -w 320 -r 10 -m 60K \
  >/dev/null 2>&1
le "$(size "$TMP/out/budget.gif")" 61440 "budget: hard cap respected"

ffmpeg -v error -f lavfi -i testsrc2=s=200x100:r=10 -t 1 -pix_fmt rgb24 "$TMP/ref.gif"
"$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/out/ref.gif" -R "$TMP/ref.gif" -m 500K \
  >/dev/null 2>&1
eq "$(probe "$TMP/out/ref.gif" stream=width)" 200 "reference: width floor honoured"

"$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/out/nocap.gif" -w 80 -r 5 --max-size none \
  >/dev/null 2>&1
[[ -s "$TMP/out/nocap.gif" ]] && ok "max-size none: accepts no cap" \
  || no "max-size none: accepts no cap"

# ---------- existing GIF ----------
cp "$TMP/out/slides.gif" "$TMP/in.gif"
before="$(size "$TMP/in.gif")"
"$SCRIPT" -i "$TMP/in.gif" -o "$TMP/out/opt.gif" -m 1M >"$TMP/gif.log" 2>&1
eq "$(probe "$TMP/out/opt.gif" stream=width)" 320 "gif: source width preserved"
between "$(fps_of "$TMP/out/opt.gif")" 1.9 2.1 "gif: source fps preserved"
le "$(size "$TMP/out/opt.gif")" "$before" "gif: output is not bigger than input"

# ---------- clean failures ----------
fails_with "crop auto with photos fails clearly" "crop auto works only" "$TMP/e1.log" \
  "$SCRIPT" -i "$TMP/photos" -o "$TMP/bad.gif" --crop auto
fails_with "fps=0 is rejected" "--fps must be" "$TMP/e2.log" \
  "$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/bad.gif" -r 0
fails_with "bad width target is rejected" "--width must be" "$TMP/e3.log" \
  "$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/bad.gif" -w no-such-file.gif
fails_with "colors=1 is rejected" "--colors must be" "$TMP/e4.log" \
  "$SCRIPT" -i "$TMP/video.mp4" -o "$TMP/bad.gif" --colors 1
fails_with "photo-time=0 is rejected" "--photo-time must be" "$TMP/e5.log" \
  "$SCRIPT" -i "$TMP/photos" -o "$TMP/bad.gif" -p 0
fails_with "empty glob is rejected" "glob matched no photos" "$TMP/e6.log" \
  "$SCRIPT" -i "$TMP/photos/*.webp" -o "$TMP/bad.gif"

mkdir -p "$TMP/mixed"
cp "$TMP/photos/1.png" "$TMP/mixed/"
ffmpeg -v error -f lavfi -i color=c=purple:s=100x100 -frames:v 1 "$TMP/mixed/small.png"
fails_with "crop bigger than a photo fails clearly" "crop rectangle must fit" "$TMP/e7.log" \
  "$SCRIPT" -i "$TMP/mixed" -o "$TMP/bad.gif" --crop 200:200:0:0 -w 100 -p 1

# ---------- summary ----------
echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
