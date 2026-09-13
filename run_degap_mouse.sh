#!/bin/bash
#
# DEGAP v2 pipeline for mouse genome gap filling: AutoGapfiller (internal
# N-gaps) followed by TelSeeker (chromosome-end telomere extension).
#
# This runs as a plain script (no job scheduler / SLURM / PBS directives) --
# submit it on the HPC the same way you'd run any local script, e.g.:
#   nohup bash run_degap_mouse.sh > degap_run.log 2>&1 &
# or inside a persistent tmux/screen session, since a whole-genome run can
# take many hours.
#
# TelSeeker needs a manually-reviewed list of chromosome ends to target
# (this is DEGAP's own documented workflow, not something safe to automate
# blindly). So this script runs in two passes:
#   Pass 1 (TARGET_ENDS_FILE left empty below): runs AutoGapfiller, then
#     TelSeekerCheck to produce motif plots, then stops with instructions.
#   Pass 2 (after you've reviewed the plots and filled in TARGET_ENDS_FILE
#     below): re-run this script and it will skip straight to TelSeeker.

set -e

# ---------------------------------------------------------------------------
# Configuration -- edit these for your run
# ---------------------------------------------------------------------------

# Path to the DEGAP checkout (must contain bin/AutoGapfiller.py etc.)
DEGAP_DIR="/path/to/DEGAP"

# Input genome assembly to gap-fill (FASTA, with N-gaps)
INPUT_ASSEMBLY="/path/to/mouse_assembly.fasta"

# Pre-corrected ONT reads, FASTA format
ONT_READS="/path/to/ont_reads_corrected.fasta"

# Output folder for the whole pipeline (created if missing)
OUTPUT_DIR="/path/to/output"

# Mouse telomere repeat motif
TELOMERE_MOTIF="TTAGGG"

# Extension round cap, applied to both stages
MAX_EXTENSION_ROUND=25

# Compute resources -- adjust to what you're allocated on the node
THREADS=20
WORKERS=4

# Chromosome-end target list for TelSeeker (one end per line, e.g. chr1.L).
# Leave empty for pass 1. TelSeekerCheck below writes plots under
# "$OUTPUT_DIR/telseeker_check/genome.telomere.check/" -- review those,
# write a target_ends.txt (see HOWTO.md), then set this path and re-run.
TARGET_ENDS_FILE=""

# ---------------------------------------------------------------------------
# Pipeline -- shouldn't need to edit below this line
# ---------------------------------------------------------------------------

echo "== DEGAP mouse gap-filling pipeline =="
echo "DEGAP_DIR:        $DEGAP_DIR"
echo "INPUT_ASSEMBLY:   $INPUT_ASSEMBLY"
echo "ONT_READS:        $ONT_READS"
echo "OUTPUT_DIR:       $OUTPUT_DIR"
echo "TELOMERE_MOTIF:   $TELOMERE_MOTIF"
echo "MAX_EXTENSION_ROUND: $MAX_EXTENSION_ROUND"
echo "THREADS / WORKERS: $THREADS / $WORKERS"
echo

mkdir -p "$OUTPUT_DIR"

AUTOGAPFILLER_OUT="$OUTPUT_DIR/autogapfiller"
FILLED_GENOME="$AUTOGAPFILLER_OUT/04.genome_integration/genome.filled.fasta"

# --- Stage 1: AutoGapfiller (internal N-gaps, whole genome) ---------------
if [ -f "$FILLED_GENOME" ]; then
    echo "[1/3] AutoGapfiller output already present, skipping: $FILLED_GENOME"
else
    echo "[1/3] Running AutoGapfiller..."
    python "$DEGAP_DIR/bin/AutoGapfiller.py" \
        --genome "$INPUT_ASSEMBLY" \
        --ont "$ONT_READS" \
        -o "$AUTOGAPFILLER_OUT" \
        --work "$WORKERS" \
        --thread "$THREADS" \
        --kmer_filter \
        --MaximumExtensionRound "$MAX_EXTENSION_ROUND"
fi

if [ ! -f "$FILLED_GENOME" ]; then
    echo "AutoGapfiller did not produce $FILLED_GENOME -- check the log above."
    exit 1
fi

# --- Stage 2: TelSeekerCheck (motif plots for manual review) --------------
TELSEEKER_CHECK_OUT="$OUTPUT_DIR/telseeker_check"
echo "[2/3] Running TelSeekerCheck..."
python "$DEGAP_DIR/bin/TelSeekerCheck.py" \
    --genome "$FILLED_GENOME" \
    --motif "$TELOMERE_MOTIF" \
    --out "$TELSEEKER_CHECK_OUT"

# --- Stage 3: TelSeeker (telomere-end extension) ---------------------------
if [ -z "$TARGET_ENDS_FILE" ]; then
    cat <<MSG

[3/3] TelSeeker not run yet -- target ends need manual review first.

Review the motif plots under:
  $TELSEEKER_CHECK_OUT/genome.telomere.check/all_chromosomes_combined.png
  $TELSEEKER_CHECK_OUT/genome.telomere.check/<chromosome>_telomere_motif.png

and the extracted end sequences:
  $TELSEEKER_CHECK_OUT/genome.telomere.check/genome.telomere.check.left.2kb.fa
  $TELSEEKER_CHECK_OUT/genome.telomere.check/genome.telomere.check.right.2kb.fa

Then write a target_ends.txt (one end per line, e.g. "Chr01.L"/"Chr01.R"; see
HOWTO.md's AutoGapfiller/TelSeeker section), set TARGET_ENDS_FILE at the top
of this script to that file's path, and re-run it.
MSG
    exit 0
fi

if [ ! -f "$TARGET_ENDS_FILE" ]; then
    echo "TARGET_ENDS_FILE is set but not found: $TARGET_ENDS_FILE"
    exit 1
fi

echo "[3/3] Running TelSeeker..."
python "$DEGAP_DIR/bin/DEGAP.py" \
    --mode telseeker \
    -o "$OUTPUT_DIR/telseeker" \
    --genome "$FILLED_GENOME" \
    --motif "$TELOMERE_MOTIF" \
    --ont "$ONT_READS" \
    --target_ends "$TARGET_ENDS_FILE" \
    --work "$WORKERS" \
    --thread "$THREADS" \
    --kmer_filter \
    --MaximumExtensionRound "$MAX_EXTENSION_ROUND"

echo "Done. TelSeeker output: $OUTPUT_DIR/telseeker"
