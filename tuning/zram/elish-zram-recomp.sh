#!/bin/sh
set -eu
Z=/sys/block/zram0
[ -w "$Z/recompress" ] || exit 0
[ -r "$Z/recomp_algorithm" ] || exit 0
grep -q '\[zstd\]' "$Z/recomp_algorithm" || exit 0

orig_bytes=$(awk '{print $1}' "$Z/mm_stat" 2>/dev/null || echo 0)
if [ "${orig_bytes:-0}" -gt 0 ]; then
  # Recompress pages that remained untouched since the previous cycle + incompressible huge pages
  echo "type=idle threshold=1024" > "$Z/recompress" 2>/dev/null || true
  echo "type=huge" > "$Z/recompress" 2>/dev/null || true
  # Mark current pages as idle candidates for the next cycle
  echo all > "$Z/idle" 2>/dev/null || true
fi
