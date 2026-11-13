#!/usr/bin/env python3
import json
import os
import sys
import time

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import httpx
import pandas as pd

DATA_ROOT = Path(
    os.environ.get(
        "CINESCOPE_DATA_ROOT",
        "/var/lib/cinescope",
    )
)

RESULTS = DATA_ROOT / "results"
RAW = DATA_ROOT / "raw"

MOVIES_PATH = RESULTS / "movies_all"
OUT = RESULTS / "posters.json"

BASE_URL = "https://api.themoviedb.org/3/movie/{}"

MAX_ATTEMPTS = 4
REQUEST_INTERVAL = 0.06


def stop(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def atomic_save(data):
    """
    Save a complete JSON file before replacing the previous version.
    """

    temp = OUT.with_name(
        f".{OUT.name}.{os.getpid()}.tmp"
    )

    try:
        with temp.open("w", encoding="utf-8") as stream:

            json.dump(
                data,
                stream,
                ensure_ascii=False,
                separators=(",", ":")
            )

            stream.flush()
            os.fsync(stream.fileno())

        os.replace(temp, OUT)

    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def retry_delay(value, fallback):

    if not value:
        return fallback

    try:
        return max(0.0, float(value))

    except ValueError:
        try:
            when = parsedate_to_datetime(value)

            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)

            return max(
                0.0,
                (
                    when - datetime.now(timezone.utc)
                ).total_seconds()
            )

        except (TypeError, ValueError, OverflowError):
            return fallback


def find_links_file():

    dataset = os.environ.get("DATASET")

    if dataset:

        path = RAW / dataset / "links.csv"

        if not path.is_file():
            stop(
                f"DATASET={dataset!r} selected, "
                f"but {path} does not exist."
            )

        return path

    matches = sorted(RAW.glob("*/links.csv"))

    if len(matches) != 1:

        shown = "\n".join(
            f"  {path.parent.name}: {path}"
            for path in matches
        ) or "  (none found)"

        stop(
            "Could not identify one unambiguous MovieLens "
            "links.csv. Set DATASET to the dataset used by "
            "the completed pipeline.\n" + shown
        )

    return matches[0]


def load_cached():

    if not OUT.exists():
        return {}

    try:
        with OUT.open(encoding="utf-8") as stream:
            data = json.load(stream)

    except (OSError, json.JSONDecodeError) as error:

        stop(
            f"Existing {OUT} is unreadable. "
            f"Refusing to overwrite it: {error}"
        )

    if not isinstance(data, dict):
        stop(
            f"Existing {OUT} is not a JSON object. "
            "Refusing to overwrite it."
        )

    return data


def main():

    try:
        top = int(sys.argv[1]) if len(sys.argv) > 1 else 6000

    except ValueError:
        stop("Usage: posters.py [positive_TOP]")

    if top < 1:
        stop("TOP must be a positive integer.")

    bearer = os.environ.get(
        "TMDB_API_READ_ACCESS_TOKEN", ""
    ).strip()

    api_key = os.environ.get(
        "TMDB_API_KEY", ""
    ).strip()

    if not bearer and not api_key:

        stop(
            "Set TMDB_API_READ_ACCESS_TOKEN "
            "(recommended) or TMDB_API_KEY."
        )

    if not MOVIES_PATH.exists():

        stop(
            f"Missing {MOVIES_PATH}. "
            "The analysis/export pipeline must have "
            "completed first."
        )

    links_path = find_links_file()
    dataset_name = links_path.parent.name

    print(f"Selected dataset: {dataset_name}")
    print(f"Reading movies: {MOVIES_PATH}")
    print(f"Reading links: {links_path}")

    try:

        movies = pd.read_parquet(
            MOVIES_PATH,
            columns=["movieId", "n"]
        )

        links = pd.read_csv(
            links_path,
            usecols=["movieId", "tmdbId"]
        )

    except Exception as error:

        stop(
            f"Could not read movie/link data: {error}"
        )

    movies["movieId"] = pd.to_numeric(
        movies["movieId"],
        errors="coerce"
    )

    movies["n"] = pd.to_numeric(
        movies["n"],
        errors="coerce"
    ).fillna(0)

    links["movieId"] = pd.to_numeric(
        links["movieId"],
        errors="coerce"
    )

    links["tmdbId"] = pd.to_numeric(
        links["tmdbId"],
        errors="coerce"
    )

    movies = movies.dropna(
        subset=["movieId"]
    ).copy()

    links = links.dropna(
        subset=["movieId", "tmdbId"]
    ).copy()

    links = links[
        (links["tmdbId"] > 0) &
        (links["tmdbId"] % 1 == 0)
    ].copy()

    movies["movieId"] = movies[
        "movieId"
    ].astype("int64")

    links["movieId"] = links[
        "movieId"
    ].astype("int64")

    links["tmdbId"] = links[
        "tmdbId"
    ].astype("int64")

    links = links.drop_duplicates(
        subset=["movieId"],
        keep="first"
    )

    candidates = (
        movies.sort_values(
            ["n", "movieId"],
            ascending=[False, True]
        )
        .head(top)
        .merge(
            links[["movieId", "tmdbId"]],
            on="movieId",
            how="inner",
            validate="one_to_one"
        )
    )

    done = load_cached()

    previous_dataset = done.get("__dataset__")

    if done and previous_dataset is None:

        stop(
            f"Existing {OUT} has no dataset marker. "
            "Preserve it and move it aside before creating "
            "a fresh dataset-specific cache."
        )

    if (
        previous_dataset is not None
        and previous_dataset != dataset_name
    ):

        stop(
            f"Existing poster cache belongs to "
            f"{previous_dataset!r}, but the selected "
            f"dataset is {dataset_name!r}. "
            "Refusing to mix movie IDs."
        )

    done["__dataset__"] = dataset_name

    print(f"Candidates with TMDB IDs: {len(candidates)}")
    print(f"Already cached: {len(done) - 1}")

    headers = {
        "accept": "application/json"
    }

    params = {
        "language": "en-US"
    }

    if bearer:

        headers["Authorization"] = (
            f"Bearer {bearer}"
        )

    else:

        params["api_key"] = api_key

    processed = 0
    newly_saved = 0

    with httpx.Client(
        timeout=15.0,
        headers=headers,
        follow_redirects=True
    ) as client:

        for row in candidates.itertuples(index=False):

            movie_id = str(int(row.movieId))
            tmdb_id = int(row.tmdbId)

            if movie_id in done:
                continue

            response = None

            for attempt in range(MAX_ATTEMPTS):

                try:

                    response = client.get(
                        BASE_URL.format(tmdb_id),
                        params=params
                    )

                except httpx.RequestError as error:

                    if attempt == MAX_ATTEMPTS - 1:

                        print(
                            f"Network error for "
                            f"movieId={movie_id}: {error}"
                        )

                        break

                    time.sleep(
                        min(2 ** attempt, 30)
                    )

                    continue

                if response.status_code == 429:

                    if attempt == MAX_ATTEMPTS - 1:

                        print(
                            f"429 after {MAX_ATTEMPTS} attempts; "
                            f"will retry movieId={movie_id} "
                            "on the next run."
                        )

                        break

                    delay = retry_delay(
                        response.headers.get("Retry-After"),
                        min(2 ** attempt, 30)
                    )

                    print(
                        f"TMDB returned 429; "
                        f"backing off for {delay:.1f}s"
                    )

                    time.sleep(delay)
                    continue

                if 500 <= response.status_code < 600:

                    if attempt == MAX_ATTEMPTS - 1:

                        print(
                            f"TMDB {response.status_code} "
                            f"for movieId={movie_id}; "
                            "will retry on the next run."
                        )

                        break

                    time.sleep(
                        min(2 ** attempt, 30)
                    )

                    continue

                break

            if response is not None:

                if response.status_code == 401:

                    atomic_save(done)

                    stop(
                        "TMDB returned HTTP 401. "
                        "Check the API credentials."
                    )

                if response.status_code == 403:

                    atomic_save(done)

                    stop(
                        "TMDB returned HTTP 403. "
                        "Check account/token permissions."
                    )

                if response.status_code == 200:

                    item = response.json()

                    done[movie_id] = {
                        "poster": item.get("poster_path"),
                        "overview": item.get("overview")
                    }

                    newly_saved += 1

                elif response.status_code == 404:

                    done[movie_id] = {
                        "poster": None,
                        "overview": None
                    }

                    newly_saved += 1

                elif (
                    response.status_code != 429
                    and not (
                        500 <= response.status_code < 600
                    )
                ):

                    atomic_save(done)

                    stop(
                        f"Unexpected HTTP "
                        f"{response.status_code} for "
                        f"tmdbId={tmdb_id}: "
                        f"{response.text[:500]}"
                    )

            processed += 1

            if processed % 100 == 0:

                atomic_save(done)

                print(
                    f"Checked {processed}/{len(candidates)} "
                    f"candidates; cached {len(done) - 1} records."
                )

            time.sleep(REQUEST_INTERVAL)

    atomic_save(done)

    print(
        f"Saved {len(done) - 1} poster records to {OUT}. "
        f"{newly_saved} records added this run."
    )


if __name__ == "__main__":
    main()
