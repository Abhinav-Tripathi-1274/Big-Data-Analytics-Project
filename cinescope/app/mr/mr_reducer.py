#!/usr/bin/env python3
import math
import sys


def emit(genre, total, squares, count, high):
    average = total / count
    deviation = math.sqrt(max(squares / count - average * average, 0.0))
    print(f"{genre}\t{count}\t{average:.4f}\t{deviation:.4f}\t{100 * high / count:.2f}")


current = None
total = squares = 0.0
count = high = 0
for line in sys.stdin:
    genre, value, square, n, four_plus = line.rstrip("\n").split("\t")
    if genre != current:
        if current is not None:
            emit(current, total, squares, count, high)
        current, total, squares, count, high = genre, 0.0, 0.0, 0, 0
    total += float(value); squares += float(square); count += int(n); high += int(four_plus)
if current is not None:
    emit(current, total, squares, count, high)
