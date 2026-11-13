#!/usr/bin/env python3

import json
import os
import sys
import time

from pathlib import Path


RESULTS = Path(
    os.environ.get(
        "CINESCOPE_RESULTS_DIR",
        "/var/lib/cinescope/results",
    )
)

path = RESULTS / "benchmarks.json"


def main():

    if len(sys.argv) != 7:
        raise SystemExit(
            "Usage: bench_log.py ID ENGINE FORMAT SIZE "
            "WORKERS SECONDS"
        )

    RESULTS.mkdir(
        parents=True,
        exist_ok=True,
    )

    rows = (
        json.loads(path.read_text(encoding="utf-8"))
        if path.exists()
        else []
    )

    identifier, engine, fmt, size, workers, seconds = (
        sys.argv[1:7]
    )

    rows = [
        row
        for row in rows
        if row["id"] != identifier
    ]

    rows.append({
        "id": identifier,
        "engine": engine,
        "format": fmt,
        "data": size,
        "workers": int(workers),
        "seconds": float(seconds),
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
    })

    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.tmp"
    )

    try:

        temporary.write_text(
            json.dumps(rows, indent=2),
            encoding="utf-8",
        )

        os.replace(temporary, path)

    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
