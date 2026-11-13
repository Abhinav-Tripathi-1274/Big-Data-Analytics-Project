#!/usr/bin/env python3
import sys

current = None
total = squares = 0.0
count = high = 0
for line in sys.stdin:
    genre, value, square, n, four_plus = line.rstrip("\n").split("\t")
    if genre != current:
        if current is not None:
            print(f"{current}\t{total}\t{squares}\t{count}\t{high}")
        current, total, squares, count, high = genre, 0.0, 0.0, 0, 0
    total += float(value); squares += float(square); count += int(n); high += int(four_plus)
if current is not None:
    print(f"{current}\t{total}\t{squares}\t{count}\t{high}")
