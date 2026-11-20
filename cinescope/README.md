# CineScope: a three-node Hadoop + Spark lab on one Ubuntu computer

This project deliberately models three machines with three Docker containers:

| Container | Processes it owns | Persistent storage |
| --- | --- | --- |
| `master` | NameNode, SecondaryNameNode, ResourceManager, MapReduce history, Spark history, FastAPI and React UI | NameNode metadata and result/data cache |
| `worker1` | DataNode and NodeManager | HDFS DataNode blocks |
| `worker2` | DataNode and NodeManager | HDFS DataNode blocks |

Docker Compose supplies the private bridge network and its DNS. The service names `master`, `worker1`, and `worker2` are stable hostnames inside it, so this design intentionally has **no fixed IPs, `/etc/hosts` edits, SSH, rsync, or `start-dfs.sh`**. Those are appropriate to three physical PCs, not to this single-host Compose cluster.

The default configuration uses HDFS replication factor 2, 32 MiB blocks, and two 3 GiB YARN workers. The master formats its NameNode volume only on the first startup; restarts preserve the cluster.

## 1. Host requirements

- A 64-bit Ubuntu version supported by Docker Engine (22.04 or 24.04 are good choices).
- At least 12 GiB RAM available to Docker, 20 GiB free disk, and internet access for the first image/data download. On a 16 GiB host, close memory-heavy applications before running the 32M dataset.
- Docker Engine and the Compose plugin installed from the [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/). Confirm both before continuing:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

Docker-published ports can bypass `ufw` rules. This Compose file therefore binds every UI to `127.0.0.1`; the services are reachable only from the Ubuntu computer by default. Do not remove that loopback address unless the host and network access controls are intentionally configured.

## 2. Build and start the cluster

From this directory:

```bash
cp .env.example .env
docker compose build --pull
docker compose up -d
docker compose ps
```

The first build downloads, SHA-512 checks, and unpacks Apache Hadoop 3.4.3 and Spark 3.5.9. It also builds the React/Vite/Tailwind/ECharts dashboard. Wait until all three services report `healthy`:

```bash
docker compose ps
docker compose logs --tail=80 master
```

If Docker has less memory available, lower `MASTER_MEMORY` and `WORKER_MEMORY` in `.env` **and** lower the matching `3072` values in `app/cluster/conf/yarn-site.xml` before building. Keep each executor below a worker's YARN memory limit.

## 3. Prove that all three nodes work

Run Hadoop commands as the `hadoop` user, not as root:

```bash
docker compose exec --user hadoop master jps
docker compose exec --user hadoop worker1 jps
docker compose exec --user hadoop worker2 jps

docker compose exec --user hadoop master hdfs dfsadmin -report
docker compose exec --user hadoop master yarn node -list
docker compose exec --user hadoop master hadoop jar /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.3.jar pi 4 100
docker compose exec --user hadoop master spark-submit --class org.apache.spark.examples.SparkPi /opt/spark/examples/jars/spark-examples_2.12-3.5.9.jar 20
```

Expected process placement:

- `master`: `NameNode`, `SecondaryNameNode`, `ResourceManager`, `JobHistoryServer`, and `HistoryServer`.
- each worker: `DataNode` and `NodeManager`.
- `hdfs dfsadmin -report` reports two live DataNodes, and `yarn node -list` reports two RUNNING nodes.

Open these host-local URLs for screenshots/evidence:

- [CineScope dashboard](http://localhost:8000)
- [HDFS NameNode](http://localhost:9870)
- [YARN ResourceManager](http://localhost:8088)
- [MapReduce history](http://localhost:19888)
- [Spark history](http://localhost:18080)

## 4. Run the analysis pipeline

Begin with the small MovieLens dataset. It is downloaded inside the master data volume, uploaded to HDFS, cleaned into Parquet, analyzed with Spark, recomputed with Hadoop Streaming MapReduce, compared, and exported for the API/UI:

```bash
docker compose exec --user hadoop -e DATASET=ml-latest-small master bash /workspace/scripts/run_pipeline.sh
docker compose exec master curl -fsS -X POST http://localhost:8000/api/reload
```

Success ends with `PIPELINE DONE` and prints a validation object whose `match` is `True`. In the dashboard, the Cluster & Jobs page shows the green “Spark = MapReduce” result after loading the results.

Inspect block replicas directly:

```bash
docker compose exec --user hadoop master hdfs fsck /cinescope/raw/ratings/ratings.csv -files -blocks -locations
```

The project saves authoritative outputs in HDFS under `/cinescope/results`. Small dashboard summary tables are JSON in the master data volume; the larger per-movie Parquet tables are exported only after the analysis job completes.

## 5. Switch to MovieLens 32M

Do this only after the small-data run is green. MovieLens 32M is a stable benchmark: 32,000,204 ratings from 200,948 users over 87,585 movies. It is roughly 228–239 MB compressed and substantially larger when extracted.

```bash
docker compose exec --user hadoop -e DATASET=ml-32m master bash /workspace/scripts/run_pipeline.sh
docker compose exec master curl -fsS -X POST http://localhost:8000/api/reload
```

The input is intentionally not copied into source control. See the [GroupLens MovieLens 32M page](https://grouplens.org/datasets/movielens/32m/) and its [README/license/citation](https://files.grouplens.org/datasets/movielens/ml-32m-README.html) before redistribution or commercial use.

## 6. Benchmarks and failure rehearsal

After the 32M pipeline completes, launch the benchmark script in one terminal:

```bash
docker compose exec --user hadoop master bash /workspace/scripts/bench.sh
```

When it pauses for the one-worker test, use a second terminal in this project directory:

```bash
docker compose exec --user hadoop worker2 yarn --daemon stop nodemanager
docker compose exec --user hadoop master yarn node -list
```

Press Enter in the benchmark terminal after only `worker1` remains. Restore the second scheduler afterward:

```bash
docker compose exec --user hadoop worker2 yarn --daemon start nodemanager
```

Benchmark records are written to `benchmarks.json` in the master data volume and appear on the dashboard after a refresh.

For a fault-tolerance demonstration, start a long MapReduce job (the 10× input is best), then stop both worker2 services after it is under way:

```bash
docker compose exec --user hadoop worker2 yarn --daemon stop nodemanager
docker compose exec --user hadoop worker2 hdfs --daemon stop datanode
```

YARN should reschedule lost work to worker1, while HDFS continues to read the other replica. Restore afterward:

```bash
docker compose exec --user hadoop worker2 hdfs --daemon start datanode
docker compose exec --user hadoop worker2 yarn --daemon start nodemanager
```

This is an educational availability demonstration, not a claim of production-grade HA: there is one NameNode and exactly two DataNodes.

## Operations and troubleshooting

```bash
# Start after a host reboot; data survives.
docker compose up -d

# Stop while retaining HDFS data and results.
docker compose down

# Live logs
docker compose logs -f master
docker compose logs -f worker1 worker2
```

| Symptom | First check |
| --- | --- |
| Worker missing from HDFS | `docker compose logs worker1` and `docker compose exec --user hadoop master hdfs dfsadmin -report` |
| Worker missing from YARN | `docker compose exec --user hadoop master yarn node -list`; then inspect `docker compose logs worker1` |
| Spark remains ACCEPTED | Both workers must be RUNNING; check the 3 GiB worker limit and executor requests in `spark-defaults.conf` |
| Spark archive error | `docker compose logs master`; the master stages `/spark-archive/spark-libs.zip` automatically during first startup |
| Dashboard has no analysis | Run the pipeline, then `POST /api/reload` as shown above |
| Full reset required | Use the explicit destructive command below |

**Destructive reset—erases the NameNode, both DataNodes, downloaded datasets and all results:**

```bash
docker compose down -v
```

## Version and security notes

- Hadoop 3.4.3 is a current 3.4 maintenance release; Apache publishes it with checksums and release notes. The project verifies the published SHA-512 during image build. [Apache Hadoop releases](https://hadoop.apache.org/releases)
- Spark 3.5.9 is the current 3.5 patch release, selected for compatibility with the requested 3.x project. It is not the newest Spark major version. Spark 3.5 supports Java 8/11/17 and Python 3.8+, so this image pins Java 11 for consistency—not because Java 11 is the only usable runtime. [Spark 3.5.9 docs](https://spark.apache.org/docs/3.5.9/)
- Spark-on-YARN requires `HADOOP_CONF_DIR` or `YARN_CONF_DIR`; the image provides both on every node and stages a shared Spark archive in HDFS. [Official Spark-on-YARN guide](https://spark.apache.org/docs/3.5.9/running-on-yarn.html)
- This has no Kerberos, TLS, authorization policy, HA NameNode, monitoring/alerting, or backup regime. Keep it private. Hadoop explicitly warns that an unauthenticated cluster grants anyone with network access broad data and compute access.

## Evidence checklist for a report/demo

1. `docker compose ps` showing three healthy containers.
2. `jps` on the master and each worker.
3. NameNode UI with two DataNodes and ResourceManager UI with two nodes.
4. `hdfs fsck` output showing block locations and replication.
5. a Spark application in the ResourceManager with executors on both workers.
6. the MapReduce output and `validation.json` / dashboard badge proving Spark and MapReduce agree.
7. the 1-vs-2-worker benchmarks and a recorded worker2 failure/recovery exercise.
