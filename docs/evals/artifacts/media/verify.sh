#!/bin/sh
# Run at the repository root; FFMPEG_BIN may name the Apple Silicon binary.
set -eu
"${FFMPEG_BIN:-ffmpeg}" -hide_banner -nostats -nostdin -i docs/media/promo.mp4 \
    -vf 'freezedetect=n=-60dB:d=1.5' -af 'ebur128=peak=true:framelog=verbose' -f null -
