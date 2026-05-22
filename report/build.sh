#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "==> Generating plots..."
python3 plot_asr_comparison.py
python3 plot_english_plugins.py
python3 plot_blindspot.py

echo "==> Compiling LaTeX..."
tectonic sarvam_redteam_report.tex

echo ""
echo "Done → sarvam_redteam_report.pdf"
