"""Small shared helpers for CineScope Spark jobs."""
import json
from pathlib import Path

from pyspark.sql import SparkSession

HDFS = "hdfs://master:8020"
LOCAL_RESULTS = Path("/data/results")


def get_spark(name: str) -> SparkSession:
    return SparkSession.builder.appName(name).getOrCreate()


def save(df, name: str, local_json: bool = True) -> None:
    """Persist the authoritative result in HDFS and small UI tables locally."""
    path = f"{HDFS}/cinescope/results/{name}"
    df.write.mode("overwrite").parquet(path)
    if not local_json:
        print(f"[saved HDFS] {name}")
        return
    LOCAL_RESULTS.mkdir(parents=True, exist_ok=True)
    # Only summary tables use this path. Do not collect large fact tables.
    records = [json.loads(row) for row in df.sparkSession.read.parquet(path).toJSON().collect()]
    (LOCAL_RESULTS / f"{name}.json").write_text(json.dumps(records, allow_nan=False))
    print(f"[saved] {name}: {len(records)} rows")
