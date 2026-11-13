"""
Unit test: the MapReduce mapper/reducer pipeline must give the same genre
averages as a straightforward pure-Python computation.

Run:  python3 -m unittest discover -s tests -v
"""
import csv
import os
import random
import subprocess
import sys
import tempfile
import unittest
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MAPPER = os.path.join(ROOT, "mapreduce", "mapper.py")
REDUCER = os.path.join(ROOT, "mapreduce", "reducer.py")


def run(cmd, stdin_text, env=None):
    return subprocess.run(cmd, input=stdin_text, capture_output=True, text=True,
                          check=True, env=env).stdout


def sort_lines(text):
    return "".join(sorted(text.splitlines(keepends=True)))


class MapReducePipelineTest(unittest.TestCase):
    def test_matches_reference(self):
        rnd = random.Random(7)
        genres_all = ["Action", "Comedy", "Drama", "Horror", "Sci-Fi"]
        movies = {}
        with tempfile.TemporaryDirectory() as tmp:
            mpath = os.path.join(tmp, "movies.csv")
            with open(mpath, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["movieId", "title", "genres"])
                for i in range(1, 31):
                    g = rnd.sample(genres_all, rnd.randint(1, 3)) if i % 10 else []
                    movies[str(i)] = g
                    # title with a comma + quotes to test CSV parsing
                    w.writerow([i, f'Movie, "{i}" (2000)', "|".join(g) or "(no genres listed)"])
            lines = ["userId,movieId,rating,timestamp"]
            ratings = []
            for _ in range(500):
                mid, r = str(rnd.randint(1, 30)), rnd.choice([0.5, 1, 2.5, 3, 4, 4.5, 5])
                ratings.append((mid, r))
                lines.append(f"{rnd.randint(1, 50)},{mid},{r},1000000000")

            env = dict(os.environ, MOVIES_FILE=mpath)
            mapped = sort_lines(run([sys.executable, MAPPER], "\n".join(lines) + "\n", env))
            combined = sort_lines(run([sys.executable, REDUCER, "--combine"], mapped))
            final = run([sys.executable, REDUCER], combined)

        got = {}
        for line in final.splitlines():
            g, avg, n = line.split("\t")
            got[g] = (float(avg), int(n))

        ref = defaultdict(lambda: [0.0, 0])
        for mid, r in ratings:
            for g in movies[mid]:
                ref[g][0] += r
                ref[g][1] += 1

        self.assertEqual(set(got), set(ref))
        for g, (total, n) in ref.items():
            self.assertEqual(got[g][1], n)
            self.assertAlmostEqual(got[g][0], total / n, places=4)


if __name__ == "__main__":
    unittest.main()
