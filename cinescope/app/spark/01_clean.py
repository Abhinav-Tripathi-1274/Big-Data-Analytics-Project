from pyspark.sql import functions as F, types as T

from common import HDFS, get_spark

spark = get_spark("CineScope-clean")
ratings_schema = T.StructType([
    T.StructField("userId", T.IntegerType()),
    T.StructField("movieId", T.IntegerType()),
    T.StructField("rating", T.DoubleType()),
    T.StructField("ts", T.LongType()),
])
movies_schema = T.StructType([
    T.StructField("movieId", T.IntegerType()),
    T.StructField("title", T.StringType()),
    T.StructField("genres", T.StringType()),
])

ratings = (spark.read.option("header", "true").schema(ratings_schema)
           .csv(f"{HDFS}/cinescope/raw/ratings"))
movies = (spark.read.option("header", "true").option("escape", '"').schema(movies_schema)
          .csv(f"{HDFS}/cinescope/raw/movies"))

ratings = (ratings.withColumn("ts_utc", F.col("ts").cast("timestamp"))
           .withColumn("rating_year", F.year("ts_utc"))
           .withColumn("dow", F.dayofweek("ts_utc"))
           .withColumn("hour", F.hour("ts_utc"))
           .select("userId", "movieId", "rating", "ts_utc", "rating_year", "dow", "hour"))
movies = (movies.withColumn("year", F.regexp_extract("title", r"\((\d{4})\)\s*$", 1).cast("int"))
          .withColumn("decade", (F.floor(F.col("year") / 10) * 10).cast("int")))

ratings.write.mode("overwrite").parquet(f"{HDFS}/cinescope/curated/ratings")
movies.write.mode("overwrite").parquet(f"{HDFS}/cinescope/curated/movies")
print("ratings=", ratings.count(), "movies=", movies.count())
