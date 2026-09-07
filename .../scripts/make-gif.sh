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
# Built-in weight ceiling, applied by default when neither -m/--max-size nor
# -R/--reference is given. Used to be looked up from a locally-present GIF's
# file size — that read the same value but only worked when that file
# happened to exist; the number is now baked in directly.
DEFAULT_MAX_SIZE_BYTES=8223879

usage() {
  cat <<'EOF'
make-gif.sh — build an optimized GIF from a video or photos (ffmpeg two-pass palette)

Usage:
  make-gif.sh -i INPUT -o OUTPUT.gif [options]

Input:
  -i, --input PATH        video file, photo directory, or quoted glob (required)
  -o, --output PATH       output .gif path (default: out/<name>.gif or ./<name>.gif)

Video-only options:
  -s, --start TIME        start offset, e.g. 00:00:05 or 5
  -t, --duration SECONDS  clip length to encode (default: whole input)
      --speed FACTOR      speed multiplier, e.g. 2 = twice as fast (default: 1)
      --crop SPEC         "w:h:x:y", or "auto" to auto-detect letterboxing/UI chrome

Photo-only options:
  -p, --photo-time SEC    seconds each photo is shown (default: 1/fps)

Common options:
  -r, --fps N              output frame rate (default: 10)
  -w, --width N             output width in px, height auto-scaled (default: 640).
                             Also accepts a file path — uses that file's own width
                             (e.g. -w ref.gif to match a reference's resolution).
      --colors N            max palette colors, 2-256 (default: 256)
      --dither MODE         none|bayer|sierra2_4a|floyd_steinberg... (default: sierra2_4a)
      --stats-mode MODE     full|diff|single for palettegen (default: full;
                             use "diff" for screencasts/whiteboards — mostly-static
                             frame with a small moving region)
  -m, --max-size SIZE       size budget: "8M", "500K", a raw byte count, or a path
                             to another file whose size to match. If the first
                             encode comes out bigger, fps/colors (and width, but
                             never below -R's floor) are stepped down and it
                             re-encodes automatically until it fits or hits a floor.
                             Default: a built-in ~7.8M ceiling, applied unless you
                             pass -m or -R yourself (prints a note when it does).
  -R, --reference FILE      shorthand for "not worse than FILE": sets --width to
                             FILE's resolution (a floor auto-tune won't shrink below)
                             and --max-size to FILE's weight (a ceiling), in one go.
                             An explicit -w or --max-size of your own overrides just
                             that half. FILE must exist on disk — this only matches
                             a real file you point it at, nothing is auto-detected.
  -h, --help                show this help

Examples:
  # Video clip, cropped to a region, sped up 2x, 10s starting at 0:05
  make-gif.sh -i input.mov -o out/demo.gif -s 5 -t 10 --speed 2 \
    --crop "2400:1600:500:300" -r 12 -w 640

  # Auto-detect crop (e.g. strip browser chrome from a screen recording)
  make-gif.sh -i input.mov -o out/demo.gif --crop auto

  # Slideshow from a folder of photos, 1.5s per photo
  make-gif.sh -i photos/ -o out/slideshow.gif -p 1.5 -w 720

  # Must not exceed 2MB — auto-tunes fps/width/colors down until it fits
  make-gif.sh -i input.mov -o out/demo.gif --max-size 2M

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
    -r|--fps) FPS="$2"; shift 2 ;;
    -w|--width) WIDTH="$2"; WIDTH_SET=1; shift 2 ;;
    --colors) COLORS="$2"; shift 2 ;;
    --dither) DITHER="$2"; shift 2 ;;
    --stats-mode) STATS_MODE="$2"; shift 2 ;;
    --loop) LOOP="$2"; shift 2 ;;
    -m|--max-size) MAX_SIZE_ARG="$2"; MAX_SIZE_SET=1; shift 2 ;;
    -R|--reference) REFERENCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

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
# DEFAULT_MAX_SIZE_BYTES above) — no file is read to get it.
if [[ -z "$MAX_SIZE_ARG" ]]; then
  MAX_SIZE_ARG="$DEFAULT_MAX_SIZE_BYTES"
  echo "No -m/--max-size given — capping output at the built-in baseline (~$(( DEFAULT_MAX_SIZE_BYTES / 1024 / 1024 ))M). Pass -m/--max-size/--reference yourself to change this." >&2
fi

# -w/--width also accepts a path to another file — resolve it to that file's
# pixel width, so output resolution can be pinned to match a reference.
if [[ -f "$WIDTH" ]]; then
  resolved_w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$WIDTH" 2>/dev/null)"
  [[ -n "$resolved_w" ]] || { echo "Error: couldn't read a video width from $WIDTH" >&2; exit 1; }
  echo "Using width from $WIDTH: ${resolved_w}px" >&2
  WIDTH="$resolved_w"
fi

# ---------- work dir ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
PALETTE="$WORKDIR/palette.png"

# ---------- mode detection ----------
IMAGE_EXT_RE='\.(jpe?g|png|bmp|tiff?|webp)$'
MODE=""
declare -a PHOTO_FILES=()

if [[ -d "$INPUT" ]]; then
  MODE="images"
  while IFS= read -r -d '' f; do PHOTO_FILES+=("$f"); done < <(
    find "$INPUT" -maxdepth 1 -type f \( \
      -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
      -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.webp' \
    \) -print0 | sort -z
  )
  [[ ${#PHOTO_FILES[@]} -gt 0 ]] || { echo "Error: no photos found in directory: $INPUT" >&2; exit 1; }
elif [[ "$INPUT" == *[*?]* ]]; then
  MODE="images"
  shopt -s nullglob
  PHOTO_FILES=( $INPUT )
  shopt -u nullglob
  [[ ${#PHOTO_FILES[@]} -gt 0 ]] || { echo "Error: glob matched no files: $INPUT" >&2; exit 1; }
elif [[ -f "$INPUT" ]]; then
  if [[ "$INPUT" =~ $IMAGE_EXT_RE ]]; then
    MODE="images"
    PHOTO_FILES=("$INPUT")
  else
    MODE="video"
  fi
else
  echo "Error: input not found: $INPUT" >&2
  exit 1
fi

# ---------- output path default ----------
if [[ -z "$OUTPUT" ]]; then
  base="$(basename "${PHOTO_FILES[0]:-$INPUT}")"
  base="${base%.*}"
  if [[ -d "out" ]]; then OUTPUT="out/${base}.gif"; else OUTPUT="${base}.gif"; fi
fi
mkdir -p "$(dirname "$OUTPUT")"

# ---------- crop auto-detect (video only) ----------
if [[ "$MODE" == "video" && "$CROP" == "auto" ]]; then
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

# ---------- build filter chain, input args, and run the two ffmpeg passes ----------
# Re-run on every auto-tune step, since FPS/WIDTH/COLORS may have changed.
run_encode() {
  FILTERS=""
  declare -a INPUT_ARGS=()

  if [[ "$MODE" == "video" ]]; then
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
      ffmpeg -y -v error -i "$f" -vf "$per_photo_filter" -frames:v 1 \
        "$WORKDIR/seq/$(printf '%05d' "$idx").png"
    done

    local per_photo framerate_val
    per_photo="${PHOTO_TIME:-$(awk -v f="$FPS" 'BEGIN{printf "%.6f", 1/f}')}"
    framerate_val="$(awk -v t="$per_photo" 'BEGIN{printf "%.6f", 1/t}')"
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
}

run_encode
CUR_SIZE="$(filesize "$OUTPUT")"

# ---------- auto-tune down to a size budget, if requested ----------
if [[ -n "$MAX_SIZE_ARG" ]]; then
  MAX_SIZE_BYTES="$(parse_size "$MAX_SIZE_ARG")"
  FPS_FLOOR=5
  # In reference mode, WIDTH is already the reference's own resolution — never
  # shrink below it, or "not worse than the reference" would be a lie.
  if [[ "$REFERENCE_ACTIVE" -eq 1 ]]; then WIDTH_FLOOR="$WIDTH"; else WIDTH_FLOOR=160; fi
  COLORS_FLOOR=32
  attempt=0
  while [[ "$CUR_SIZE" -gt "$MAX_SIZE_BYTES" && $attempt -lt 15 ]]; do
    attempt=$((attempt + 1))
    if [[ "$MODE" == "video" && "$FPS" -gt "$FPS_FLOOR" ]]; then
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

size_h="$(awk -v b="$CUR_SIZE" 'BEGIN{if(b>=1048576)printf "%.1fM",b/1048576; else printf "%dK",b/1024}')"
if [[ "$REFERENCE_ACTIVE" -eq 1 ]]; then
  ref_note=", not-worse-than $REFERENCE: resolution held"
  [[ -n "$MAX_SIZE_ARG" && "$CUR_SIZE" -gt "$MAX_SIZE_BYTES" ]] && ref_note="${ref_note}, weight over budget"
  [[ -n "$MAX_SIZE_ARG" && "$CUR_SIZE" -le "$MAX_SIZE_BYTES" ]] && ref_note="${ref_note}, weight within budget"
else
  ref_note=""
fi
echo "Done: $OUTPUT ($size_h, fps=$FPS width=$WIDTH colors=$COLORS${ref_note})" >&2
