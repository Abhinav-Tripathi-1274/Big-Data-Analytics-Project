# Big-Data-Analytics-Project

**Project Topic:** Movie Rating Analysis (MovieLens + Spark)  
**Product Name:** CineScope

## Team Members

Abhinav Tripathi, 231210002<br>
Ashutosh Dayal, 231210028<br>
Ayush Goyal, 231210031

## About

**Movie Rating Analysis (MovieLens + Spark)** is a Big Data Analytics course project developed by our team under the name **CineScope**.

CineScope is a distributed movie-rating analysis platform designed to transform large-scale movie-rating data into meaningful, interactive insights. Using datasets from [MovieLens](https://grouplens.org/datasets/movielens/), the project explores how users rate movies, how ratings vary across genres and time periods, and how movies differ in terms of popularity and audience reception.

The project uses **Apache Hadoop and Apache Spark** to build a distributed data-processing pipeline across three physical computers. Hadoop Distributed File System (HDFS) provides distributed storage, while YARN manages cluster resources and application execution. PySpark performs data cleaning, transformation and large-scale analytical processing. Hadoop Streaming MapReduce provides an independent implementation of genre-level aggregation, allowing its results to be compared against Spark's output.

CineScope explores several dimensions of movie-rating data, including:

- **Genre Analysis:** Rating distributions, average ratings, median ratings, rating variability and the proportion of high ratings across movie genres.
- **Temporal Analysis:** Rating trends across years and movie-release decades.
- **Movie Insights:** Movie-level rating statistics, popularity, vote-adjusted rankings, highly rated lesser-known movies and movies with widely varying audience opinions.
- **User Activity:** Rating participation patterns, rating tendencies and activity distributions.
- **Performance Analysis:** Comparisons between Spark and Hadoop Streaming MapReduce, CSV and Parquet input formats, and different worker configurations.

The analytical results are presented through an interactive web dashboard built with **React, ECharts and FastAPI**. It provides an accessible interface for exploring genre scorecards, rating trends, movie statistics, rankings and cluster information. An integration with **The Movie Database (TMDB)** enriches supported movie entries with poster artwork and additional descriptions.

By combining distributed storage, parallel data processing, analytical validation, performance benchmarking and interactive visualisation, CineScope demonstrates how large-scale movie-rating datasets can be processed and explored using a practical Hadoop and Spark ecosystem.

**The goal of CineScope is to turn movie-rating data into understandable insights while demonstrating the concepts and technologies of distributed Big Data Analytics.**
