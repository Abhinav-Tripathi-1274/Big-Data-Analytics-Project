from pyspark.sql import Window, functions as F

from common import HDFS, get_spark, save

spark = get_spark("CineScope-analysis")
r = spark.read.parquet(f"{HDFS}/cinescope/curated/ratings")
m = spark.read.parquet(f"{HDFS}/cinescope/curated/movies")
mg = (m.select("movieId", "title", "year", "decade", F.explode(F.split("genres", r"\|")).alias("genre"))
      .filter(F.col("genre") != "(no genres listed)"))
rg = r.select("movieId", "rating", "rating_year").join(
    F.broadcast(mg.select("movieId", "decade", "genre")), "movieId")
summary = [F.count("*").alias("ratings"), F.round(F.avg("rating"), 4).alias("avg_rating")]

overview = r.agg(F.count("*").alias("ratings"), F.countDistinct("userId").alias("users"),
                 F.countDistinct("movieId").alias("movies_rated"), F.round(F.avg("rating"), 4).alias("avg_rating"),
                 F.min("rating_year").alias("first_year"), F.max("rating_year").alias("last_year"))
save(overview.withColumn("movies_total", F.lit(m.count()))
     .withColumn("genres", F.lit(mg.select("genre").distinct().count())), "overview")
save(rg.filter(F.col("decade").isNotNull()).groupBy("genre", "decade").agg(*summary), "genre_decade")
save(rg.groupBy("genre", "rating_year").agg(*summary), "genre_year")
save(r.groupBy("rating").agg(F.count("*").alias("n")).orderBy("rating"), "rating_hist")
save(rg.groupBy("genre", "rating").agg(F.count("*").alias("n")), "genre_hist")

movie_stats = r.groupBy("movieId").agg(F.count("*").alias("n"), F.round(F.avg("rating"), 4).alias("avg"),
                                         F.round(F.stddev_pop("rating"), 4).alias("std"))
save(m.join(movie_stats, "movieId", "left").na.fill({"n": 0})
     .select("movieId", "title", "year", "genres", "n", "avg", "std"), "movies_all", local_json=False)

mean_rating = r.agg(F.avg("rating")).first()[0]
minimum_votes = max(movie_stats.approxQuantile("n", [0.9], 0.01)[0], 25.0)
weighted = movie_stats.withColumn(
    "wr", F.round(F.col("n") / (F.col("n") + minimum_votes) * F.col("avg") +
                  minimum_votes / (F.col("n") + minimum_votes) * F.lit(mean_rating), 4))
eligible = F.col("n") >= minimum_votes
gem = (F.col("avg") >= 4.0) & (F.col("n") >= minimum_votes * 0.1) & (F.col("n") < minimum_votes)


def top_by(frame, order, condition, k=10):
    window = Window.partitionBy("genre").orderBy(F.desc(order), F.desc("n"))
    return (frame.filter(condition).withColumn("rk", F.row_number().over(window)).filter(F.col("rk") <= k)
            .select("genre", "rk", "movieId", "title", "year", "n", "avg", "std", "wr"))


movie_weighted = weighted.join(mg, "movieId")
save(top_by(movie_weighted, "wr", eligible), "genre_top10")
save(top_by(movie_weighted, "wr", gem), "genre_gems")
save(top_by(movie_weighted, "std", eligible), "genre_divisive")
base = weighted.join(m.select("movieId", "title", "year"), "movieId")
columns = ["movieId", "title", "year", "n", "avg", "std", "wr"]
save(base.filter(eligible).orderBy(F.desc("wr")).limit(20).select(*columns), "top_overall")
save(base.filter(gem).orderBy(F.desc("wr")).limit(20).select(*columns), "gems_overall")
save(base.filter(eligible).orderBy(F.desc("std")).limit(20).select(*columns), "divisive_overall")

users = r.groupBy("userId").agg(F.count("*").alias("n"), F.avg("rating").alias("avg"))
bucket = (F.when(F.col("n") < 50, "20-49").when(F.col("n") < 100, "50-99")
          .when(F.col("n") < 200, "100-199").when(F.col("n") < 500, "200-499")
          .when(F.col("n") < 1000, "500-999").otherwise("1000+"))
save(users.groupBy(bucket.alias("bucket")).agg(F.count("*").alias("users")), "user_activity")
save(users.groupBy((F.round(F.col("avg") * 2) / 2).alias("bin")).agg(F.count("*").alias("users")).orderBy("bin"), "user_avg_hist")
save(r.groupBy("dow", "hour").agg(F.count("*").alias("n")), "weekday_hour")
save(r.groupBy("rating_year").agg(*summary).orderBy("rating_year"), "year_volume")
save(r.groupBy("movieId", "rating").agg(F.count("*").alias("n")), "movie_hist", local_json=False)
save(r.groupBy("movieId", "rating_year").agg(F.count("*").alias("n"), F.round(F.avg("rating"), 3).alias("avg")),
     "movie_year", local_json=False)
print(f"analysis complete: C={mean_rating:.4f}, minimum_votes={minimum_votes}")
