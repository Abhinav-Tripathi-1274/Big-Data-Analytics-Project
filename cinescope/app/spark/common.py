"""Shared helpers for CineScope Spark jobs."""

import json
import os

from pathlib import Path

from pyspark.sql import SparkSession


HDFS = os.environ.get(
    "CINESCOPE_HDFS",
    "hdfs://master:8020",
).rstrip("/")

LOCAL_RESULTS = Path(
    os.environ.get(
        "CINESCOPE_RESULTS_DIR",
        "/var/lib/cinescope/results",
    )
)


def get_spark(name: str) -> SparkSession:

    return (
        SparkSession.builder
        .appName(name)
        .getOrCreate()
    )


def save(
    df,
    name: str,
    local_json: bool = True,
) -> None:
    """
    Persist authoritative results in HDFS.

    Small dashboard tables are additionally exported as JSON
    onto the physical master PC.

    Large fact tables remain in HDFS until export_results.sh.
    """

    hdfs_path = (
        f"{HDFS}/cinescope/results/{name}"
    )

    df.write.mode("overwrite").parquet(hdfs_path)

    if not local_json:
        print(f"[saved HDFS] {name}")
        return

    LOCAL_RESULTS.mkdir(
        parents=True,
        exist_ok=True,
    )

    records = [
        json.loads(row)
        for row in (
            df.sparkSession
            .read
            .parquet(hdfs_path)
            .toJSON()
            .collect()
        )
    ]

    target = LOCAL_RESULTS / f"{name}.json"

    temporary = target.with_name(
        f".{target.name}.{os.getpid()}.tmp"
    )

    try:

        temporary.write_text(
            json.dumps(
                records,
                allow_nan=False,
            ),
            encoding="utf-8",
        )

        os.replace(
            temporary,
            target,
        )

    finally:
        temporary.unlink(missing_ok=True)

    print(
        f"[saved] {name}: {len(records)} rows"
    )
