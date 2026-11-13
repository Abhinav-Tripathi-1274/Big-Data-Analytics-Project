import sys

from pyspark.sql import functions as F, types as T

from common import HDFS, get_spark

fmt, path = sys.argv[1], sys.argv[2]
has_header = (sys.argv[3] if len(sys.argv) > 3 else "true").lower() == "true"
spark = get_spark(f"CineScope-benchmark-{fmt}")
if fmt == "csv":
    schema = T.StructType([
        T.StructField("userId", T.IntegerType()), T.StructField("movieId", T.IntegerType()),
        T.StructField("rating", T.DoubleType()), T.StructField("ts", T.LongType()),
    ])
    ratings = spark.read.option("header", str(has_header).lower()).schema(schema).csv(path)
else:
    ratings = spark.read.parquet(path)
movies = spark.read.parquet(f"{HDFS}/cinescope/curated/movies")
genres = (movies.select("movieId", F.explode(F.split("genres", r"\|")).alias("genre"))
          .filter(F.col("genre") != "(no genres listed)"))
out = (ratings.select("movieId", "rating").join(F.broadcast(genres), "movieId")
       .groupBy("genre").agg(F.count("*").alias("n"), F.avg("rating").alias("avg")))
print("genres:", out.count())
