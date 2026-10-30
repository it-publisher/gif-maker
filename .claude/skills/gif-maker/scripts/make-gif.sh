#!/usr/bin/env bash
# make-gif.sh — build an optimized animated GIF from a video or a folder of photos.
#
# Uses ffmpeg's two-pass palette pipeline (palettegen -> paletteuse) instead of
# ffmpeg's built-in default GIF encoder, which gives much smaller files at the
# same visual quality (5-10x smaller is typical for screencasts).
#
# Usage:
#   make-gif.sh -i INPUT -o OUTPUT.gif [options]
#
# INPUT is one of:
#   - a video file (.mov/.mp4/.mkv/.webm/...)
#   - a directory of photos (jpg/jpeg/png/bmp/tif/tiff/webp)
#   - a shell glob of photos, quoted: -i "photos/*.jpg"
#
# Run with -h for the full option list.

set -euo pipefail

# ---------- defaults ----------
# Quality (fps/width/colors/dither) and weight (max size) baselines are fixed
# constants below, not read from any file on disk — they're identical on
# every install of this skill, with nothing extra to ship alongside it.
FPS=10
WIDTH=640
CROP=""
SPEED=1
LOOP=0
COLORS=256
DITHER="sierra2_4a"
STATS_MODE="full"
START=""
DURATION=""
PHOTO_TIME=""
INPUT=""
OUTPUT=""
MAX_SIZE_ARG=""
REFERENCE=""
WIDTH_SET=0
MAX_SIZE_SET=0
FPS_SET=0
COLORS_SET=0
DITHER_SET=0
STATS_SET=0
LOSSY=0
LOSSY_SET=0
NO_CAP=0
USED_GIFSICLE=0
# Built-in weight ceiling, applied by default when neither -m/--max-size nor
# -R/--reference is given. Used to be looked up from a locally-present GIF's
# file size — that read the same value but only worked when that file
# happened to exist; the number is now baked in directly.
DEFAULT_MAX_SIZE_BYTES=8223879

usage() {
  cat <<'EOF'
make-gif.sh — build an optimized GIF from a video, photos, or another GIF

Usage:
  make-gif.sh -i INPUT -o OUTPUT.gif [options]

Input:
  -i, --input PATH        video file, photo directory, quoted glob, or .gif
  -o, --output PATH       output .gif path (default: out/<name>.gif or ./<name>.gif)

Video/GIF options:
  -s, --start TIME        start offset, e.g. 00:00:05 or 5
  -t, --duration SECONDS  clip length to encode (default: whole input).
                          Applied before --speed, so output length = duration/speed.
      --speed FACTOR      speed multiplier, e.g. 2 = twice as fast (default: 1)
      --crop SPEC         "w:h:x:y" (video, GIF, photos), or "auto" for video/GIF
                          to auto-detect letterboxing/UI chrome

Photo-only options:
  -p, --photo-time SEC    seconds each photo is shown (default: 1/fps).
                          When set, it replaces -r as the slideshow timing.

Common options:
  -r, --fps N              output frame rate (default: 10; for .gif input the
                             source rate is kept unless you pass -r)
  -w, --width N             output width in px, height auto-scaled (default: 640;
                             for .gif input the source width is kept unless you pass -w).
                             Also accepts a file path — uses that file's own width
                             (e.g. -w ref.gif to match a reference's resolution).
      --colors N            max palette colors, 2-256 (default: 256)
      --dither MODE         none|bayer|sierra2_4a|floyd_steinberg... (default: sierra2_4a)
      --stats-mode MODE     full|diff|single for palettegen (default: full;
                             use "diff" for screencasts/whiteboards — mostly-static
                             frame with a small moving region)
      --loop N              GIF loop count: 0 = forever (default), -1 = once, N = repeat
  -m, --max-size SIZE       size budget: "8M", "500K", a raw byte count, or a path
                             to another file whose size to match. If the first
                             encode comes out bigger, fps is stepped down, then
                             width (never below -R's floor), then colors, until it
                             fits or hits a floor. "none" disables the cap.
                             Default: a built-in ~7.8M ceiling, unless you pass
                             -m or -R yourself (prints a note when it does).
      --lossy N             gifsicle lossy level 0-200 (default: 0 = lossless).
                             Requires gifsicle; higher is smaller and less precise.
                             Applied after encoding when gifsicle is installed.
  -R, --reference FILE      shorthand for "not worse than FILE": sets --width to
                             FILE's resolution (a floor auto-tune won't shrink below)
                             and --max-size to FILE's weight (a ceiling), in one go.
                             An explicit -w or --max-size of your own overrides just
                             that half. FILE must exist on disk — this only matches
                             a real file you point it at, nothing is auto-detected.
  -h, --help                show this help

Existing .gif input is optimized losslessly with gifsicle -O3 when gifsicle is
installed, keeping the source fps and width. Without gifsicle it falls back to
the ffmpeg palette pipeline at the source fps/width.

Examples:
  # Video clip, cropped to a region, sped up 2x, 10s starting at 0:05
  make-gif.sh -i input.mov -o out/demo.gif -s 5 -t 10 --speed 2 \
    --crop "2400:1600:500:300" -r 12 -w 640

  # Auto-detect crop (e.g. strip browser chrome from a screen recording)
  make-gif.sh -i input.mov -o out/demo.gif --crop auto

  # Slideshow from a folder of photos, 1.5s per photo
  make-gif.sh -i photos/ -o out/slideshow.gif -p 1.5 -w 720

  # Shrink an existing GIF losslessly (fps and width preserved)
  make-gif.sh -i existing.gif -o out/smaller.gif

  # ...or squeeze harder with gifsicle's lossy mode
  make-gif.sh -i existing.gif -o out/smaller.gif --max-size 4M --lossy 40

  # Must not exceed 2MB — auto-tunes fps/width/colors down until it fits
  make-gif.sh -i input.mov -o out/demo.gif --max-size 2M

  # No weight cap: keep the best quality your fps/width/colors allow
  make-gif.sh -i input.mov -o out/best.gif --max-size none

  # Match another GIF's size exactly (a budget, not a quality target)
  make-gif.sh -i input.mov -o out/demo.gif --max-size reference.gif

  # Match another GIF's resolution (width, not weight)
  make-gif.sh -i input.mov -o out/demo.gif --speed 2 -w reference.gif

  # "Not worse than reference.gif": resolution floor + weight ceiling, both at once
  make-gif.sh -i input.mov -o out/demo.gif --speed 2 --reference reference.gif
EOF
}

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) INPUT="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -s|--start) START="$2"; shift 2 ;;
    -t|--duration) DURATION="$2"; shift 2 ;;
    -p|--photo-time) PHOTO_TIME="$2"; shift 2 ;;
    --speed) SPEED="$2"; shift 2 ;;
    --crop) CROP="$2"; shift 2 ;;
    -r|--fps) FPS="$2"; FPS_SET=1; shift 2 ;;
    -w|--width) WIDTH="$2"; WIDTH_SET=1; shift 2 ;;
    --colors) COLORS="$2"; COLORS_SET=1; shift 2 ;;
    --dither) DITHER="$2"; DITHER_SET=1; shift 2 ;;
    --stats-mode) STATS_MODE="$2"; STATS_SET=1; shift 2 ;;
    --loop) LOOP="$2"; shift 2 ;;
    -m|--max-size) MAX_SIZE_ARG="$2"; MAX_SIZE_SET=1; shift 2 ;;
    --lossy) LOSSY="$2"; LOSSY_SET=1; shift 2 ;;
    -R|--reference) REFERENCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------- validate numeric options early ----------
die() { echo "Error: $*" >&2; exit 1; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_number() { [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; }
is_positive() { awk -v v="$1" 'BEGIN{exit !(v>0)}'; }

is_number "$FPS" && is_positive "$FPS" && awk -v f="$FPS" 'BEGIN{exit !(f<=240)}' \
  || die "--fps must be a number in 1..240 (got: $FPS)"
is_number "$SPEED" && is_positive "$SPEED" \
  || die "--speed must be a positive number (got: $SPEED)"
if [[ -n "$PHOTO_TIME" ]]; then
  is_number "$PHOTO_TIME" && is_positive "$PHOTO_TIME" \
    || die "--photo-time must be a positive number (got: $PHOTO_TIME)"
fi
is_uint "$COLORS" && [[ "$COLORS" -ge 2 && "$COLORS" -le 256 ]] \
  || die "--colors must be an integer in 2..256 (got: $COLORS)"
[[ "$LOOP" =~ ^-?[0-9]+$ ]] || die "--loop must be an integer (got: $LOOP)"
is_uint "$LOSSY" && [[ "$LOSSY" -le 200 ]] \
  || die "--lossy must be an integer in 0..200 (got: $LOSSY)"
if [[ -n "$DURATION" ]] && is_number "$DURATION"; then
  is_positive "$DURATION" || die "--duration must be positive (got: $DURATION)"
fi
if [[ -n "$CROP" && "$CROP" != "auto" ]]; then
  [[ "$CROP" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] \
    || die '--crop must be "w:h:x:y" or "auto" (got: '"$CROP"')'
  IFS=':' read -r _cw _ch _cx _cy <<< "$CROP"
  [[ "$_cw" -gt 0 && "$_ch" -gt 0 ]] \
    || die "--crop width/height must be greater than 0 (got: $CROP)"
fi

# ---------- ensure ffmpeg/ffprobe are available ----------
ensure_ffmpeg() {
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && return 0

  echo "ffmpeg not found on this system." >&2
  local os; os="$(uname -s)"

  case "$os" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        echo "Installing ffmpeg via Homebrew (brew install ffmpeg)..." >&2
        if brew install ffmpeg; then
          echo "ffmpeg installed." >&2
          return 0
        fi
        echo "Homebrew install failed. Install manually: brew install ffmpeg" >&2
      else
        cat >&2 <<'EOM'
Homebrew not found. To install ffmpeg:
  1. Install Homebrew:  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     then run:           brew install ffmpeg
  2. Or grab a static build from https://evermeet.cx/ffmpeg/ and put it on your PATH.
EOM
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "Debian/Ubuntu detected. Install with:  sudo apt-get update && sudo apt-get install -y ffmpeg" >&2
      elif command -v dnf >/dev/null 2>&1; then
        echo "Fedora detected. Install with:  sudo dnf install -y ffmpeg" >&2
      elif command -v pacman >/dev/null 2>&1; then
        echo "Arch detected. Install with:  sudo pacman -S ffmpeg" >&2
      elif command -v zypper >/dev/null 2>&1; then
        echo "openSUSE detected. Install with:  sudo zypper install ffmpeg" >&2
      else
        echo "Install ffmpeg via your distro's package manager, or see https://ffmpeg.org/download.html" >&2
      fi
      echo "(Not auto-installing on Linux — it needs sudo/a password.)" >&2
      ;;
    *)
      echo "Unrecognized OS ($os). Download ffmpeg from https://ffmpeg.org/download.html" >&2
      ;;
  esac

  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1
}

ensure_ffmpeg || { echo "Error: ffmpeg/ffprobe still not available, aborting" >&2; exit 1; }

[[ -n "$INPUT" ]] || { echo "Error: -i/--input is required" >&2; exit 1; }

REFERENCE_ACTIVE=0
if [[ -n "$REFERENCE" ]]; then
  [[ -f "$REFERENCE" ]] || { echo "Error: --reference file not found: $REFERENCE" >&2; exit 1; }
  REFERENCE_ACTIVE=1
  [[ "$WIDTH_SET" -eq 0 ]] && WIDTH="$REFERENCE"
  [[ "$MAX_SIZE_SET" -eq 0 ]] && MAX_SIZE_ARG="$REFERENCE"
fi

# ---------- built-in weight baseline ----------
# Neither -m/--max-size nor -R/--reference given? Cap at the built-in ceiling
# instead of leaving weight unconstrained. This is a fixed constant (see
# DEFAULT_MAX_SIZE_BYTES above) — no file is read to get it. `-m none` (or
# off/unlimited) explicitly disables the cap for maximum quality.
max_lc="$(printf '%s' "$MAX_SIZE_ARG" | tr '[:upper:]' '[:lower:]')"
if [[ "$max_lc" == "none" || "$max_lc" == "off" || "$max_lc" == "unlimited" ]]; then
  NO_CAP=1
  MAX_SIZE_ARG=""
  echo "Weight cap disabled (-m $max_lc) — keeping the requested quality." >&2
fi
if [[ "$NO_CAP" -eq 0 && -z "$MAX_SIZE_ARG" ]]; then
  MAX_SIZE_ARG="$DEFAULT_MAX_SIZE_BYTES"
  baseline_m="$(awk -v b="$DEFAULT_MAX_SIZE_BYTES" 'BEGIN{printf "%.1f", b/1048576}')"
  echo "No -m/--max-size given — capping output at the built-in baseline (~${baseline_m}M). Pass -m, -R, or -m none to change this." >&2
fi

# -w/--width also accepts a path to another file — resolve it to that file's
# pixel width, so output resolution can be pinned to match a reference.
# Anything else must be a positive integer width; a typo used to reach ffmpeg
# as scale=<garbage> and fail with an opaque error code.
if [[ -f "$WIDTH" ]]; then
  resolved_w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$WIDTH" 2>/dev/null)"
  [[ -n "$resolved_w" ]] || die "couldn't read a video width from $WIDTH"
  echo "Using width from $WIDTH: ${resolved_w}px" >&2
  WIDTH="$resolved_w"
elif ! is_uint "$WIDTH" || [[ "$WIDTH" -lt 2 ]]; then
  die "-w/--width must be a pixel width >= 2 or an existing file, not: $WIDTH"
fi

# ---------- work dir ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PALETTE="$WORKDIR/palette.png"

# ---------- mode detection ----------
IMAGE_EXT_RE='\.(jpe?g|png|bmp|tiff?|webp)$'
GIF_EXT_RE='\.[Gg][Ii][Ff]$'
MODE=""
declare -a PHOTO_FILES=()

# Natural sort (1.jpg < 2.jpg < 10.jpg) when the local sort supports -V;
# plain lexicographic sort otherwise. Both -z flags keep paths with spaces intact.
SORT_OPTS=(-z)
if printf '' | sort -z -V >/dev/null 2>&1; then SORT_OPTS=(-z -V); fi

# Case-insensitive extension checks: a glob like *.JPG must not be mistaken for
# non-image files (the regexes below are lowercase). Scoped to mode detection.
shopt -s nocasematch

if [[ -d "$INPUT" ]]; then
  MODE="images"
  while IFS= read -r -d '' f; do PHOTO_FILES+=("$f"); done < <(
    find "$INPUT" -maxdepth 1 -type f \( \
      -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
      -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.webp' \
    \) -print0 | sort "${SORT_OPTS[@]}"
  )
  [[ ${#PHOTO_FILES[@]} -gt 0 ]] || die "no photos found in directory: $INPUT"
elif [[ "$INPUT" == *[*?]* ]]; then
  MODE="images"
  shopt -s nullglob
  # shellcheck disable=SC2206  # intentional: expand the user's quoted glob
  matched=( $INPUT )
  shopt -u nullglob
  PHOTO_FILES=()
  skipped=0
  if [[ ${#matched[@]} -gt 0 ]]; then
    for f in "${matched[@]}"; do
      if [[ -f "$f" && "$f" =~ $IMAGE_EXT_RE ]]; then
        PHOTO_FILES+=("$f")
      elif [[ ! -d "$f" ]]; then
        skipped=$((skipped + 1))
      fi
    done
  fi
  if [[ "$skipped" -gt 0 ]]; then
    echo "Warning: ignored $skipped non-image match(es) from the glob" >&2
  fi
  [[ ${#PHOTO_FILES[@]} -gt 0 ]] || die "glob matched no photos: $INPUT"
elif [[ -f "$INPUT" ]]; then
  if [[ "$INPUT" =~ $GIF_EXT_RE ]]; then
    MODE="gif"
  elif [[ "$INPUT" =~ $IMAGE_EXT_RE ]]; then
    MODE="images"
    PHOTO_FILES=("$INPUT")
  else
    MODE="video"
  fi
else
  die "input not found: $INPUT"
fi
shopt -u nocasematch

# ---------- output path default ----------
if [[ -z "$OUTPUT" ]]; then
  base="$(basename "${PHOTO_FILES[0]:-$INPUT}")"
  base="${base%.*}"
  if [[ -d "out" ]]; then OUTPUT="out/${base}.gif"; else OUTPUT="${base}.gif"; fi
fi
mkdir -p "$(dirname "$OUTPUT")"

# ---------- existing GIF: keep the source fps/width by default ----------
# Re-encoding a 50 fps 960 px GIF at the generic 10 fps / 640 px defaults would
# silently destroy most of its frames and sharpness — exactly what "shrink an
# existing GIF" must not do.
if [[ "$MODE" == "gif" ]]; then
  gif_probe="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,avg_frame_rate -of csv=p=0 "$INPUT" 2>/dev/null)"
  gif_w="${gif_probe%%,*}"
  gif_fr="${gif_probe#*,}"
  [[ -n "$gif_w" ]] || die "couldn't read a width from GIF: $INPUT"
  gif_fps="$(awk -v f="$gif_fr" 'BEGIN{n=split(f,a,"/"); if(n==2 && a[1]>0 && a[2]>0) printf "%.6f", a[1]/a[2]; else print "0"}')"
  if ! is_positive "$gif_fps"; then
    gif_fr="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$INPUT" 2>/dev/null)"
    gif_fps="$(awk -v f="$gif_fr" 'BEGIN{n=split(f,a,"/"); if(n==2 && a[1]>0 && a[2]>0) printf "%.6f", a[1]/a[2]; else print "10"}')"
  fi
  if [[ "$FPS_SET" -eq 0 ]]; then FPS="$gif_fps"; fi
  # -R's resolution floor (already resolved into WIDTH) wins over the source width.
  if [[ "$WIDTH_SET" -eq 0 && "$REFERENCE_ACTIVE" -eq 0 ]]; then WIDTH="$gif_w"; fi
  if ! is_uint "$WIDTH" || [[ "$WIDTH" -lt 2 ]]; then
    die "couldn't read a usable width from GIF: $INPUT"
  fi
  echo "GIF input: keeping fps=$FPS width=$WIDTH unless overridden" >&2
fi

# ---------- gifsicle availability ----------
HAVE_GIFSICLE=0
if command -v gifsicle >/dev/null 2>&1; then HAVE_GIFSICLE=1; fi
if [[ "$LOSSY_SET" -eq 1 && "$HAVE_GIFSICLE" -eq 0 ]]; then
  die "--lossy requires gifsicle (brew install gifsicle, or sudo apt-get install -y gifsicle)"
fi

# Pure optimize: a GIF with no re-encode options can go straight through
# gifsicle -O3, which is lossless (and --lossy is opt-in on top).
PURE_OPT=0
if [[ "$MODE" == "gif" && -z "$CROP" && "$SPEED" == "1" && -z "$START" && -z "$DURATION" \
      && -z "$PHOTO_TIME" && "$FPS_SET" -eq 0 && "$WIDTH_SET" -eq 0 \
      && "$COLORS_SET" -eq 0 && "$DITHER_SET" -eq 0 && "$STATS_SET" -eq 0 \
      && "$REFERENCE_ACTIVE" -eq 0 && "$LOOP" -eq 0 ]]; then
  PURE_OPT=1
fi

# Photo timing is a property of the slideshow, not of -r: when -p is set the
# real output rate is 1/p, and that is what the final report must show.
PHOTO_INTERVAL=""
if [[ "$MODE" == "images" ]]; then
  PHOTO_INTERVAL="${PHOTO_TIME:-$(awk -v f="$FPS" 'BEGIN{printf "%.6f", 1/f}')}"
fi

case "$MODE" in
  video|gif)
    if [[ -n "$PHOTO_TIME" ]]; then
      echo "Warning: -p/--photo-time only applies to photo input; ignoring it" >&2
    fi
    ;;
  images)
    if [[ -n "$START" || -n "$DURATION" || "$SPEED" != "1" ]]; then
      echo "Warning: -s/-t/--speed only apply to video/GIF input; ignoring them" >&2
    fi
    ;;
esac

# ---------- crop auto-detect (video/GIF only) ----------
if [[ "$CROP" == "auto" ]]; then
  case "$MODE" in
    video|gif)
      probe_start="${START:-0}"
      detected="$(
        ffmpeg -v info -nostats -ss "$probe_start" -t 3 -i "$INPUT" \
          -vf "cropdetect=24:16:0" -f null - 2>&1 \
          | { grep -o 'crop=[0-9:]*' || true; } | tail -1 | cut -d= -f2
      )"
      if [[ -z "$detected" ]]; then
        echo "Warning: crop auto-detect found nothing, encoding uncropped" >&2
        CROP=""
      else
        echo "Auto-detected crop: $detected" >&2
        CROP="$detected"
      fi
      ;;
    *)
      die '--crop auto works only for video/GIF input; for photos pass an explicit "w:h:x:y" rectangle'
      ;;
  esac
fi

# join two filter-chain fragments with a comma, tolerating an empty left side
join_filter() { if [[ -z "$1" ]]; then printf '%s' "$2"; else printf '%s,%s' "$1" "$2"; fi }

filesize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

# parse a --max-size value: an existing file's size, or "8M"/"500K"/"12345"(bytes)
parse_size() {
  local arg="$1"
  if [[ -f "$arg" ]]; then filesize "$arg"; return; fi
  local s="${arg%[Bb]}"
  if [[ "$s" =~ ^([0-9]+\.?[0-9]*)([KkMmGg]?)$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
      [Kk]) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
      [Mm]) awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}' ;;
      [Gg]) awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
      *) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
    esac
  else
    echo "Error: bad --max-size value: $arg (use e.g. 8M, 500K, a byte count, or an existing file path)" >&2
    exit 1
  fi
}

# gifsicle's LZW encoder is slightly tighter than ffmpeg's, and -O3 rewrites
# frame disposal/transparency without touching pixels. Applied to every output
# when gifsicle is present; --lossy is opt-in on top.
apply_gifsicle() {
  [[ "$HAVE_GIFSICLE" -eq 1 ]] || return 0
  local tmp="$WORKDIR/gifsicle.tmp.gif"
  local args=(-O3)
  if [[ "$LOSSY" -gt 0 ]]; then args+=(--lossy="$LOSSY"); fi
  if gifsicle "${args[@]}" "$1" -o "$tmp" 2>/dev/null; then
    if [[ "$(filesize "$tmp")" -lt "$(filesize "$1")" ]]; then
      mv "$tmp" "$1"
      USED_GIFSICLE=1
    else
      rm -f "$tmp"
    fi
  else
    rm -f "$tmp"
    echo "Warning: gifsicle optimization failed, keeping the encoded file" >&2
  fi
}

# ---------- build filter chain, input args, and run the two ffmpeg passes ----------
# Re-run on every auto-tune step, since FPS/WIDTH/COLORS may have changed.
run_encode() {
  FILTERS=""
  declare -a INPUT_ARGS=()

  if [[ "$MODE" == "video" || "$MODE" == "gif" ]]; then
    [[ -n "$CROP" ]] && FILTERS="crop=${CROP},"
    if [[ "$SPEED" != "1" ]]; then
      FILTERS="${FILTERS}setpts=PTS/${SPEED},"
    fi
    FILTERS="${FILTERS}fps=${FPS},scale=${WIDTH}:-2:flags=lanczos"

    [[ -n "$START" ]] && INPUT_ARGS+=(-ss "$START")
    [[ -n "$DURATION" ]] && INPUT_ARGS+=(-t "$DURATION")
    INPUT_ARGS+=(-i "$INPUT")
  else
    # Photos rarely share one resolution/orientation, and the concat demuxer
    # requires uniform frame size — so pre-render each photo onto a common
    # letterboxed canvas first, then feed ffmpeg a plain numbered sequence.
    # Redone every call since WIDTH (canvas size) may have changed.
    local first_photo="${PHOTO_FILES[0]}" crop_w crop_h _crop_x _crop_y wh canvas_h per_photo_filter idx f
    if [[ -n "$CROP" ]]; then
      IFS=':' read -r crop_w crop_h _crop_x _crop_y <<< "$CROP"
    else
      wh="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$first_photo")"
      crop_w="${wh%,*}"
      crop_h="${wh#*,}"
    fi
    canvas_h="$(awk -v w="$WIDTH" -v cw="$crop_w" -v ch="$crop_h" 'BEGIN{h=int((w*ch/cw)/2+0.5)*2; if(h<2)h=2; print h}')"

    per_photo_filter=""
    [[ -n "$CROP" ]] && per_photo_filter="crop=${CROP},"
    per_photo_filter="${per_photo_filter}scale=${WIDTH}:${canvas_h}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${WIDTH}:${canvas_h}:(ow-iw)/2:(oh-ih)/2:color=black"

    rm -rf "$WORKDIR/seq"; mkdir -p "$WORKDIR/seq"
    idx=0
    for f in "${PHOTO_FILES[@]}"; do
      idx=$((idx + 1))
      if ! ffmpeg -y -v error -i "$f" -vf "$per_photo_filter" -frames:v 1 \
        "$WORKDIR/seq/$(printf '%05d' "$idx").png"; then
        if [[ -n "$CROP" ]]; then
          pwh="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null)"
          die "couldn't render $f with --crop $CROP (photo is ${pwh:-unknown size}); the crop rectangle must fit every photo"
        fi
        die "couldn't render photo: $f"
      fi
    done

    local framerate_val
    framerate_val="$(awk -v t="$PHOTO_INTERVAL" 'BEGIN{printf "%.6f", 1/t}')"
    INPUT_ARGS+=(-framerate "$framerate_val" -i "$WORKDIR/seq/%05d.png")
    # crop/scale/pad are already baked into the sequence frames
    FILTERS=""
  fi

  # pass 1: palette
  ffmpeg -y -v error "${INPUT_ARGS[@]}" \
    -vf "$(join_filter "$FILTERS" "palettegen=max_colors=${COLORS}:stats_mode=${STATS_MODE}")" \
    "$PALETTE"

  # pass 2: encode with palette
  local encode_lavfi
  if [[ -n "$FILTERS" ]]; then
    encode_lavfi="${FILTERS}[x];[x][1:v]paletteuse=dither=${DITHER}"
  else
    encode_lavfi="[0:v][1:v]paletteuse=dither=${DITHER}"
  fi
  ffmpeg -y -v error "${INPUT_ARGS[@]}" -i "$PALETTE" \
    -lavfi "$encode_lavfi" \
    -loop "$LOOP" \
    "$OUTPUT"
  apply_gifsicle "$OUTPUT"
}

# Pure GIF optimization skips ffmpeg entirely; anything with re-encode options
# goes through the palette pipeline, with gifsicle tightening the result.
if [[ "$PURE_OPT" -eq 1 && "$HAVE_GIFSICLE" -eq 1 ]]; then
  gs_args=(-O3)
  if [[ "$LOSSY" -gt 0 ]]; then gs_args+=(--lossy="$LOSSY"); fi
  gs_tmp="$WORKDIR/pure.tmp.gif"
  gifsicle "${gs_args[@]}" "$INPUT" -o "$gs_tmp" || die "gifsicle failed on $INPUT"
  mv "$gs_tmp" "$OUTPUT"
  USED_GIFSICLE=1
else
  if [[ "$PURE_OPT" -eq 1 && "$HAVE_GIFSICLE" -eq 0 ]]; then
    echo "gifsicle not found — falling back to ffmpeg at the source fps/width. Install gifsicle for lossless GIF optimization (brew install gifsicle / sudo apt-get install -y gifsicle)." >&2
  fi
  run_encode
fi
CUR_SIZE="$(filesize "$OUTPUT")"
MAX_SIZE_BYTES=""

# ---------- auto-tune down to a size budget, if requested ----------
if [[ "$NO_CAP" -eq 0 && -n "$MAX_SIZE_ARG" ]]; then
  MAX_SIZE_BYTES="$(parse_size "$MAX_SIZE_ARG")"

  if [[ "$PURE_OPT" -eq 1 && "$HAVE_GIFSICLE" -eq 1 ]]; then
    # No pixels to touch here, so the only lever is gifsicle's lossy mode —
    # and only when the user did not pin a level explicitly.
    if [[ "$CUR_SIZE" -gt "$MAX_SIZE_BYTES" && "$LOSSY_SET" -eq 0 ]]; then
      for n in 20 40 60 80 100 150 200; do
        if ! gifsicle -O3 --lossy="$n" "$INPUT" -o "$WORKDIR/lossy.tmp.gif"; then
          break
        fi
        mv "$WORKDIR/lossy.tmp.gif" "$OUTPUT"
        LOSSY="$n"
        USED_GIFSICLE=1
        CUR_SIZE="$(filesize "$OUTPUT")"
        echo "  retry: gifsicle --lossy=$n -> $(( CUR_SIZE / 1024 ))K" >&2
        if [[ "$CUR_SIZE" -le "$MAX_SIZE_BYTES" ]]; then break; fi
      done
    fi
    if [[ "$CUR_SIZE" -le "$MAX_SIZE_BYTES" ]]; then
      echo "Within budget: $(( CUR_SIZE / 1024 ))K <= $(( MAX_SIZE_BYTES / 1024 ))K" >&2
    elif [[ "$LOSSY" -gt 0 ]]; then
      echo "Still over budget: $(( CUR_SIZE / 1024 ))K > $(( MAX_SIZE_BYTES / 1024 ))K at gifsicle --lossy=$LOSSY. Raise --lossy, reduce -w/-r, or raise --max-size." >&2
    else
      echo "Still over budget: $(( CUR_SIZE / 1024 ))K > $(( MAX_SIZE_BYTES / 1024 ))K. Lossless optimization is already applied; use --lossy N, -w/-r, or a larger --max-size." >&2
    fi
  else
    FPS_FLOOR=5
    # In reference mode, WIDTH is already the reference's own resolution — never
    # shrink below it, or "not worse than the reference" would be a lie.
    if [[ "$REFERENCE_ACTIVE" -eq 1 ]]; then WIDTH_FLOOR="$WIDTH"; else WIDTH_FLOOR=160; fi
    COLORS_FLOOR=32
    attempt=0
    while [[ "$CUR_SIZE" -gt "$MAX_SIZE_BYTES" && $attempt -lt 15 ]]; do
      attempt=$((attempt + 1))
      if [[ "$MODE" == "video" || "$MODE" == "gif" ]] && [[ "$FPS" -gt "$FPS_FLOOR" ]]; then
        FPS="$(awk -v f="$FPS" -v floor="$FPS_FLOOR" 'BEGIN{v=int(f*0.8+0.5); if(v>=f)v=f-1; if(v<floor)v=floor; print v}')"
      elif [[ "$WIDTH" -gt "$WIDTH_FLOOR" ]]; then
        WIDTH="$(awk -v w="$WIDTH" -v floor="$WIDTH_FLOOR" 'BEGIN{v=int(w*0.85/2+0.5)*2; if(v>=w)v=w-2; if(v<floor)v=floor; print v}')"
      elif [[ "$COLORS" -gt "$COLORS_FLOOR" ]]; then
        COLORS=$(( COLORS / 2 ))
        [[ "$COLORS" -lt "$COLORS_FLOOR" ]] && COLORS="$COLORS_FLOOR"
      else
        if [[ "$REFERENCE_ACTIVE" -eq 1 ]]; then
          echo "Warning: still over budget at the reference's own resolution (${WIDTH}px, held as a floor) and fps=${FPS_FLOOR}/colors=${COLORS_FLOOR} — the source has more to encode than the reference did at that size. Trim the duration, or accept going over on weight." >&2
        else
          echo "Warning: hit quality floors (fps>=${FPS_FLOOR}, width>=${WIDTH_FLOOR}, colors>=${COLORS_FLOOR}) and still over budget — trim the duration or raise --max-size" >&2
        fi
        break
      fi
      run_encode
      CUR_SIZE="$(filesize "$OUTPUT")"
      echo "  retry $attempt: fps=$FPS width=$WIDTH colors=$COLORS -> $(( CUR_SIZE / 1024 ))K" >&2
    done

    if [[ "$CUR_SIZE" -le "$MAX_SIZE_BYTES" ]]; then
      echo "Within budget: $(( CUR_SIZE / 1024 ))K <= $(( MAX_SIZE_BYTES / 1024 ))K" >&2
    else
      echo "Still over budget after ${attempt} retries: $(( CUR_SIZE / 1024 ))K > $(( MAX_SIZE_BYTES / 1024 ))K (best effort)" >&2
    fi
  fi
fi

if [[ "$MODE" == "images" ]]; then
  report_fps="$(awk -v t="$PHOTO_INTERVAL" 'BEGIN{printf "%.3g", 1/t}')"
else
  report_fps="$(awk -v f="$FPS" 'BEGIN{printf "%.3g", f}')"
fi
size_h="$(awk -v b="$CUR_SIZE" 'BEGIN{if(b>=1048576)printf "%.1fM",b/1048576; else printf "%dK",b/1024}')"
ref_note=""
if [[ "$REFERENCE_ACTIVE" -eq 1 ]]; then
  ref_note=", not-worse-than $REFERENCE: resolution held"
  if [[ "$NO_CAP" -eq 0 && -n "$MAX_SIZE_ARG" && "$CUR_SIZE" -gt "$MAX_SIZE_BYTES" ]]; then
    ref_note="${ref_note}, weight over budget"
  elif [[ "$NO_CAP" -eq 0 && -n "$MAX_SIZE_ARG" ]]; then
    ref_note="${ref_note}, weight within budget"
  fi
fi
gif_note=""
if [[ "$USED_GIFSICLE" -eq 1 ]]; then
  gif_note=", gifsicle -O3"
  if [[ "$LOSSY" -gt 0 ]]; then gif_note="${gif_note} lossy=$LOSSY"; fi
fi
if [[ "$PURE_OPT" -eq 1 && "$USED_GIFSICLE" -eq 1 ]]; then
  params="fps=$report_fps width=$WIDTH"
else
  params="fps=$report_fps width=$WIDTH colors=$COLORS"
fi
echo "Done: $OUTPUT ($size_h, $params${gif_note}${ref_note})" >&2
