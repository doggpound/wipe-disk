#!/usr/bin/env bash
set -euo pipefail

BS="64M"
DD_DIRECT=0
LOG_DIR="./logs"
INTERVAL=1
DEVICES=()

# Defaults ON
VERIFY=1
SMART=1
REPORT=1
PDF=1
TEXTSHOT=1
PER_DEVICE_REPORT=1

VERIFY_SAMPLES=200
VERIFY_BLOCK_SIZE=4096

AUTO_PREP_VIDPID="152d:0562"

NO_WIPE=0
DRY_RUN_PROGRESS=0
DRY_RUN_SECONDS=30
DRY_RUN_SIZE_GB=64

REPORTS_ROOT="./reports"
RUN_DIR=""
ASSETS_DIR=""
REPORT_FILE=""
RUN_CAPTURE_FILE=""
RUN_CLEAN_FILE=""
RUN_WRAP_FILE=""
RUN_PNG_FILE=""
PDF_ENGINE="auto"
PRIMARY_SERIAL="unknown-serial"

CURRENT_DD_PID=""
INTERRUPTED=0
LAST_WRITTEN_BYTES=0

START_TS="$(date +%Y%m%d-%H%M%S)"
START_HUMAN="$(date -Is)"

usage() {
  cat <<EOF
Usage:
  $0 --devices /dev/sda,/dev/sdb [options]

Options:
  --no-wipe
  --dry-run-progress
  --dry-run-seconds N
  --dry-run-size-gb N
  --direct-io
  --no-direct-io
  --no-verify
  --no-smart
  --no-report
  --no-textshot
  --no-pdf
  --no-per-device-report
  --reports-root DIR
  --verify-samples N
  --verify-bs BYTES
  --bs SIZE
EOF
}

on_interrupt() {
  INTERRUPTED=1
  echo
  echo "INTERRUPT: stopping active wipe safely..."
  if [[ -n "${CURRENT_DD_PID:-}" ]]; then
    kill -INT "-${CURRENT_DD_PID}" 2>/dev/null || true
    kill -INT "${CURRENT_DD_PID}" 2>/dev/null || true
    sleep 0.2
    kill -TERM "-${CURRENT_DD_PID}" 2>/dev/null || true
    kill -TERM "${CURRENT_DD_PID}" 2>/dev/null || true
    sleep 0.2
    kill -KILL "-${CURRENT_DD_PID}" 2>/dev/null || true
    kill -KILL "${CURRENT_DD_PID}" 2>/dev/null || true
  fi
}
trap on_interrupt INT TERM

parse_devices_arg() {
  local raw="$1"
  IFS=',' read -r -a split <<< "$raw"
  for d in "${split[@]}"; do
    d="$(echo "$d" | xargs)"
    [[ -n "$d" ]] && DEVICES+=("$d")
  done
}

human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB",u," ");
    i=1; while (b>=1024 && i<6) {b/=1024;i++}
    printf "%.1f %s", b, u[i]
  }'
}

human_rate_mib() {
  local bps="${1:-0}"
  awk -v b="$bps" 'BEGIN{ printf "%.1f MiB/s", b/1048576 }'
}

human_eta() {
  local sec="${1:-0}"
  (( sec < 0 )) && sec=0
  awk -v s="$sec" 'BEGIN{
    h=int(s/3600); m=int((s%3600)/60); ss=int(s%60);
    if (h>0) printf "%dh %02dm %02ds",h,m,ss;
    else if (m>0) printf "%dm %02ds",m,ss;
    else printf "%ds",ss;
  }'
}

human_pct() {
  local bytes="$1" total="$2"
  if (( total <= 0 )); then
    echo "0.00"
  else
    awk -v b="$bytes" -v s="$total" 'BEGIN{ printf "%.2f", (b*100/s) }'
  fi
}

get_written_sectors() {
  local devname="$1"
  awk -v d="$devname" '$3==d {print $10}' /proc/diskstats 2>/dev/null || echo 0
}

sanitize_name() {
  local x="${1:-}"
  x="${x//\//_}"; x="${x// /_}"; x="${x//:/-}"
  echo "$x"
}

safe_serial_for_name() {
  local dev="$1" s
  s="$(lsblk -d -n -o SERIAL "$dev" 2>/dev/null | xargs || true)"
  [[ -z "$s" ]] && s="unknown-serial"
  s="$(echo "$s" | tr -cd '[:alnum:]._-')"
  [[ -z "$s" ]] && s="unknown-serial"
  echo "$s"
}

get_vidpid_for_dev() {
  local dev="$1" node sys v p
  node="$(lsblk -dno PKNAME "$dev" 2>/dev/null || true)"
  [[ -z "$node" ]] && node="$(basename "$dev")"
  sys="/sys/class/block/${node}/device"
  for _ in {1..10}; do
    if [[ -f "${sys}/idVendor" && -f "${sys}/idProduct" ]]; then
      v="$(tr 'A-F' 'a-f' < "${sys}/idVendor")"
      p="$(tr 'A-F' 'a-f' < "${sys}/idProduct")"
      echo "${v}:${p}"
      return 0
    fi
    sys="$(readlink -f "${sys}/.." 2>/dev/null || true)"
    [[ -z "$sys" ]] && break
  done
  echo "unknown"
}

strip_ansi_file() {
  local in="$1" out="$2"
  perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a]*(?:\a|\e\\)//g; s/\e//g;' "$in" \
    | tr -cd '\11\12\15\40-\176' \
    | sed 's/\r$//' > "$out"
}

wrap_clean_text() {
  local in="$1" out="$2"
  fold -s -w 180 "$in" > "$out"
}

render_textshot_png_robust() {
  local txt="$1" out_png="$2"
  local tmp_ps tmp_pdf tmp_dir
  tmp_ps="$(mktemp --suffix=.ps)"
  tmp_pdf="$(mktemp --suffix=.pdf)"
  tmp_dir="$(mktemp -d)"

  if ! enscript -B -q -f "Courier10" -p "$tmp_ps" "$txt" 2>/tmp/enscript.err; then
    echo "TEXTSHOT: enscript failed"
    sed -n '1,120p' /tmp/enscript.err || true
    rm -f "$tmp_ps" "$tmp_pdf"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! ps2pdf "$tmp_ps" "$tmp_pdf" 2>/tmp/ps2pdf.err; then
    echo "TEXTSHOT: ps2pdf failed"
    sed -n '1,120p' /tmp/ps2pdf.err || true
    rm -f "$tmp_ps" "$tmp_pdf"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! pdftoppm -png "$tmp_pdf" "${tmp_dir}/page" 2>/tmp/pdftoppm.err; then
    echo "TEXTSHOT: pdftoppm failed"
    sed -n '1,120p' /tmp/pdftoppm.err || true
    rm -f "$tmp_ps" "$tmp_pdf"
    rm -rf "$tmp_dir"
    return 1
  fi

  shopt -s nullglob
  local pages=( "${tmp_dir}"/page-*.png )
  shopt -u nullglob
  if [[ ${#pages[@]} -eq 0 ]]; then
    echo "TEXTSHOT: no png pages produced"
    rm -f "$tmp_ps" "$tmp_pdf"
    rm -rf "$tmp_dir"
    return 1
  fi

  if command -v convert >/dev/null 2>&1; then
    for p in "${pages[@]}"; do
      convert "$p" \
        -fuzz 2% -trim +repage \
        -background "#111111" -alpha remove -alpha off \
        -bordercolor "#111111" -border 12 \
        "$p" 2>/tmp/convert.err || true
    done
    if ! convert "${pages[@]}" -append "$out_png" 2>/tmp/convert.err; then
      echo "TEXTSHOT: stitch failed"
      sed -n '1,120p' /tmp/convert.err || true
      cp "${pages[0]}" "$out_png"
    fi
  else
    cp "${pages[0]}" "$out_png"
  fi

  rm -f "$tmp_ps" "$tmp_pdf" /tmp/enscript.err /tmp/ps2pdf.err /tmp/pdftoppm.err /tmp/convert.err
  rm -rf "$tmp_dir"
  return 0
}

run_prewipe_steps() {
  local dev="$1" log="$2"
  echo "      -> sudo wipefs -a $dev" | tee -a "$log"
  sudo wipefs -a "$dev" >>"$log" 2>&1 || true
  echo "      -> sudo mdadm --zero-superblock $dev || true" | tee -a "$log"
  sudo mdadm --zero-superblock "$dev" >>"$log" 2>&1 || true
  echo "      -> sudo sgdisk --zap-all $dev || true" | tee -a "$log"
  sudo sgdisk --zap-all "$dev" >>"$log" 2>&1 || true
  echo "      -> sudo partprobe $dev || true" | tee -a "$log"
  sudo partprobe "$dev" >>"$log" 2>&1 || true
}

smart_try_modes() {
  local dev="$1" mode
  for mode in "" "-d sat" "-d sat,12" "-d scsi"; do
    if sudo smartctl ${mode} -a "$dev" >/dev/null 2>&1; then
      echo "$mode"
      return 0
    fi
  done
  return 1
}

capture_smart_for_device() {
  local dev="$1" when="$2" perlog="$3" outdir="$4"
  local db out mode
  db="$(sanitize_name "$(basename "$dev")")"
  out="${outdir}/smart-${db}-${when}.txt"
  {
    echo "=== SMART ${when^^} capture for ${dev} @ $(date -Is) ==="
    if mode="$(smart_try_modes "$dev")"; then
      echo "SMART mode: ${mode:-default}"
      if [[ -n "$mode" ]]; then
        sudo smartctl $mode -H -a "$dev" || true
      else
        sudo smartctl -H -a "$dev" || true
      fi
    else
      echo "Unable to read SMART"
    fi
  } >"$out" 2>&1 || true
  echo "SMART ${when}: ${out}" >> "$perlog"
}

get_smart_serial_from_file() {
  local smart_file="$1"
  if [[ -f "$smart_file" ]]; then
    grep -m1 '^Serial number:' "$smart_file" | sed 's/^Serial number:[[:space:]]*//' || true
  fi
}

draw_progress_table() {
  local dev="$1" bytes="$2" total_bytes="$3" speed_bps="$4" eta_s="$5" state="$6"
  local model serial vidpid pct

  model="${DEV_MODEL[$dev]:-unknown}"
  serial="${DEV_SERIAL[$dev]:-unknown}"
  vidpid="${DEV_VIDPID[$dev]:-unknown}"
  pct="$(human_pct "$bytes" "$total_bytes")"

  printf "\033[H\033[2J"
  echo "Parallel Disk Wipe Dashboard  |  $(date)"
  echo "Refresh: ${INTERVAL}s   BS: ${BS}   Logs: ${LOG_DIR}"
  echo "I/O mode: $([[ "$DD_DIRECT" -eq 1 ]] && echo direct-io || echo buffered-io)"
  echo
  printf "%-10s %-16s %-14s %-9s %7s %12s %12s %10s %10s\n" "DEVICE" "MODEL" "SERIAL" "VID:PID" "DONE%" "WRITTEN" "SPEED" "ETA" "STATE"
  printf "%-10s %-16s %-14s %-9s %7s %12s %12s %10s %10s\n" "------" "-----" "------" "-------" "-----" "-------" "-----" "---" "-----"
  printf "%-10s %-16.16s %-14.14s %-9.9s %6s%% %12s %12s %10s %10s\n" \
    "$dev" "$model" "$serial" "$vidpid" "$pct" "$(human_bytes "$bytes")" "$(human_bytes "$speed_bps")/s" "$(human_eta "$eta_s")" "$state"
  echo
  echo "Ctrl+C will stop ALL running wipes."
}

# Stable progress with low overhead: diskstats delta + dd status=none
pretty_progress_dd() {
  local dev="$1" total_bytes="$2" log="$3"
  local dd_pid dd_rc start_ts now elapsed bytes
  local dd_oflag
  local devname base_sect prev_sect cur_sect
  local last_ts dt inst_delta_sect inst_bps
  local rem eta_s

  if [[ "$DD_DIRECT" -eq 1 ]]; then
    dd_oflag="oflag=direct"
  else
    dd_oflag=""
  fi

  devname="$(basename "$dev")"
  base_sect="$(get_written_sectors "$devname")"
  [[ -z "$base_sect" ]] && base_sect=0
  prev_sect="$base_sect"

  set +e
  setsid sudo dd if=/dev/zero of="$dev" bs="$BS" $dd_oflag status=none >>"$log" 2>&1 &
  dd_pid=$!
  set -e

  CURRENT_DD_PID="$dd_pid"
  start_ts=$(date +%s)
  last_ts="$start_ts"
  inst_bps=0

  echo "dd mode: bs=${BS} ${dd_oflag:-buffered-io} status=none" >> "$log"

  while kill -0 "$dd_pid" 2>/dev/null; do
    sleep 1

    cur_sect="$(get_written_sectors "$devname")"
    [[ -z "$cur_sect" ]] && cur_sect="$prev_sect"
    (( cur_sect < prev_sect )) && cur_sect="$prev_sect"

    bytes=$(( (cur_sect - base_sect) * 512 ))
    (( bytes < 0 )) && bytes=0
    (( bytes > total_bytes )) && bytes="$total_bytes"

    now=$(date +%s)
    elapsed=$(( now - start_ts ))

    dt=$(( now - last_ts ))
    (( dt <= 0 )) && dt=1
    inst_delta_sect=$(( cur_sect - prev_sect ))
    (( inst_delta_sect < 0 )) && inst_delta_sect=0
    inst_bps=$(( (inst_delta_sect * 512) / dt ))

    rem=$(( total_bytes - bytes ))
    (( rem < 0 )) && rem=0
    if (( inst_bps > 0 )); then
      eta_s=$(( rem / inst_bps ))
    else
      eta_s=0
    fi

    draw_progress_table "$dev" "$bytes" "$total_bytes" "$inst_bps" "$eta_s" "RUNNING"

    prev_sect="$cur_sect"
    last_ts="$now"

    if [[ "$INTERRUPTED" -eq 1 ]]; then
      break
    fi
  done

  set +e
  wait "$dd_pid"
  dd_rc=$?
  set -e

  cur_sect="$(get_written_sectors "$devname")"
  [[ -z "$cur_sect" ]] && cur_sect="$prev_sect"
  LAST_WRITTEN_BYTES=$(( (cur_sect - base_sect) * 512 ))
  (( LAST_WRITTEN_BYTES < 0 )) && LAST_WRITTEN_BYTES=0
  (( LAST_WRITTEN_BYTES > total_bytes )) && LAST_WRITTEN_BYTES="$total_bytes"

  CURRENT_DD_PID=""
  draw_progress_table "$dev" "$LAST_WRITTEN_BYTES" "$total_bytes" "$inst_bps" 0 "DONE"
  printf "\n"
  return "$dd_rc"
}

pretty_progress_simulated() {
  local label="$1" total_bytes="$2" duration_sec="$3" log="$4"
  local start now elapsed bytes rem eta_s
  local jitter
  local speed_bps

  start=$(date +%s)
  echo "DRY-RUN: simulated wipe started for ${label} (size=$(human_bytes "$total_bytes"), duration=${duration_sec}s)" >> "$log"

  while :; do
    now=$(date +%s)
    elapsed=$(( now - start ))
    (( elapsed > duration_sec )) && elapsed=$duration_sec

    jitter=$(( RANDOM % 5000000 ))
    bytes=$(( (total_bytes * elapsed / duration_sec) + jitter ))
    (( bytes > total_bytes )) && bytes=$total_bytes

    if (( elapsed > 0 )); then
      speed_bps=$(( bytes / elapsed ))
    else
      speed_bps=0
    fi
    rem=$(( total_bytes - bytes ))
    (( rem < 0 )) && rem=0
    if (( speed_bps > 0 )); then
      eta_s=$(( rem / speed_bps ))
    else
      eta_s=0
    fi

    draw_progress_table "$label" "$bytes" "$total_bytes" "$speed_bps" "$eta_s" "RUNNING"
    echo "$bytes bytes (simulated progress)" >> "$log"

    (( elapsed >= duration_sec )) && break
    sleep 1

    if [[ "$INTERRUPTED" -eq 1 ]]; then
      break
    fi
  done

  LAST_WRITTEN_BYTES="$bytes"
  draw_progress_table "$label" "$LAST_WRITTEN_BYTES" "$total_bytes" "$speed_bps" 0 "DONE"
  printf "\n"

  if [[ "$INTERRUPTED" -eq 1 ]]; then
    return 130
  fi
  return 0
}

verify_device_samples() {
  local dev="$1" size="$2" log="$3" samples="$4" block_size="$5"
  local blocks max_block i skip hex

  blocks=$(( size / block_size ))
  (( blocks <= 1 )) && return 1
  max_block=$(( blocks - 1 ))

  echo "VERIFY: starting sampled verification ($(date))" | tee -a "$log"
  for (( i=1; i<=samples; i++ )); do
    skip=$(( RANDOM % max_block ))
    hex="$(sudo dd if="$dev" bs="$block_size" skip="$skip" count=1 iflag=direct status=none 2>/dev/null | od -An -tx1 -v | tr -d ' \n')"
    [[ -z "$hex" ]] && return 1
    echo "$hex" | grep -q '[^0]' && return 1
    (( i % 25 == 0 || i == samples )) && echo "VERIFY: progress $i/$samples" | tee -a "$log"
  done
  echo "VERIFY: PASS all sampled blocks are zero ($(date))" | tee -a "$log"
  return 0
}

detect_pdf_engine() {
  local forced="${1:-auto}"
  [[ "$forced" != "auto" ]] && { echo "$forced"; return; }
  command -v xelatex >/dev/null 2>&1 && { echo "xelatex"; return; }
  command -v pdflatex >/dev/null 2>&1 && { echo "pdflatex"; return; }
  echo "none"
}

append_smart_embed_for_dev() {
  local dev="$1" assets="$2"
  local db pre post

  db="$(sanitize_name "$(basename "$dev")")"
  pre="${assets}/smart-${db}-pre.txt"
  post="${assets}/smart-${db}-post.txt"

  [[ -f "$pre" ]] && {
    echo "### SMART PRE (${dev})"
    echo
    echo '```text'
    sed -n '1,120p' "$pre"
    echo '```'
    echo
  }
  [[ -f "$post" ]] && {
    echo "### SMART POST (${dev})"
    echo
    echo '```text'
    sed -n '1,120p' "$post"
    echo '```'
    echo
  }

  return 0
}

generate_markdown_report() {
  local out="$1" clean_txt="$2" png="$3" pdf="$4" assets="$5"
  {
    echo "# Disk Wipe Report"
    echo
    echo "- **Start:** ${START_HUMAN}"
    echo "- **End:** $(date -Is)"
    echo
    echo "## Device Summary"
    echo
    echo "| Device | Model | Host Serial (lsblk) | SMART Serial | VID:PID | Size | Written | State | Reason | Log |"
    echo "|---|---|---|---|---|---:|---:|---|---|---|"
    for d in "${DEVICES[@]}"; do
      local db smart_pre smart_serial
      db="$(sanitize_name "$(basename "$d")")"
      smart_pre="${assets}/smart-${db}-pre.txt"
      smart_serial="$(get_smart_serial_from_file "$smart_pre")"
      [[ -z "${smart_serial:-}" ]] && smart_serial="n/a"
      echo "| $d | ${DEV_MODEL[$d]//|/\\|} | ${DEV_SERIAL[$d]//|/\\|} | ${smart_serial//|/\\|} | ${DEV_VIDPID[$d]} | $(human_bytes "${DEV_SIZE[$d]}") | $(human_bytes "${DEV_WRITTEN_BYTES[$d]}") | ${DEV_STATE[$d]} | ${DEV_REASON[$d]//|/\\|} | ${DEV_LOG[$d]} |"
    done
    echo
    echo "## Screenshot Evidence"
    echo
    if [[ -f "$png" ]]; then
      echo "![Console Evidence](assets/$(basename "$png"))"
      echo
      echo "[Open screenshot directly](assets/$(basename "$png"))"
    else
      echo "_Screenshot unavailable (expected at: assets/$(basename "$png"))_"
    fi
    echo
    echo "## Console (sanitized excerpt)"
    echo
    echo '```text'
    tail -n 240 "$clean_txt"
    echo '```'
    echo
    echo "## SMART excerpts"
    echo
    echo "> Note: On some USB/SATA bridge adapters, SMART serial may differ from host-reported lsblk serial. This is expected when the bridge exposes its own enclosure/controller identifier."
    echo
    for d in "${DEVICES[@]}"; do
      append_smart_embed_for_dev "$d" "$assets"
    done
    [[ -n "$pdf" ]] && {
      echo "## PDF"
      echo
      printf -- "- \`%s\`\n" "$pdf"
    }

    echo "## Self-test checklist"
    echo
    echo "- [ ] Progress UI showed continuous percent, bytes, speed, ETA"
    echo "- [ ] Ctrl+C stopped active wipe immediately and script exited with code 130"
    echo "- [ ] Report table includes Host Serial and SMART Serial"
    echo "- [ ] Screenshot link uses assets/<png-name> and opens correctly"
    echo "- [ ] Long console screenshot is trimmed and stitched"
  } > "$out"
}

generate_per_device_report() {
  local d="$1" out="$2" out_pdf="$3" clean_txt="$4" png="$5" assets="$6"
  local db smart_pre smart_serial

  db="$(sanitize_name "$(basename "$d")")"
  smart_pre="${assets}/smart-${db}-pre.txt"
  smart_serial="$(get_smart_serial_from_file "$smart_pre")"
  [[ -z "${smart_serial:-}" ]] && smart_serial="n/a"

  {
    echo "# Disk Wipe Report - $d"
    echo
    echo "| Device | Model | Host Serial (lsblk) | SMART Serial | VID:PID | Size | Written | State | Reason | Log |"
    echo "|---|---|---|---|---|---:|---:|---|---|---|"
    echo "| $d | ${DEV_MODEL[$d]//|/\\|} | ${DEV_SERIAL[$d]//|/\\|} | ${smart_serial//|/\\|} | ${DEV_VIDPID[$d]} | $(human_bytes "${DEV_SIZE[$d]}") | $(human_bytes "${DEV_WRITTEN_BYTES[$d]}") | ${DEV_STATE[$d]} | ${DEV_REASON[$d]//|/\\|} | ${DEV_LOG[$d]} |"
    echo
    echo "## Screenshot Evidence"
    echo
    if [[ -f "$png" ]]; then
      echo "![Console Evidence](assets/$(basename "$png"))"
      echo
      echo "[Open screenshot directly](assets/$(basename "$png"))"
    else
      echo "_Screenshot unavailable (expected at: assets/$(basename "$png"))_"
    fi
    echo
    echo "> Note: On some USB/SATA bridge adapters, SMART serial may differ from host-reported lsblk serial. This is expected when the bridge exposes its own enclosure/controller identifier."
    echo
    append_smart_embed_for_dev "$d" "$assets"

    echo "## Console (sanitized excerpt)"
    echo
    echo '```text'
    tail -n 120 "$clean_txt"
    echo '```'
  } > "$out"

  if [[ "$PDF" -eq 1 && -n "$out_pdf" && -s "$out" ]] && command -v pandoc >/dev/null 2>&1; then
    local engine
    engine="$(detect_pdf_engine "$PDF_ENGINE")"
    [[ "$engine" != "none" ]] && pandoc "$out" -o "$out_pdf" --pdf-engine="$engine" || true
  fi
}

# Parse args
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        parse_devices_arg "$1"
        shift
      done
      ;;
    --no-wipe) NO_WIPE=1; shift ;;
    --dry-run-progress) DRY_RUN_PROGRESS=1; NO_WIPE=1; VERIFY=0; SMART=0; shift ;;
    --dry-run-seconds) DRY_RUN_SECONDS="${2:-30}"; shift 2 ;;
    --dry-run-size-gb) DRY_RUN_SIZE_GB="${2:-64}"; shift 2 ;;
    --direct-io) DD_DIRECT=1; shift ;;
    --no-direct-io) DD_DIRECT=0; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --no-smart) SMART=0; shift ;;
    --no-report) REPORT=0; shift ;;
    --no-textshot) TEXTSHOT=0; shift ;;
    --no-pdf) PDF=0; shift ;;
    --no-per-device-report) PER_DEVICE_REPORT=0; shift ;;
    --reports-root) REPORTS_ROOT="${2:-./reports}"; shift 2 ;;
    --verify-samples) VERIFY_SAMPLES="${2:-200}"; shift 2 ;;
    --verify-bs) VERIFY_BLOCK_SIZE="${2:-4096}"; shift 2 ;;
    --bs) BS="${2:-64M}"; shift 2 ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ ${#DEVICES[@]} -eq 0 ]]; then
  if [[ "$DRY_RUN_PROGRESS" -eq 1 ]]; then
    DEVICES=("/dev/dry-run0")
  else
    echo "No devices provided."
    exit 1
  fi
fi

PRIMARY_SERIAL="$(safe_serial_for_name "${DEVICES[0]}")"

for cmd in lsblk blockdev awk grep od tr sed perl fold enscript ps2pdf pdftoppm smartctl pandoc wipefs mdadm sgdisk partprobe dd; do
  command -v "$cmd" >/dev/null 2>&1 || echo "WARN: missing $cmd"
done

if [[ "$TEXTSHOT" -eq 1 ]]; then
  for c in enscript ps2pdf pdftoppm; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: screenshot requires '$c'"; exit 2; }
  done
fi

if [[ "$DRY_RUN_PROGRESS" -eq 0 ]]; then
  sudo -v
fi

mkdir -p "$LOG_DIR" "$REPORTS_ROOT"
RUN_DIR="${REPORTS_ROOT}/${START_TS}"
ASSETS_DIR="${RUN_DIR}/assets"
mkdir -p "$RUN_DIR" "$ASSETS_DIR"

REPORT_FILE="${RUN_DIR}/${PRIMARY_SERIAL}-report-${START_TS}.md"
RUN_CAPTURE_FILE="${ASSETS_DIR}/${PRIMARY_SERIAL}-run-${START_TS}.raw.txt"
RUN_CLEAN_FILE="${ASSETS_DIR}/${PRIMARY_SERIAL}-run-${START_TS}.clean.txt"
RUN_WRAP_FILE="${ASSETS_DIR}/${PRIMARY_SERIAL}-run-${START_TS}.wrap.txt"
RUN_PNG_FILE="${ASSETS_DIR}/${PRIMARY_SERIAL}-run-${START_TS}.png"

echo "Reports folder: $RUN_DIR"
if [[ "$DRY_RUN_PROGRESS" -eq 1 ]]; then
  echo "DRY-RUN mode active: no disks will be wiped."
elif [[ "$NO_WIPE" -eq 1 ]]; then
  read -r -p "Type AUDIT-ONLY to continue (no wipe): " CONFIRM
  [[ "$CONFIRM" == "AUDIT-ONLY" ]] || exit 1
else
  read -r -p "Type WIPE-ALL to continue: " CONFIRM
  [[ "$CONFIRM" == "WIPE-ALL" ]] || exit 1
fi

exec > >(tee -a "$RUN_CAPTURE_FILE") 2>&1

declare -A DEV_SIZE DEV_LOG DEV_MODEL DEV_SERIAL DEV_VIDPID DEV_STATE DEV_REASON DEV_WRITTEN_BYTES

for d in "${DEVICES[@]}"; do
  devname="$(basename "$d")"
  log="${LOG_DIR}/wipe-${START_TS}-${devname}.log"
  DEV_LOG["$d"]="$log"

  DEV_MODEL["$d"]="$(lsblk -d -n -o MODEL "$d" 2>/dev/null | xargs || true)"
  DEV_SERIAL["$d"]="$(lsblk -d -n -o SERIAL "$d" 2>/dev/null | xargs || true)"
  DEV_VIDPID["$d"]="$(get_vidpid_for_dev "$d")"

  if [[ "$DRY_RUN_PROGRESS" -eq 1 ]]; then
    DEV_SIZE["$d"]=$(( DRY_RUN_SIZE_GB * 1024 * 1024 * 1024 ))
    [[ -z "${DEV_SERIAL[$d]}" ]] && DEV_SERIAL["$d"]="dry-run-serial"
    [[ -z "${DEV_MODEL[$d]}" ]] && DEV_MODEL["$d"]="DryRun Device"
  else
    DEV_SIZE["$d"]="$(sudo blockdev --getsize64 "$d" 2>/dev/null || echo 0)"
  fi

  DEV_WRITTEN_BYTES["$d"]=0

  echo "[$d] model=${DEV_MODEL[$d]} serial=${DEV_SERIAL[$d]} vidpid=${DEV_VIDPID[$d]} size=$(human_bytes "${DEV_SIZE[$d]}")"

  if [[ "$DRY_RUN_PROGRESS" -eq 0 && "${DEV_VIDPID[$d]}" == "$AUTO_PREP_VIDPID" ]]; then
    run_prewipe_steps "$d" "$log"
    DEV_SIZE["$d"]="$(sudo blockdev --getsize64 "$d" 2>/dev/null || echo 0)"
  fi

  if [[ "$SMART" -eq 1 && "$DRY_RUN_PROGRESS" -eq 0 ]]; then
    capture_smart_for_device "$d" "pre" "$log" "$ASSETS_DIR"
  fi

  if [[ "$DRY_RUN_PROGRESS" -eq 1 ]]; then
    echo "Simulating wipe UI for $d ..."
    set +e
    pretty_progress_simulated "$d" "${DEV_SIZE[$d]}" "$DRY_RUN_SECONDS" "$log"
    sim_rc=$?
    set -e

    DEV_WRITTEN_BYTES["$d"]="$LAST_WRITTEN_BYTES"
    if [[ "$INTERRUPTED" -eq 1 || "$sim_rc" -eq 130 ]]; then
      DEV_STATE["$d"]="FAILED"
      DEV_REASON["$d"]="Interrupted by user"
      break
    fi

    DEV_STATE["$d"]="SUCCESS"
    DEV_REASON["$d"]="Dry-run progress simulation completed"
    continue
  fi

  if [[ "$NO_WIPE" -eq 1 ]]; then
    DEV_STATE["$d"]="SKIPPED"
    DEV_REASON["$d"]="--no-wipe set"
    continue
  fi

  echo "Wiping $d ..."
  set +e
  pretty_progress_dd "$d" "${DEV_SIZE[$d]}" "$log"
  dd_rc=$?
  set -e

  DEV_WRITTEN_BYTES["$d"]="$LAST_WRITTEN_BYTES"

  if [[ "$INTERRUPTED" -eq 1 ]]; then
    DEV_STATE["$d"]="FAILED"
    DEV_REASON["$d"]="Interrupted by user"
    break
  fi

  if [[ "$dd_rc" -eq 0 ]]; then
    DEV_STATE["$d"]="SUCCESS"
    DEV_REASON["$d"]="dd completed"
    [[ "${DEV_WRITTEN_BYTES[$d]}" -eq 0 ]] && DEV_WRITTEN_BYTES["$d"]="${DEV_SIZE[$d]}"
  else
    if grep -q "No space left on device" "$log"; then
      DEV_STATE["$d"]="SUCCESS"
      DEV_REASON["$d"]="Reached end-of-device (expected)"
      DEV_WRITTEN_BYTES["$d"]="${DEV_SIZE[$d]}"
    elif [[ "$dd_rc" -eq 130 ]]; then
      DEV_STATE["$d"]="FAILED"
      DEV_REASON["$d"]="Interrupted by user"
    else
      DEV_STATE["$d"]="FAILED"
      DEV_REASON["$d"]="dd failed (rc=$dd_rc)"
    fi
  fi

  if [[ "$SMART" -eq 1 ]]; then
    capture_smart_for_device "$d" "post" "$log" "$ASSETS_DIR"
  fi
done

if [[ "$INTERRUPTED" -eq 0 && "$VERIFY" -eq 1 && "$DRY_RUN_PROGRESS" -eq 0 ]]; then
  echo "Starting sampled verification..."
  for d in "${DEVICES[@]}"; do
    if [[ "${DEV_STATE[$d]:-}" == "SUCCESS" || "${DEV_STATE[$d]:-}" == "SKIPPED" ]]; then
      if verify_device_samples "$d" "${DEV_SIZE[$d]}" "${DEV_LOG[$d]}" "$VERIFY_SAMPLES" "$VERIFY_BLOCK_SIZE"; then
        DEV_REASON["$d"]="${DEV_REASON[$d]}; verify PASS"
        [[ "${DEV_STATE[$d]}" == "SKIPPED" ]] && DEV_STATE["$d"]="AUDIT-PASS"
      else
        DEV_STATE["$d"]="FAILED"
        DEV_REASON["$d"]="${DEV_REASON[$d]}; verify FAILED"
      fi
    fi
  done
fi

strip_ansi_file "$RUN_CAPTURE_FILE" "$RUN_CLEAN_FILE"
wrap_clean_text "$RUN_CLEAN_FILE" "$RUN_WRAP_FILE"

if [[ "$TEXTSHOT" -eq 1 ]]; then
  if render_textshot_png_robust "$RUN_WRAP_FILE" "$RUN_PNG_FILE"; then
    echo "TEXTSHOT: created $RUN_PNG_FILE"
  else
    echo "TEXTSHOT: failed to create screenshot PNG"
  fi
fi

if [[ "$REPORT" -eq 1 ]]; then
  PDF_OUT="${RUN_DIR}/${PRIMARY_SERIAL}-report-${START_TS}.pdf"
  generate_markdown_report "$REPORT_FILE" "$RUN_CLEAN_FILE" "$RUN_PNG_FILE" "$PDF_OUT" "$ASSETS_DIR"
  echo "REPORT: markdown created at $REPORT_FILE"

  if [[ "$PDF" -eq 1 ]] && command -v pandoc >/dev/null 2>&1; then
    ENGINE="$(detect_pdf_engine "$PDF_ENGINE")"
    if [[ "$ENGINE" != "none" ]]; then
      pandoc "$REPORT_FILE" -o "$PDF_OUT" --pdf-engine="$ENGINE" && echo "REPORT: PDF created at $PDF_OUT"
    fi
  fi

  if [[ "$PER_DEVICE_REPORT" -eq 1 ]]; then
    for d in "${DEVICES[@]}"; do
      dev_serial="$(safe_serial_for_name "$d")"
      dev_tag="$(sanitize_name "$(basename "$d")")"
      per_md="${RUN_DIR}/${dev_serial}-per-device-${dev_tag}-report-${START_TS}.md"
      per_pdf="${RUN_DIR}/${dev_serial}-per-device-${dev_tag}-report-${START_TS}.pdf"
      generate_per_device_report "$d" "$per_md" "$per_pdf" "$RUN_CLEAN_FILE" "$RUN_PNG_FILE" "$ASSETS_DIR"
      echo "REPORT: per-device markdown created at $per_md"
      [[ -f "$per_pdf" ]] && echo "REPORT: per-device PDF created at $per_pdf"
    done
  fi
fi

echo "Done. Reports in: $RUN_DIR"
echo ""
echo "Self-test checklist:"
echo "[ ] Progress UI showed continuous percent, bytes, speed, ETA"
echo "[ ] Ctrl+C stopped active wipe and exit code was 130"
echo "[ ] Host Serial + SMART Serial appear in report table"
echo "[ ] Screenshot markdown path is assets/<png-name>"
echo "[ ] Stitched PNG exists and opens"

if [[ "$INTERRUPTED" -eq 1 ]]; then
  exit 130
fi

fail=0
for d in "${DEVICES[@]}"; do
  [[ "${DEV_STATE[$d]:-}" == "FAILED" ]] && fail=1
done
exit "$fail"
