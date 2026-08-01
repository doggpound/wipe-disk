# wipe-disk

> [!WARNING]  
> This is a script fully generated from AI. Use at your own risk.

Disk wipe utility for USB/SATA devices with:

- Live table-style progress dashboard
- Safe interrupt handling (`Ctrl+C` exits with code `130`)
- Optional SMART pre/post capture
- Sampled post-wipe verification
- Markdown/PDF report generation
- Console screenshot evidence pipeline (text -> ps -> pdf -> png, trimmed + stitched)

## Warning

This script permanently destroys data on the selected devices.

Always verify targets first:

```bash
lsblk -d -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN
```

## Requirements

Physical Connection:
- Plugged into motherboard/HBA
- USB plug in

> [!INFORMATION]
> For my testing of SATA and SAS drives, I used external USB options.
> For SAS, I used "chenyang USB 3.0 to SAS Adapter for 2.5/3.5" SFF-8482 SAS" (with power)

Minimum runtime tools:

- `bash`, `sudo`, `lsblk`, `dd`, `blockdev`, `awk`, `grep`, `sed`, `tr`, `od`, `perl`, `fold`
- Wipe prep helpers: `wipefs`, `mdadm`, `sgdisk`, `partprobe`
- SMART: `smartctl` (optional but enabled by default)

For screenshot evidence:

- `enscript`, `ps2pdf`, `pdftoppm`
- `convert` (ImageMagick, optional but recommended for trim/stitch)

For PDF report output:

- `pandoc`
- `xelatex` or `pdflatex`

## Make Executable

```bash
chmod +x wipe-disk.sh
```

## Basic Usage

```bash
./wipe-disk.sh --devices /dev/sdX
```

Multiple devices:

```bash
./wipe-disk.sh --devices /dev/sdb,/dev/sdc
```

or:

```bash
./wipe-disk.sh --devices /dev/sdb /dev/sdc
```

The script will ask for confirmation (`WIPE-ALL`) before wiping.

## Recommended Workflow

1. Identify target disks with `lsblk`.
2. Run dry-run progress mode to validate UI/report pipeline.
3. Execute real wipe on one device.
4. Validate report and screenshot artifacts.

## Dry Run Progress Mode

Simulates progress UI without writing to disks:

```bash
./wipe-disk.sh --dry-run-progress --dry-run-seconds 10 --devices /dev/dry-run0
```

Tune simulated size:

```bash
./wipe-disk.sh --dry-run-progress --dry-run-size-gb 128 --devices /dev/dry-run0
```

## Performance Modes

Default mode is buffered I/O (generally faster on many USB bridges).

- Buffered (default): no flag needed
- Direct I/O (stricter, sometimes slower):

```bash
./wipe-disk.sh --devices /dev/sdX --direct-io
```

Force buffered explicitly:

```bash
./wipe-disk.sh --devices /dev/sdX --no-direct-io
```

Change write block size:

```bash
./wipe-disk.sh --devices /dev/sdX --bs 128M
```

## Verification

Verification is enabled by default (sampled random block checks for zeroes).

Tune sample count and sample size:

```bash
./wipe-disk.sh --devices /dev/sdX --verify-samples 400 --verify-bs 4096
```

Disable verification:

```bash
./wipe-disk.sh --devices /dev/sdX --no-verify
```

## Report and Artifact Options

Disable/report controls:

```bash
./wipe-disk.sh --devices /dev/sdX --no-report
./wipe-disk.sh --devices /dev/sdX --no-textshot
./wipe-disk.sh --devices /dev/sdX --no-pdf
./wipe-disk.sh --devices /dev/sdX --no-per-device-report
```

Change report root folder:

```bash
./wipe-disk.sh --devices /dev/sdX --reports-root ./reports
```

No-write audit flow (collect metadata/report without wipe):

```bash
./wipe-disk.sh --devices /dev/sdX --no-wipe
```

## Interrupt / Cancel Behavior

- Press `Ctrl+C` during wipe to stop active wipe safely.
- Script exits with code `130` on interrupt.

## Output Structure

Each run creates a timestamped folder:

```text
reports/<timestamp>/
	<primary-serial>-report-<timestamp>.md
	<primary-serial>-report-<timestamp>.pdf           (if PDF enabled)
	<device-serial>-per-device-<dev>-report-<timestamp>.md
	assets/
		<primary-serial>-run-<timestamp>.raw.txt
		<primary-serial>-run-<timestamp>.clean.txt
		<primary-serial>-run-<timestamp>.wrap.txt
		<primary-serial>-run-<timestamp>.png
		smart-<dev>-pre.txt
		smart-<dev>-post.txt
```

Notes:

- Report screenshot link is always relative to report location: `assets/<png-name>`.
- Report table includes both serials:
	- Host Serial (`lsblk`)
	- SMART Serial (from SMART PRE capture, fallback `n/a`)
- USB/SATA bridge serial mismatches are documented in report notes.

## Example Commands

Dry-run validation:

```bash
./wipe-disk.sh --dry-run-progress --dry-run-seconds 8 --devices /dev/dry-run0
```

Real wipe (single device, default settings):

```bash
./wipe-disk.sh --devices /dev/sdb
```

Real wipe with faster tuning trial:

```bash
./wipe-disk.sh --devices /dev/sdb --bs 128M --no-direct-io
```

Cancel test (manual):

1. Start a real wipe.
2. Press `Ctrl+C` during active writing.
3. Confirm script exits with code `130`.

## Troubleshooting

- Throughput much lower than expected:
	- Try `--no-direct-io` (or avoid `--direct-io`)
	- Try `--bs 128M`
	- Check USB link/port/cable/enclosure quality
- SMART read missing:
	- Some bridges do not fully pass SMART
	- Report will show SMART serial as `n/a`
- Screenshot generation fails:
	- Install `enscript`, `ps2pdf`, `pdftoppm`
	- Install ImageMagick (`convert`) for best trim/stitch output