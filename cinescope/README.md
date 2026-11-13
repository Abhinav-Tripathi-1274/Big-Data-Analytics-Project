# CineScope — three physical Ubuntu PCs

CineScope is a distributed Big Data Analytics project using Hadoop, HDFS,
YARN, Hadoop Streaming MapReduce, Spark/PySpark, FastAPI, React, ECharts and
MovieLens. This guide describes the **physical three-computer deployment**.

---

## 1. Physical architecture

| Physical PC | Hostname | Services |
|---|---|---|
| PC 1 | `master` | HDFS NameNode and SecondaryNameNode; YARN ResourceManager; MapReduce JobHistory Server; Spark driver and Spark History Server; FastAPI; React dashboard |
| PC 2 | `worker1` | HDFS DataNode and YARN NodeManager |
| PC 3 | `worker2` | HDFS DataNode and YARN NodeManager |

All three computers must be connected to the same trusted LAN and must be
able to resolve and contact one another. This deployment snapshot targets
Ubuntu 24.04 LTS (Noble) on all three PCs. Prefer wired Ethernet, stable IP
addresses or DHCP reservations. The installation scripts support `x86_64`
and `aarch64/arm64`; using the same CPU architecture on all three PCs is
simplest.

### HDFS

- One NameNode on `master`.
- One DataNode on each worker.
- Default replication factor: 2.
- HDFS block size: 32 MiB.
- NameNode metadata is stored on `master` in `/var/lib/hadoop/namenode`.
- DataNode blocks are stored locally on each worker in `/var/lib/hadoop/datanode`.

### YARN and MapReduce

- ResourceManager on `master`.
- NodeManager on `worker1` and `worker2`.
- Hadoop Streaming executes the Python mapper, combiner and reducer as YARN tasks.
- MapReduce JobHistory Server runs on `master`.

### Spark

- `spark-submit` and the Spark driver run on `master` in YARN client mode.
- Two YARN executors are requested by the default Spark configuration.
- Executors are scheduled on the worker NodeManagers. Two requested executors do
  **not** guarantee one executor on each worker; verify their actual hostnames in
  the Spark application UI/History Server.

### Application

- FastAPI and the built React dashboard run on `master`.
- Dashboard output caches and exported Parquet tables are stored locally under
  `/var/lib/cinescope/results` on `master`.
- Authoritative raw, curated and result datasets are stored in HDFS under
  `/cinescope`.

### Availability limitation

`master` is a single point of failure. The SecondaryNameNode creates HDFS
checkpoints; it is **not** a standby NameNode and does not provide automatic
failover. This configuration is a small teaching cluster, not an HA design.

---

## 2. Project structure

```text
cinescope/
├── app/
│   ├── api/
│   │   └── main.py
│   ├── frontend/
│   │   ├── index.html
│   │   ├── package.json
│   │   ├── package-lock.json
│   │   ├── src/
│   │   │   ├── assets/
│   │   │   │   └── tmdb-logo.svg
│   │   │   ├── main.jsx
│   │   │   └── styles.css
│   │   └── vite.config.js
│   ├── mr/
│   │   ├── mr_mapper.py
│   │   ├── mr_combiner.py
│   │   └── mr_reducer.py
│   ├── scripts/
│   │   ├── bench_log.py
│   │   ├── bench.sh
│   │   ├── compare.py
│   │   ├── ensure_spark_archive.sh
│   │   ├── export_results.sh
│   │   ├── load_hdfs.sh
│   │   ├── posters.py
│   │   ├── run_mr.sh
│   │   └── run_pipeline.sh
│   └── spark/
│       ├── 01_clean.py
│       ├── 02_genre_scorecard.py
│       ├── 03_analysis.py
│       ├── bench_genre.py
│       └── common.py
├── config/
│   ├── hadoop/
│   │   ├── capacity-scheduler.xml
│   │   ├── core-site.xml
│   │   ├── hadoop-env.sh
│   │   ├── hdfs-site.xml
│   │   ├── mapred-site.xml
│   │   ├── workers
│   │   └── yarn-site.xml
│   └── spark/
│       ├── spark-defaults.conf
│       └── spark-env.sh
├── deploy/
│   └── cinescope-api.service
├── scripts/
│   ├── cluster-check.sh
│   ├── cluster-lib.sh
│   ├── format-namenode.sh
│   ├── install-distributed-tools.sh
│   ├── prepare-node.sh
│   ├── start-cluster.sh
│   └── stop-cluster.sh
├── .gitignore
├── README.md
└── requirements.txt
```

---

## 3. Before installation: check hardware and storage

The YARN configuration initially reserves **3072 MiB per worker** for YARN
containers. This is a starting value, not a universal setting. On each PC,
inspect the actual memory, CPU and disk capacity before proceeding:

```bash
hostnamectl
lscpu
free -h
df -h /
df -h /var
```

Leave enough RAM for Ubuntu, Hadoop daemons and any other applications. If a
worker cannot safely reserve 3072 MiB for YARN, change the two matching memory
values in `config/hadoop/yarn-site.xml` **before preparing any PC**:

- `yarn.nodemanager.resource.memory-mb`
- `yarn.scheduler.maximum-allocation-mb`

Keep the maximum allocation at least as large as the largest requested YARN
container. The Spark executor and AM memory settings are in
`config/spark/spark-defaults.conf`; MapReduce memory settings are in
`config/hadoop/mapred-site.xml`. Recheck all of them together if you change
worker memory.

Also ensure that the workers have sufficient free disk for HDFS blocks and
intermediate data. With replication 2, HDFS stores two replicas of each
replicated block on different DataNodes. The master needs disk for the
NameNode metadata, downloaded MovieLens archives/CSV files, Python virtual
environment, frontend build and exported results.

---

## 4. Choose stable LAN addresses and hostnames

Use static addresses or DHCP reservations. The following are examples only:

| Hostname | Example private IPv4 address |
|---|---|
| `master` | `192.168.1.10` |
| `worker1` | `192.168.1.11` |
| `worker2` | `192.168.1.12` |

On each PC, identify its active LAN address:

```bash
hostname
hostname -I
ip -4 -brief address
ip route
```

Do not copy the example addresses blindly. Record the actual three addresses.
All three addresses must be distinct private IPv4 addresses. The preparation
script checks that the address assigned to the current PC matches its selected
role.

Avoid guest Wi-Fi/client isolation. The master must reach both workers by SSH,
and all nodes must communicate with the other cluster nodes for HDFS, YARN and
Spark.

---

## 5. Put the same project snapshot on all three PCs

Place the project directory at `~/cinescope` on each PC, using Git, SSH, or a
USB drive. Make sure the source tree is the same on all three machines. Do not
copy a partially modified project to one worker and a different version to the
other.

The installation scripts deploy the project under:

```text
/opt/cinescope
```

Do not manually create HDFS directories or format HDFS during this step.

---

## 6. Install Java, Hadoop, Spark and Node.js

The current project pins this compatibility baseline:

| Software | Pinned version | Where it is installed |
|---|---:|---|
| Eclipse Temurin JDK | 11 | All three PCs |
| Apache Hadoop | 3.4.3 | All three PCs |
| Apache Spark | 3.5.9 | Master only |
| Node.js | 22.23.5 | Master only |

These are deliberate pinned versions for this project, not a claim that they
are the newest available releases. Hadoop 3.3+ supports Java 11 at runtime;
Spark 3.5.9 supports Java 11. Hadoop 3.5 and later requires JDK 17 server-side,
so upgrading to Hadoop 3.5.x requires a coordinated Java and application test.
Do not upgrade Hadoop, Spark and Java independently.

The installer downloads the official archives and verifies the published
SHA-512 checksums for Hadoop/Spark and SHA-256 checksum for Node.js. It uses
`/etc/cinescope/cluster.env` to tell CineScope which Java 11 installation to use
and restores any previously selected system `java`/`javac` alternatives.

On **master**:

```bash
cd ~/cinescope
sudo bash scripts/install-distributed-tools.sh master
```

On **worker1**:

```bash
cd ~/cinescope
sudo bash scripts/install-distributed-tools.sh worker1
```

On **worker2**:

```bash
cd ~/cinescope
sudo bash scripts/install-distributed-tools.sh worker2
```

The installer creates `/opt/hadoop` on every PC. It creates `/opt/spark` and
`/opt/node` only on `master`.

### Generate and commit the frontend lockfile on master

After installing Node.js on master, generate the lockfile from the pinned
`package.json`:

```bash
cd ~/cinescope/app/frontend
/opt/node/bin/npm install --package-lock-only --ignore-scripts --no-audit --no-fund
```

Confirm it exists:

```bash
test -s package-lock.json && echo "package-lock.json is ready"
```

Commit `app/frontend/package-lock.json` to Git and make that same file available
in `~/cinescope/app/frontend/` on both workers before running
`prepare-node.sh`. The preparation script uses `npm ci`, not an unconstrained
`npm install`, to make future frontend installs reproducible.

---

## 7. Prepare each physical computer

Run from the project root on each PC. Replace the three example addresses with
the actual addresses chosen in Section 4.

On master:

```bash
cd ~/cinescope
sudo bash scripts/prepare-node.sh master 192.168.1.10 192.168.1.11 192.168.1.12
```

On worker1:

```bash
cd ~/cinescope
sudo bash scripts/prepare-node.sh worker1 192.168.1.10 192.168.1.11 192.168.1.12
```

On worker2:

```bash
cd ~/cinescope
sudo bash scripts/prepare-node.sh worker2 192.168.1.10 192.168.1.11 192.168.1.12
```

The script sets the real hostname, maintains a tagged block in `/etc/hosts`,
creates the dedicated `hadoop` account and its SSH directory, creates the
local Hadoop storage/log directories, copies the project to `/opt/cinescope`,
and installs the authoritative Hadoop configuration on every PC. On master
it also installs Spark configuration, creates the Python virtual environment,
builds the React app, and enables `cinescope-api.service`.

The script intentionally refuses empty or malformed XML configuration and
requires `spark.master=yarn`, `spark.submit.deployMode=client`, and the pinned
Spark archive path. If it stops with a validation error, correct the source
files first; do not bypass the check.

Verify from each PC:

```bash
hostname -s
getent hosts master
getent hosts worker1
getent hosts worker2
```

Each hostname must resolve to the expected physical PC IP address.

---

## 8. Configure passwordless SSH from master to both workers

Hadoop's `start-dfs.sh` and `start-yarn.sh` use SSH to launch daemons on the
hosts listed in the Hadoop `workers` file. The master must SSH as `hadoop` to
both workers without interactive password entry. SSH host-key checking must
remain enabled.

On master, the preparation script has already created `/home/hadoop/.ssh`.
Generate an Ed25519 key only if it does not already exist:

```bash
sudo -u hadoop -H test -f /home/hadoop/.ssh/id_ed25519 || \
sudo -u hadoop -H ssh-keygen -t ed25519 -N '' -f /home/hadoop/.ssh/id_ed25519
```

Display the public key (copy the complete single line):

```bash
sudo cat /home/hadoop/.ssh/id_ed25519.pub
```

On **each worker**, create the `authorized_keys` file if it does not exist,
then edit it and paste the complete public key on its own line:

```bash
sudo touch /home/hadoop/.ssh/authorized_keys
sudo chown hadoop:hadoop /home/hadoop/.ssh/authorized_keys
sudo chmod 0600 /home/hadoop/.ssh/authorized_keys
sudo nano /home/hadoop/.ssh/authorized_keys
```

Do not delete existing authorized keys belonging to other legitimate users.
Do not copy the master's private key (`id_ed25519`) to either worker.

Before accepting an SSH host key for the first time, compare the fingerprint
shown by SSH with the worker's host-key fingerprint. On each worker, run:

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Then, from master, test both connections as the `hadoop` user:

```bash
sudo -u hadoop -H ssh worker1 hostname
sudo -u hadoop -H ssh worker2 hostname
```

Accept a host key only after verifying its fingerprint. Both commands must
complete without a password prompt and print the correct worker hostname.

---

## 9. Verify installed software and configuration

Run on each PC:

```bash
source /etc/cinescope/cluster.env
"$JAVA_HOME/bin/java" -version
/opt/hadoop/bin/hadoop version
```

On master additionally:

```bash
/opt/spark/bin/spark-submit --version
/opt/node/bin/node --version
/opt/node/bin/npm --version
```

Check the installed Hadoop workers file on master:

```bash
cat /opt/hadoop/etc/hadoop/workers
```

It must contain exactly:

```text
worker1
worker2
```

Check the Spark configuration on master:

```bash
grep -E '^(spark.master|spark.submit.deployMode|spark.yarn.archive)' \
    /opt/spark/conf/spark-defaults.conf
```

It must show YARN, client mode and the Spark 3.5.9 archive under
`/spark-archive/spark-libs-3.5.9.zip`.

---

## 10. Network firewall and security

First inspect the current firewall state on each computer:

```bash
sudo ufw status verbose
```

Do not run `ufw reset`. Do not enable a firewall over a remote SSH session
unless you have console access and have added the management-PC SSH rule first.
If you administer the PCs remotely, add the management-PC SSH rule before
enabling UFW. If you administer them locally, you can skip that rule.

Hadoop and Spark use fixed service ports plus additional service/container
ports. A fragile whitelist of only a few fixed ports can cause intermittent
shuffle, block-transfer or executor connectivity failures. On a trusted,
physically controlled LAN, a practical host-firewall approach is to allow
incoming traffic **from the other two cluster PCs only** on the cluster nodes.
That keeps the cluster peers connected without opening those services to the
whole internet.

If managing from a separate PC, first allow its actual IP to SSH on each
computer (replace `ADMIN_PC_IP`):

```bash
sudo ufw allow from ADMIN_PC_IP to any port 22 proto tcp
```

On master (replace values):

```bash
sudo ufw allow from 192.168.1.11 to any
sudo ufw allow from 192.168.1.12 to any
```

On worker1:

```bash
sudo ufw allow from 192.168.1.10 to any
sudo ufw allow from 192.168.1.12 to any
```

On worker2:

```bash
sudo ufw allow from 192.168.1.10 to any
sudo ufw allow from 192.168.1.11 to any
```

After adding the peer rules (and management SSH rule, if needed), enable the
firewall on each PC only if you intend to use UFW:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

If you browse the dashboard and Hadoop web interfaces from a separate admin
PC, add narrowly scoped rules for that PC's actual IP, for example:

```bash
sudo ufw allow from ADMIN_PC_IP to any port 8000 proto tcp
sudo ufw allow from ADMIN_PC_IP to any port 9870 proto tcp
sudo ufw allow from ADMIN_PC_IP to any port 8088 proto tcp
sudo ufw allow from ADMIN_PC_IP to any port 19888 proto tcp
sudo ufw allow from ADMIN_PC_IP to any port 18080 proto tcp
sudo ufw allow from ADMIN_PC_IP to any port 4040:4060 proto tcp
```

The main configured ports include:

| Service | Port | Machine |
|---|---:|---|
| SSH | 22 | all three PCs |
| NameNode RPC | 8020 | master |
| NameNode web UI | 9870 | master |
| SecondaryNameNode web UI | 9868 | master |
| DataNode HTTP | 9864 | worker1, worker2 |
| DataNode data transfer | 9866 | worker1, worker2 |
| DataNode IPC | 9867 | worker1, worker2 |
| ResourceManager web UI | 8088 | master |
| ResourceManager scheduler/resource tracker/client | 8030/8031/8032 | master |
| NodeManager web UI | 8042 | workers |
| MapReduce shuffle | 13562 | workers |
| JobHistory RPC/web UI | 10020/19888 | master |
| Spark driver RPC | 7078–7098 | master |
| Spark block manager | 7079–7099 | master and both workers |
| Spark application UI | 4040–4060 | master, if browser access is needed |
| Spark History UI | 18080 | master |
| CineScope API | 8000 | master |

The Spark port ranges account for the configured `spark.port.maxRetries=20`.
The block manager runs on both the driver and the executors; worker-to-worker
block-manager traffic is required. YARN and Hadoop can use additional ports
for containers and internal RPC, which is why the rules above allow full
peer-to-peer traffic only between the three trusted cluster PCs.

---

## 11. Initialize the new HDFS namespace — first deployment only

**This is destructive if an existing HDFS namespace is present.** The
formatting script refuses to proceed if the master NameNode directory or
either worker DataNode directory contains data, if a NameNode process is
running, or if explicit authorization is absent.

Only for a completely new physical cluster, run on master:

```bash
sudo -u hadoop -H env FORMAT_CINESCOPE_NAMENODE=YES \
    bash /opt/cinescope/scripts/format-namenode.sh
```

Do not copy an old container NameNode volume into this deployment. Do not run
this command during ordinary restarts. If an existing NameNode/DataNode
contains data, stop and inspect/backup the existing HDFS state; do not empty
storage directories just to make this check pass.

---

## 12. Start and verify the physical cluster

On master:

```bash
sudo -u hadoop -H bash /opt/cinescope/scripts/start-cluster.sh
```

The script starts HDFS, waits (with a timeout) for both physical DataNodes,
waits for HDFS safe mode to end, creates the required HDFS service directories,
starts YARN, and waits until the ResourceManager reports exactly one
`RUNNING` NodeManager for each of `worker1` and `worker2`. It then starts the
MapReduce and Spark History Servers.

Run the full check:

```bash
sudo -u hadoop -H bash /opt/cinescope/scripts/cluster-check.sh
```

The check must end with:

```text
CLUSTER CHECK PASSED
```

It checks the Java daemons on each physical computer, exactly two live HDFS
DataNodes, both expected YARN workers in `RUNNING` state, and the master HTTP
services. A final `PASSED` message is meaningful only if every individual
check also says `PASS`.

Useful browser interfaces on the trusted LAN:

- NameNode: `http://master:9870`
- ResourceManager: `http://master:8088`
- MapReduce JobHistory: `http://master:19888`
- Spark History: `http://master:18080`
- CineScope dashboard: `http://master:8000`

For additional process checks:

```bash
sudo -u hadoop -H bash -c \
    'source /etc/cinescope/cluster.env; "$JAVA_HOME/bin/jps" -l'
```

This reads the actual Java path installed for CineScope.

---

## 13. Run the MovieLens Small pipeline first

Do not begin with MovieLens 32M. First validate the full pipeline using
MovieLens Small.

On master:

```bash
sudo -u hadoop -H env DATASET=ml-latest-small \
    bash /opt/cinescope/app/scripts/run_pipeline.sh
```

The pipeline performs:

1. Spark JAR archive preparation in HDFS.
2. MovieLens Small download and local extraction on master.
3. Raw input upload into HDFS.
4. Spark cleaning and Parquet creation.
5. Spark genre scorecard aggregation.
6. Hadoop Streaming MapReduce genre aggregation.
7. Spark/MapReduce numerical comparison.
8. Spark analytical aggregations.
9. HDFS export of the large dashboard tables.

All Spark submissions explicitly use `--master yarn --deploy-mode client`.
The comparison step returns a failure status if any genre metric differs, so
the pipeline stops instead of printing `PIPELINE DONE` after a mismatch.

Check the validation JSON:

```bash
python3 -m json.tool /var/lib/cinescope/results/validation.json
```

It must contain:

```json
"match": true
```

Reload the API's cached results after a completed pipeline:

```bash
curl -fsS -X POST http://localhost:8000/api/reload
```

### Verify the work was actually distributed

Open the YARN ResourceManager UI and the Spark History Server. Inspect the
application's executor information and verify the executor hostnames. The
expected physical machines are `worker1` and `worker2`. Do not infer placement
from the requested executor count alone.

Inspect HDFS block replicas:

```bash
sudo -u hadoop -H /opt/hadoop/bin/hdfs fsck \
    /cinescope/raw/ratings/ratings.csv -files -blocks -locations
```

For the default replication factor of 2 and two live DataNodes, replicated
blocks should have replica locations on both physical DataNodes. Check the
actual output rather than assuming that a configuration value proves that
replication succeeded.

---

## 14. Run MovieLens 32M

Only after MovieLens Small completes and `validation.json` reports
`"match": true`, run:

```bash
sudo -u hadoop -H env DATASET=ml-32m \
    bash /opt/cinescope/app/scripts/run_pipeline.sh
```

Check the new validation file and reload API caches as described in Section
13. The loader replaces the shared HDFS raw/curated dataset paths, so do not
run two dataset pipelines concurrently.

Official dataset page and citation/license details:

- https://grouplens.org/datasets/movielens/32m/
- https://grouplens.org/datasets/movielens/

---

## 15. Performance benchmarks

Run benchmarks only after both YARN workers have been confirmed `RUNNING` and
a full pipeline has completed successfully.

For MovieLens Small:

```bash
sudo -u hadoop -H env DATASET=ml-latest-small \
    bash /opt/cinescope/app/scripts/bench.sh
```

For MovieLens 32M:

```bash
sudo -u hadoop -H env DATASET=ml-32m \
    bash /opt/cinescope/app/scripts/bench.sh
```

The 10× benchmark materializes a much larger HDFS input. With replication
factor 2, budget approximately twenty times the source ratings CSV size in
aggregate DataNode storage, in addition to the normal dataset and other HDFS
files. Check free disk space on both workers before running it.

The one-worker trials stop only the NodeManager on `worker2`; its HDFS DataNode
remains online. The script waits until YARN reports `worker1` as `RUNNING` and
`worker2` as non-running before the one-worker trials. It then restarts the
NodeManager and waits for **both** workers to be `RUNNING` again before
continuing. A cleanup trap attempts to restore worker2 if a benchmark command
fails or the script exits early.

The 10× input is stored under a dataset-specific path, so the MovieLens Small
benchmark cannot be reused accidentally for MovieLens 32M. Results are written
to:

```text
/var/lib/cinescope/results/benchmarks.json
```

---

## 16. Optional TMDB poster cache

Poster generation is optional and requires a TMDB read access token. Keep the
token out of Git and do not paste it into a source file.

Run on master, replacing the placeholder with the token:

```bash
sudo -u hadoop -H env \
    TMDB_API_READ_ACCESS_TOKEN='YOUR_TMDB_READ_ACCESS_TOKEN' \
    DATASET=ml-32m \
    /opt/cinescope/.venv/bin/python \
    /opt/cinescope/app/scripts/posters.py 6000
```

The cache is stored at:

```text
/var/lib/cinescope/results/posters.json
```

Reload the API cache after poster generation:

```bash
curl -fsS -X POST http://localhost:8000/api/reload
```

---

## 17. Start and stop after reboots

Start Hadoop and Spark from master:

```bash
sudo -u hadoop -H bash /opt/cinescope/scripts/start-cluster.sh
```

Stop Hadoop and Spark from master:

```bash
sudo -u hadoop -H bash /opt/cinescope/scripts/stop-cluster.sh
```

The FastAPI/dashboard service is managed separately by systemd:

```bash
sudo systemctl status cinescope-api.service
sudo systemctl start cinescope-api.service
sudo systemctl stop cinescope-api.service
sudo systemctl restart cinescope-api.service
sudo journalctl -u cinescope-api.service -f
```

The cluster daemons are not automatically started by this API service. Start
the Hadoop/Spark cluster explicitly after a reboot, then verify it.

---

## 18. Troubleshooting

### A worker is missing from HDFS

On master:

```bash
sudo -u hadoop -H /opt/hadoop/bin/hdfs dfsadmin -report
```

On the affected worker:

```bash
sudo -u hadoop -H /usr/bin/env bash -c 'source /etc/cinescope/cluster.env; "$JAVA_HOME/bin/jps" -l'
ls -lh /var/log/hadoop
```

Check hostname resolution and SSH:

```bash
getent hosts master worker1 worker2
sudo -u hadoop -H ssh worker1 hostname
sudo -u hadoop -H ssh worker2 hostname
```

### A worker is missing from YARN

On master:

```bash
sudo -u hadoop -H /opt/hadoop/bin/yarn node -list -all
```

On the affected worker, inspect `jps` and `/var/log/hadoop`. Check the
NodeManager local and log directories are owned by `hadoop` and that the
worker's configured YARN memory does not exceed its available physical RAM.

### Spark application stays ACCEPTED or executors fail to connect

Check:

- Both NodeManagers are `RUNNING`.
- YARN memory allocation fits the actual workers.
- The Spark archive exists and has replication 2:

```bash
sudo -u hadoop -H /opt/hadoop/bin/hdfs dfs -ls -l /spark-archive
sudo -u hadoop -H /opt/hadoop/bin/hdfs dfs -stat %r \
    /spark-archive/spark-libs-3.5.9.zip
```

- Workers resolve `master`, `worker1` and `worker2` to the correct IPs.
- Driver and block-manager traffic is allowed between all cluster PCs.
- `/usr/bin/python3` exists on both workers.

### API shows no analysis

```bash
ls -lh /var/lib/cinescope/results
curl -fsS -X POST http://localhost:8000/api/reload
sudo journalctl -u cinescope-api.service -f
```

### NameNode cannot start

Inspect:

```bash
ls -lah /var/lib/hadoop/namenode
ls -lah /var/log/hadoop
```

Do not format the NameNode as a routine troubleshooting action. Formatting
creates a new namespace and can make existing DataNode blocks inaccessible.

### Inspect listening ports

```bash
sudo ss -lntp
```

Do not solve connectivity problems by exposing the cluster to the public
internet or disabling SSH host-key verification.

---

## 19. Backup and data safety

Important master paths:

```text
/var/lib/hadoop/namenode
/var/lib/cinescope/raw
/var/lib/cinescope/results
```

Important worker paths:

```text
/var/lib/hadoop/datanode
```

Back up NameNode metadata and important HDFS data using a consistent HDFS
backup procedure. Do not copy a live NameNode directory as if it were an
ordinary file tree. Do not manually delete NameNode or DataNode directories
while daemons are running. The replication factor protects replicated HDFS
blocks from a single DataNode loss; it does not protect the NameNode metadata
from loss of the master.

---

## 20. Official references

- Apache Hadoop 3.4.3 Cluster Setup: https://hadoop.apache.org/docs/r3.4.3/hadoop-project-dist/hadoop-common/ClusterSetup.html
- Apache Hadoop 3.4.3 documentation: https://hadoop.apache.org/docs/r3.4.3/
- Apache Hadoop Java version compatibility: https://cwiki.apache.org/confluence/display/HADOOP/Hadoop+Java+Versions
- Apache Spark 3.5.9 on YARN: https://spark.apache.org/docs/3.5.9/running-on-yarn.html
- Apache Spark 3.5.9 configuration: https://spark.apache.org/docs/3.5.9/configuration.html
- Apache Spark 3.5.9 security/ports: https://spark.apache.org/docs/3.5.9/security.html
- Node.js 22.23.5 release and published checksums: https://nodejs.org/en/blog/release/v22.23.5/
- GroupLens MovieLens datasets: https://grouplens.org/datasets/movielens/
