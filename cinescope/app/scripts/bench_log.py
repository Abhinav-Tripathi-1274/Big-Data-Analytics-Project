import json
import sys
import time
from pathlib import Path

path = Path("/data/results/benchmarks.json")
rows = json.loads(path.read_text()) if path.exists() else []
identifier, engine, fmt, size, workers, seconds = sys.argv[1:7]
rows = [row for row in rows if row["id"] != identifier]
rows.append({"id": identifier, "engine": engine, "format": fmt, "data": size,
             "workers": int(workers), "seconds": float(seconds),
             "at": time.strftime("%Y-%m-%d %H:%M:%S")})
path.write_text(json.dumps(rows, indent=2))
