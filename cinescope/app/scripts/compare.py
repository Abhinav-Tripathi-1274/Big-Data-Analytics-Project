import json
import subprocess
import time
from pathlib import Path

results = Path("/data/results")
spark = {row["genre"]: row for row in json.loads((results / "genres.json").read_text())}
output = subprocess.run(
    ["hdfs", "dfs", "-cat", "/cinescope/results/mr_genre/part-*"],
    check=True, capture_output=True, text=True).stdout
mr = {}
for line in output.strip().splitlines():
    genre, count, average, deviation, four_plus = line.split("\t")
    mr[genre] = (int(count), float(average), float(deviation), float(four_plus))

differences = [
    genre for genre, row in spark.items()
    if genre not in mr or mr[genre][0] != row["ratings"]
    or abs(mr[genre][1] - row["avg_rating"]) > 1e-3
    or abs(mr[genre][2] - row["std_rating"]) > 1e-3
    or abs(mr[genre][3] - row["pct_4plus"]) > 0.011
]
result = {"match": not differences and len(mr) == len(spark), "genres": len(spark),
          "differences": differences, "checked": time.strftime("%Y-%m-%d %H:%M:%S")}
(results / "validation.json").write_text(json.dumps(result, indent=2))
print(result)
