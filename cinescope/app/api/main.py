import os
import json
import re
import socket
import subprocess
import time
from functools import lru_cache
from pathlib import Path

import httpx
import pandas as pd
import threading
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

RESULTS = Path("/data/results")
RM = "http://master:8088/ws/v1/cluster"

HADOOP_HOME = "/opt/hadoop"
SPARK_HOME = "/opt/spark"
JAVA_HOME = "/opt/java/openjdk"

HDFS_BIN = f"{HADOOP_HOME}/bin/hdfs"
SPARK_SUBMIT = f"{SPARK_HOME}/bin/spark-submit"


def cluster_env():
    env = os.environ.copy()

    env.update({
        "HOME": "/home/hadoop",
        "HADOOP_HOME": HADOOP_HOME,
        "HADOOP_CONF_DIR": f"{HADOOP_HOME}/etc/hadoop",
        "YARN_CONF_DIR": f"{HADOOP_HOME}/etc/hadoop",
        "SPARK_HOME": SPARK_HOME,
        "JAVA_HOME": JAVA_HOME,
        "HADOOP_LOG_DIR": "/var/log/hadoop",
        "HADOOP_PID_DIR": "/var/run/hadoop",
        "PYSPARK_PYTHON": "/usr/bin/python3",
    })

    required_paths = [
        f"{HADOOP_HOME}/bin",
        f"{HADOOP_HOME}/sbin",
        f"{SPARK_HOME}/bin",
        f"{SPARK_HOME}/sbin",
        "/usr/local/sbin",
        "/usr/local/bin",
        "/usr/sbin",
        "/usr/bin",
        "/sbin",
        "/bin",
    ]

    env["PATH"] = os.pathsep.join(
        required_paths + [env.get("PATH", "")]
    )

    return env

app = FastAPI(title="CineScope")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@lru_cache(maxsize=None)
def read_json(name: str):
    path = RESULTS / name
    return json.loads(path.read_text()) if path.exists() else []


@lru_cache(maxsize=None)
def read_table(name: str):
    path = RESULTS / name
    return pd.read_parquet(path) if path.exists() else pd.DataFrame()


def records(frame):
    """Pandas' encoder safely translates NaN to JSON null."""
    return json.loads(frame.to_json(orient="records"))


async def resource_manager(path: str):
    async with httpx.AsyncClient(timeout=5) as client:
        response = await client.get(f"{RM}/{path}")
        response.raise_for_status()
        return response.json()


@app.get("/api/overview")
def overview():
    return (read_json("overview.json") or [{}])[0]


@app.get("/api/genres")
def genres():
    return read_json("genres.json")


@app.get("/api/genres/{name}")
def genre(name: str):
    matching = lambda file: [row for row in read_json(file) if row.get("genre") == name]
    summary = matching("genres.json")
    return {
        "summary": summary[0] if summary else None,
        "hist": sorted(matching("genre_hist.json"), key=lambda row: row["rating"]),
        "decades": sorted(matching("genre_decade.json"), key=lambda row: row["decade"]),
        "top": sorted(matching("genre_top10.json"), key=lambda row: row["rk"]),
        "gems": sorted(matching("genre_gems.json"), key=lambda row: row["rk"]),
        "divisive": sorted(matching("genre_divisive.json"), key=lambda row: row["rk"]),
    }


@app.get("/api/top")
def top():
    return read_json("top_overall.json")[:20]

@app.get("/api/posters")
def posters():
    data = read_json("posters.json")

    if not isinstance(data, dict):
        return {}

    # Do not expose the internal dataset-identification field.
    return {
        key: value
        for key, value in data.items()
        if key != "__dataset__"
    }

@app.get("/api/insights")
def insights():
    names = ("rating_hist", "user_activity", "user_avg_hist", "weekday_hour", "year_volume",
             "gems_overall", "divisive_overall")
    return {name: read_json(f"{name}.json") for name in names}


@app.get("/api/trends")
def trends():
    return {"genre_year": read_json("genre_year.json"), "genre_decade": read_json("genre_decade.json")}


@app.get("/api/movies/search")
def search_movies(q: str, limit: int = 12):
    frame = read_table("movies_all")
    if frame.empty:
        return []
    hits = frame[frame["title"].str.contains(q, case=False, regex=False, na=False)]
    return records(hits.sort_values("n", ascending=False).head(max(1, min(limit, 50))))


@app.get("/api/movies/{movie_id}")
def movie(movie_id: int):
    films = read_table("movies_all")
    row = films[films["movieId"] == movie_id]
    if row.empty:
        return {"error": "not found"}
    histogram, yearly = read_table("movie_hist"), read_table("movie_year")
    result = records(row)[0]
    result["hist"] = records(histogram[histogram["movieId"] == movie_id].sort_values("rating")[["rating", "n"]])
    result["by_year"] = records(yearly[yearly["movieId"] == movie_id].sort_values("rating_year")[["rating_year", "n", "avg"]])
    return result


def _as_list(value):
    if value is None:
        return []

    if isinstance(value, list):
        return value

    if isinstance(value, dict):
        return [value]

    raise TypeError(
        f"Expected a JSON array or object, got {type(value).__name__}"
    )

@app.get("/api/cluster/summary")
async def cluster_summary():
    try:
        payload = await resource_manager("metrics")
        metrics = payload.get("clusterMetrics")

        if not isinstance(metrics, dict):
            raise ValueError(
                "ResourceManager response does not contain clusterMetrics"
            )

        fields = (
            "activeNodes",
            "totalNodes",
            "lostNodes",
            "appsRunning",
            "appsCompleted",
        )

        return {
            "host": socket.gethostname(),
            **{key: metrics.get(key, 0) for key in fields},
        }

    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail=f"YARN metrics unavailable: {error}",
        ) from error


@app.get("/api/cluster/nodes")
async def cluster_nodes():
    try:
        payload = await resource_manager("nodes")

        wrapper = payload.get("nodes") or {}
        raw_nodes = wrapper.get("node") if isinstance(wrapper, dict) else None

        nodes = _as_list(raw_nodes)

        if not all(isinstance(node, dict) for node in nodes):
            raise ValueError("Invalid NodeManager response structure")

        return [
            {
                "host": node.get("nodeHostName") or node.get("id", "unknown"),
                "state": node.get("state", "UNKNOWN"),
                "containers": node.get("numContainers", 0),
                "memUsedMB": node.get("usedMemoryMB", 0),
                "memAvailMB": node.get("availMemoryMB", 0),
            }
            for node in nodes
        ]

    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail=f"YARN NodeManager information unavailable: {error}",
        ) from error


@app.get("/api/cluster/apps")
async def cluster_apps():
    try:
        payload = await resource_manager("apps?limit=25")

        wrapper = payload.get("apps") or {}
        raw_apps = wrapper.get("app") if isinstance(wrapper, dict) else None

        apps = _as_list(raw_apps)

        if not all(isinstance(item, dict) for item in apps):
            raise ValueError("Invalid YARN applications response structure")

        apps.sort(
            key=lambda item: int(item.get("startedTime") or 0),
            reverse=True,
        )

        return [
            {
                "id": item["id"],
                "name": item.get("name", "Unnamed application"),
                "type": item.get("applicationType", "UNKNOWN"),
                "state": item.get("state", "UNKNOWN"),
                "final": item.get("finalStatus", "UNKNOWN"),
                "seconds": round(
                    float(item.get("elapsedTime") or 0) / 1000,
                    1,
                ),
            }
            for item in apps
        ]

    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail=f"YARN application information unavailable: {error}",
        ) from error

_hdfs_cache = {"at": 0, "value": {}}

def _run_hdfs_command(args, timeout):
    process = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=cluster_env(),
    )

    if process.returncode != 0:
        diagnostic = (
            process.stderr or process.stdout or "No diagnostic output"
        ).strip()

        raise RuntimeError(
            f"Command {' '.join(args)} exited with "
            f"status {process.returncode}: {diagnostic[-1200:]}"
        )

    return process.stdout


@app.get("/api/cluster/hdfs")
def hdfs_status():
    if time.time() - _hdfs_cache["at"] < 15:
        return _hdfs_cache["value"]

    result = {
        "datanodes": 0,
        "blocks": [],
        "total_blocks": None,
        "file": "/cinescope/raw/ratings/ratings.csv",
    }

    try:
        report = _run_hdfs_command(
            [HDFS_BIN, "dfsadmin", "-report"],
            timeout=20,
        )

        match = re.search(
            r"Live datanodes\s+\((\d+)\)",
            report,
        )

        if not match:
            raise RuntimeError(
                "Could not determine the number of live HDFS DataNodes"
            )

        result["datanodes"] = int(match.group(1))

        fsck = _run_hdfs_command(
            [
                HDFS_BIN,
                "fsck",
                result["file"],
                "-files",
                "-blocks",
                "-locations",
            ],
            timeout=30,
        )

        match = re.search(
            r"Total blocks \(validated\):\s*(\d+)",
            fsck,
        )

        if not match:
            raise RuntimeError(
                "Could not extract the validated HDFS block count. "
                f"fsck output: {fsck[-1000:]}"
            )

        result["total_blocks"] = int(match.group(1))

        replicas = {}

        for ip in re.findall(
            r"DatanodeInfoWithStorage\[([\d.]+):",
            fsck,
        ):
            replicas[ip] = replicas.get(ip, 0) + 1

        for ip, count in sorted(replicas.items()):
            try:
                host = socket.gethostbyaddr(ip)[0].split(".")[0]
            except OSError:
                host = ip

            result["blocks"].append({
                "node": host,
                "replicas": count,
            })

    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail=f"HDFS monitoring failed: {error}",
        ) from error

    _hdfs_cache.update(
        at=time.time(),
        value=result,
    )

    return result

@app.get("/api/validation")
def validation():
    return read_json("validation.json") or {}


@app.get("/api/benchmarks")
def benchmarks():
    return read_json("benchmarks.json")

RUN = {"state": "idle", "log": ""}
RUN_LOCK = threading.Lock()


def scorecard_job():
    try:
        command = [
            "/bin/bash",
            "-c",
            (
                "bash /workspace/scripts/ensure_spark_archive.sh "
                "&& "
                f"{SPARK_SUBMIT} /workspace/spark/02_genre_scorecard.py"
            ),
        ]

        process = subprocess.Popen(
            command,
            cwd="/workspace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=cluster_env(),
        )

        if process.stdout is None:
            raise RuntimeError("Could not capture Spark job output")

        for line in process.stdout:
            with RUN_LOCK:
                RUN["log"] = (RUN["log"] + line)[-5000:]

        return_code = process.wait()

        with RUN_LOCK:
            RUN["state"] = (
                "done" if return_code == 0 else "failed"
            )

            if return_code != 0:
                RUN["log"] = (
                    RUN["log"]
                    + f"\nSpark process exited with code {return_code}\n"
                )[-5000:]

    except Exception as error:
        with RUN_LOCK:
            RUN["state"] = "failed"
            RUN["log"] = (
                RUN["log"]
                + f"\nERROR: {type(error).__name__}: {error}\n"
            )[-5000:]

    finally:
        read_json.cache_clear()


@app.post("/api/run")
def run_scorecard(background: BackgroundTasks):
    with RUN_LOCK:
        if RUN["state"] != "running":
            RUN.update(
                state="running",
                log="",
            )

            background.add_task(scorecard_job)

        return dict(RUN)


@app.get("/api/run/status")
def run_status():
    with RUN_LOCK:
        return dict(RUN)

@app.post("/api/reload")
def reload_data():
    read_json.cache_clear()
    read_table.cache_clear()
    return {"ok": True}


app.mount("/", StaticFiles(directory="/opt/cinescope-web", html=True), name="web")
