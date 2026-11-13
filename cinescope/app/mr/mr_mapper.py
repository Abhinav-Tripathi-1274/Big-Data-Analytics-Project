#!/usr/bin/env python3
import csv
import sys
from collections import defaultdict

genres_of = {}
with open("movies.csv", newline="", encoding="utf-8") as source:
    reader = csv.reader(source)
    next(reader, None)
    for row in reader:
        if len(row) >= 3 and row[2] != "(no genres listed)":
            genres_of[row[0]] = row[2].split("|")

aggregate = defaultdict(lambda: [0.0, 0.0, 0, 0])
for line in sys.stdin:
    parts = line.rstrip("\n").split(",")
    if len(parts) < 3 or parts[0] == "userId":
        continue
    try:
        rating = float(parts[2])
    except ValueError:
        continue
    for genre in genres_of.get(parts[1], []):
        item = aggregate[genre]
        item[0] += rating
        item[1] += rating * rating
        item[2] += 1
        item[3] += rating >= 4.0

for genre, (total, squares, count, high) in aggregate.items():
    print(f"{genre}\t{total}\t{squares}\t{count}\t{high}")
