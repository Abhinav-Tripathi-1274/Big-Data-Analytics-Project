#!/usr/bin/env bash
set -Eeuo pipefail

cd /workspace
bash scripts/ensure_spark_archive.sh
bash scripts/load_hdfs.sh
spark-submit spark/01_clean.py
spark-submit spark/02_genre_scorecard.py
bash scripts/run_mr.sh
python3 scripts/compare.py
spark-submit spark/03_analysis.py
bash scripts/export_results.sh
echo 'PIPELINE DONE'
