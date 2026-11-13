#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time
from pathlib import Path

RESULTS = Path(os.environ.get("CINESCOPE_RESULTS_DIR", "/var/lib/cinescope/results"))
HADOOP_HOME = os.environ.get("HADOOP_HOME", "/opt/hadoop")
HDFS_BIN = str(Path(HADOOP_HOME) / "bin" / "hdfs")
HDFS_ROOT = os.environ.get("CINESCOPE_HDFS", "hdfs://master:8020").rstrip("/")
HDFS_RESULTS = f"{HDFS_ROOT}/cinescope/results"


def main() -> int:
    spark_path = RESULTS / "genres.json"
    if not spark_path.is_file():
        raise SystemExit(f"Missing Spark results: {spark_path}")
    if not Path(HDFS_BIN).is_file():
        raise SystemExit(f"HDFS executable not found: {HDFS_BIN}")

    spark_rows = json.loads(spark_path.read_text(encoding="utf-8"))
    if not isinstance(spark_rows, list):
        raise SystemExit("Spark genres.json must contain a JSON array.")
    spark = {row["genre"]: row for row in spark_rows}

    process = subprocess.run(
        [HDFS_BIN, "dfs", "-cat", f"{HDFS_RESULTS}/mr_genre/part-*"],
        check=True,
        capture_output=True,
        text=True,
    )

    mr = {}
    for line in process.stdout.strip().splitlines():
        fields = line.split("\t")
        if len(fields) != 5:
            raise SystemExit(f"Unexpected MapReduce output row: {line!r}")
        genre, count, average, deviation, four_plus = fields
        mr[genre] = (int(count), float(average), float(deviation), float(four_plus))

    differences = []
    for genre, row in spark.items():
        if genre not in mr:
            differences.append(genre)
            continue
        mr_count, mr_average, mr_std, mr_high = mr[genre]
        if (
            mr_count != int(row["ratings"])
            or abs(mr_average - float(row["avg_rating"])) > 1e-3
            or abs(mr_std - float(row["std_rating"])) > 1e-3
            or abs(mr_high - float(row["pct_4plus"])) > 0.011
        ):
            differences.append(genre)

    extra_mr_genres = sorted(set(mr) - set(spark))
    if extra_mr_genres:
        differences.extend(extra_mr_genres)

    result = {
        "match": not differences and len(mr) == len(spark),
        "genres": len(spark),
        "mapreduce_genres": len(mr),
        "differences": sorted(set(differences)),
        "checked": time.strftime("%Y-%m-%d %H:%M:%S"),
    }

    RESULTS.mkdir(parents=True, exist_ok=True)
    target = RESULTS / "validation.json"
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)

    print(json.dumps(result, indent=2))
    if not result["match"]:
        print("Validation failed: Spark and MapReduce results differ.", file=sys.stderr)
        return 1
    print("Validation passed: Spark and MapReduce results agree within the configured tolerances.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
