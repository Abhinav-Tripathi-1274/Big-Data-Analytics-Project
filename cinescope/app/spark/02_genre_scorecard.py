from pyspark.sql import functions as F

from common import HDFS, get_spark, save

spark = get_spark("CineScope-genre-scorecard")
ratings = spark.read.parquet(f"{HDFS}/cinescope/curated/ratings").select("movieId", "rating")
movies = spark.read.parquet(f"{HDFS}/cinescope/curated/movies")
movie_genre = (movies.select("movieId", F.explode(F.split("genres", r"\|")).alias("genre"))
               .filter(F.col("genre") != "(no genres listed)"))
scorecard = (ratings.join(F.broadcast(movie_genre), "movieId")
             .groupBy("genre")
             .agg(F.count("*").alias("ratings"),
                  F.countDistinct("movieId").alias("movies"),
                  F.round(F.avg("rating"), 4).alias("avg_rating"),
                  F.round(F.stddev_pop("rating"), 4).alias("std_rating"),
                  F.round(F.percentile_approx("rating", 0.5), 1).alias("median"),
                  F.round(F.avg((F.col("rating") >= 4).cast("int")) * 100, 2).alias("pct_4plus")))
save(scorecard, "genres")
scorecard.orderBy(F.desc("avg_rating")).show(30, truncate=False)
