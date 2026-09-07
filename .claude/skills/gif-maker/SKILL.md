---
name: gif-maker
description: Convert a video clip or a set of photos into an optimized animated GIF using ffmpeg's two-pass palette pipeline (palettegen/paletteuse). Use when the user asks to make/create/build a GIF from a video (.mov/.mp4/etc.) or from photos, or to shrink/improve an existing GIF's file size or quality.
---

# gif-maker

## When to use

The user wants an animated GIF from a video clip or a folder of photos, or wants an
existing GIF re-encoded to be smaller/sharper.

## Why not just `ffmpeg -i in.mov out.gif`

ffmpeg's default GIF encoder uses a fixed, generic palette. That produces banding on
gradients and bloats file size — a naive encode routinely comes out 5-10x larger than
necessary for the same visual quality. The fix is the standard two-pass approach:

1. `palettegen` — analyze the actual frames and build an optimal ≤256-color palette.
2. `paletteuse` — re-encode against that palette, with dithering to hide banding.

This skill wraps that pipeline in `scripts/make-gif.sh` with the filters (crop, fps,
scale, speed, trim) needed to get from raw footage/photos to a usable GIF.

## Requirements

`ffmpeg` and `ffprobe` on `PATH`. The script checks for both and, if missing:

- **macOS with Homebrew**: installs automatically (`brew install ffmpeg`).
- **macOS without Homebrew**: prints Homebrew-install and static-build instructions.
- **Linux**: prints the right package-manager command (`apt`/`dnf`/`pacman`/`zypper`) —
  it does not auto-run `sudo` since that needs an interactive password.
- **Other/unrecognized OS**: points to https://ffmpeg.org/download.html.

## Procedure

1. Identify the input: a single video file, a directory of photos, or a glob of photos.
2. If the user described the result in words rather than flags (crop, speed, quality,
   length), translate it — see "Turning a spoken request into flags" below. For any
   numeric value you can't read off the request itself (crop rectangle, trim window),
   pull a still frame or two first and look at them; don't guess coordinates blind.
3. Run the script:
   ```bash
   .claude/skills/gif-maker/scripts/make-gif.sh -i INPUT -o OUTPUT.gif [options]
   ```
4. Check the reported output size (`Done: out.gif (X.XM)`). If it's too big, first
   lower `--fps` or `--width` (biggest impact), then `--colors`; only trim the duration
   as a last resort if the content genuinely needs to stay full-length.
5. `ffprobe` the result if you need to confirm dimensions/frame count/duration match
   expectations. Pull a frame or two from the output to sanity-check crop/legibility
   before calling it done — a wrong crop rectangle is a silent failure otherwise.
6. State what you actually picked (crop rect, speed, fps/width, trimmed range) — the
   user gave you words, not numbers, so say what those numbers ended up being.

## Options

| Flag | Applies to | Default | Notes |
|---|---|---|---|
| `-i, --input` | both | — | video file, photo dir, or quoted glob (`"photos/*.jpg"`) |
| `-o, --output` | both | `out/<name>.gif` or `./<name>.gif` | created dir if needed |
| `-s, --start` | video | start of file | `HH:MM:SS` or seconds |
| `-t, --duration` | video | whole clip | seconds to encode |
| `--speed` | video | `1` | `2` = 2x faster (timelapse), `0.5` = half speed |
| `--crop` | video | none | `"w:h:x:y"`, or `auto` to detect UI chrome/letterboxing |
| `-p, --photo-time` | photos | `1/fps` | seconds each photo is shown |
| `-r, --fps` | both | `10` | output frame rate |
| `-w, --width` | both | `640` | px, or a path to another file — uses *its* pixel width; height auto, kept even |
| `--colors` | both | `256` | palette size, 2-256 |
| `--dither` | both | `sierra2_4a` | `none` for flat UI/screenshot content, keeps edges crisp |
| `--stats-mode` | both | `full` | `diff` for screencasts/whiteboards: mostly-static frame with one small moving region — gives the moving part more palette budget |
| `-m, --max-size` | both | a built-in ~7.8M ceiling | size budget: `8M`, `500K`, a raw byte count, or a path to another file to match its size. Over budget → auto re-encodes, stepping fps down, then width (never below a `-R` floor), then colors, until it fits or hits a floor |
| `-R, --reference` | both | none | shorthand for "not worse than FILE": `-w FILE` (resolution floor) + `--max-size FILE` (weight ceiling) together. `FILE` must exist on disk — nothing is auto-detected. An explicit `-w`/`--max-size` of your own overrides just that half |

**Quality vs. weight — these are two different knobs, don't conflate them:**

- **Quality** (does it look sharp?) is set by `-r`/`-w`/`--colors`/`--dither` — the
  defaults (`10`/`640`/`256`/`sierra2_4a`) are fixed constants in the script, tuned to a
  known-good baseline. A fresh install produces that quality with no flags and no extra
  file needed.
- **Weight** is `-m/--max-size`. Its own default is also a fixed constant (see
  `DEFAULT_MAX_SIZE_BYTES` in the script, ~7.8M) — applied automatically whenever you
  don't pass `-m` or `-R` yourself, no file lookup involved. It's a hard ceiling on
  bytes, not a quality target — it does not try to *match* any file's look, only to not
  exceed a weight, and hitting a tight ceiling on hard content can cost real quality
  (see "Fitting a size budget").
- **Matching one specific file** — resolution, weight, or both — is what `-w <file>` /
  `-m <file>` / `-R/--reference <file>` are for. These only ever act on a file you
  explicitly name; the script never goes looking for one on its own.

## Turning a spoken request into flags

Users hand this skill a video/photos plus a description, not flags. Map it yourself —
don't ask the user for `w:h:x:y` or a speed multiplier unless the request is genuinely
ambiguous about *direction* (rarely).

| They say (RU/EN) | They mean | Do this |
|---|---|---|
| "убери браузер/интерфейс", "только доска/экран", "без рамки" | crop out UI chrome | try `--crop auto` first; if the chrome isn't a uniform-color border, pull a still and compute a manual `w:h:x:y` |
| "покажи только вот этот момент/кусок" | crop to a content region | pull a still, read the rectangle off it |
| "побыстрее", "ускорь", "таймлапс" | speed up | `--speed 2` by default; "сильно/значительно" → `--speed 3`-`4` |
| "помедленнее", "замедли", "slow-mo" | slow down | `--speed 0.5` |
| "покороче", "вырежи самое интересное" | trim | scan a few stills across the timeline to find the window, then `-s`/`-t` |
| "весит много", "полегче", "сожми" | shrink the file, no hard number given | lower `--fps` and `--width` first, then `--colors`; explain the trade-off if you had to cut hard |
| "не больше N МБ/КБ", "уложись в размер X" (weight only) | a concrete size cap | `--max-size` with that value, or the file's path — let the script's auto-tune find the params, don't hand-guess them |
| "не хуже референса/этого файла", "как X, но не тяжелее" (resolution *and* weight) | both floors at once | `--reference FILE` — don't compose `-w`/`--max-size` by hand for this, it's one flag |
| "почётче", "покачественнее", "не мыльный" | raise quality | bump `--width`, keep `--colors` at 256, consider `--dither floyd_steinberg` |
| "плавнее", "не дёргается" | smoother motion | raise `--fps` (note it costs size) |
| "слайд-шоу", "подольше на каждом фото" | photo timing | set `-p` (seconds/photo) from what they said, or a comfortable default like 1.5-2s |
| no quality/size steer at all | — | defaults (`-r 10 -w 640`, capped at the built-in ~7.8M weight ceiling) already give good quality with no flags and no reference file needed — see "Quality vs. weight" above |

If a request has no clear direction at all (e.g. "сделай покрасивее" with nothing to
anchor it), pick the most likely reading, say what you picked, and move on rather than
stopping to ask — the options table above gives you enough range to correct after
seeing the result.

## Cropping a screen recording

Screen recordings usually include browser chrome, menu bars, tab strips — dead weight
in a GIF. Two ways to remove it:

- `--crop auto`: runs ffmpeg's `cropdetect` for a few seconds and applies whatever it
  finds. Works well when the dead space is uniform color (letterboxing). It will *not*
  detect "browser UI vs. page content" — that's not a solid-color border.
- `--crop "w:h:x:y"`: manual rectangle. Get the numbers by eye from a still frame:
  ```bash
  ffmpeg -ss 5 -i input.mov -frames:v 1 frame.png   # inspect this to find the rect
  ```

## Sizing trade-offs

- **fps**: 8-12 fps is plenty for UI/screen content; drawings/typing read fine even at
  6-8. Higher fps mainly costs file size, not perceived smoothness for this kind of
  content.
- **width**: GIFs are almost always viewed small (chat, embedded). 480-640px is usually
  enough; don't default to source resolution.
- **colors**: drop to 128 or 64 for flat/UI content before touching fps/width — the
  quality loss is often invisible and the size win is real.
- **stats-mode diff**: biggest win specifically for screen recordings where most of the
  frame doesn't change (a whiteboard, a cursor moving over a static page).

## Fitting a size budget

Weight is always constrained — either the built-in ~7.8M default, or a budget you set
explicitly. Pass a byte size (`8M`, `500K`) or the path to a file whose size to match
(`--max-size reference.gif`) to `-m/--max-size`. If the encode comes out bigger, the
script re-encodes automatically: fps down (video only, floor 5), then width down (floor
160, or a `-R` reference's own width if one is active — see below), then colors down
(floor 32) — one step at a time, cheapest-looking cut first, up to 15 retries. It stops
and warns if it hits every floor and is still over budget; at that point the only lever
left is trimming the duration, which the script won't do on its own since it changes
*what's in the GIF*, not just how it's encoded.

This does **not** make the output resemble any reference file's look — it only caps the
weight. A photo-realistic source pushed through a tight `--max-size` will still look
like a heavily fps/width/color-starved version of itself, not like some other file's
content or style. For high-entropy footage (video/photos with real motion, gradients,
noise), even an untuned encode may already be near-optimal for its content —
auto-tuning then has to cut real quality to hit the budget, and the retry log makes
that trade-off visible rather than silent. Report the final `fps=/width=/colors=` line
to the user rather than just the size — that's the compromise they're actually getting.

## "Not worse than a reference" — `-R, --reference`

Despite the name, this is the weight/resolution tool, not the quality one — quality is
already covered by the defaults (see "Quality vs. weight" above) with no file needed.
`--reference FILE` bundles both floors into one flag: `-w FILE` (resolution — a floor,
enforced through auto-tune too) plus `--max-size FILE` (weight — a ceiling). Use it
instead of composing `-w`/`--max-size` by hand whenever the ask is "as good as X, not
heavier than X" rather than a specific number. `FILE` must be a real path on disk you
(or the user) name explicitly — the script never searches for or assumes one.

Because resolution is a hard floor when `-R` is active, a size budget that's simply
impossible at that resolution (very long/high-motion source, tight `--max-size`) will
end with a "still over budget" warning rather than silently shrinking below the
reference's resolution — see "Fitting a size budget" above. That's the intended
trade-off: the resolution promise wins over the weight one when they conflict.

## Known limitations

- Audio is always dropped (GIF has none).
- HEIC photos may fail to decode if ffmpeg wasn't built with `libheif`; convert first
  with macOS `sips -s format jpeg in.heic --out in.jpg`.
- `--crop auto` only catches uniform-color borders, not arbitrary UI chrome.
