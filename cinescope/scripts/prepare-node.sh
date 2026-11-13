#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
MASTER_IP="${2:-}"
WORKER1_IP="${3:-}"
WORKER2_IP="${4:-}"

if (( EUID != 0 )); then
    echo "Run this script with sudo." >&2
    exit 1
fi

case "$ROLE" in
    master|worker1|worker2) ;;
    *)
        echo "Usage: sudo bash scripts/prepare-node.sh ROLE MASTER_IP WORKER1_IP WORKER2_IP" >&2
        exit 2
        ;;
esac

if [[ -z "$MASTER_IP" || -z "$WORKER1_IP" || -z "$WORKER2_IP" ]]; then
    echo "Supply all three physical LAN IPv4 addresses." >&2
    exit 2
fi

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="/opt/cinescope"
DATA_ROOT="/var/lib/cinescope"

# Validate that the addresses are distinct private IPv4 addresses and
# that the address assigned to this PC matches the selected role.
python3 - "$ROLE" "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP" <<'PY'
import ipaddress
import subprocess
import sys

role, *values = sys.argv[1:]
addresses = [ipaddress.ip_address(value) for value in values]

if any(address.version != 4 for address in addresses):
    raise SystemExit("This configuration currently expects IPv4 addresses.")
if len(set(addresses)) != 3:
    raise SystemExit("The three PC addresses must be different.")
if any(
    not address.is_private
    or address.is_loopback
    or address.is_multicast
    or address.is_unspecified
    or address.is_link_local
    or address.is_reserved
    for address in addresses
):
    raise SystemExit("Use three distinct, ordinary private LAN IPv4 addresses (not loopback, link-local or reserved).")

expected = dict(zip(("master", "worker1", "worker2"), values))[role]
result = subprocess.run(
    ["ip", "-o", "-4", "addr", "show"],
    check=True, capture_output=True, text=True,
)
assigned = {
    line.split()[3].split("/", 1)[0]
    for line in result.stdout.splitlines()
    if len(line.split()) >= 4
}
if expected not in assigned:
    raise SystemExit(
        f"{role} address {expected} is not assigned to this PC. "
        "Check the selected network interface and IP address."
    )
print(f"Validated {role} address: {expected}")
PY

# Validate the authoritative project configuration before touching the OS.
python3 - "$SOURCE_ROOT" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
hadoop = root / "config/hadoop"
spark = root / "config/spark"
required = [
    root / "app/api/main.py",
    root / "app/frontend/index.html",
    root / "app/frontend/package.json",
    root / "app/frontend/src/main.jsx",
    root / "app/frontend/src/styles.css",
    root / "app/frontend/src/assets/tmdb-logo.svg",
    root / "app/frontend/vite.config.js",
    root / "app/mr/mr_mapper.py",
    root / "app/mr/mr_combiner.py",
    root / "app/mr/mr_reducer.py",
    root / "app/spark/01_clean.py",
    root / "app/spark/02_genre_scorecard.py",
    root / "app/spark/03_analysis.py",
    root / "app/spark/bench_genre.py",
    root / "app/spark/common.py",
    root / "app/scripts/bench_log.py",
    root / "app/scripts/bench.sh",
    root / "app/scripts/compare.py",
    root / "app/scripts/ensure_spark_archive.sh",
    root / "app/scripts/export_results.sh",
    root / "app/scripts/load_hdfs.sh",
    root / "app/scripts/posters.py",
    root / "app/scripts/run_mr.sh",
    root / "app/scripts/run_pipeline.sh",
    root / "scripts/cluster-lib.sh",
    root / "scripts/start-cluster.sh",
    root / "scripts/stop-cluster.sh",
    root / "scripts/cluster-check.sh",
    root / "scripts/format-namenode.sh",
    root / "scripts/install-distributed-tools.sh",
    root / "scripts/prepare-node.sh",
    root / "deploy/cinescope-api.service",
    root / "requirements.txt",
]
missing = [str(path.relative_to(root)) for path in required if not path.is_file()]
if missing:
    raise SystemExit("Required project files are missing:\n  " + "\n  ".join(missing))

for filename in (
    "core-site.xml", "hdfs-site.xml", "yarn-site.xml",
    "mapred-site.xml", "capacity-scheduler.xml",
):
    path = hadoop / filename
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"Missing or empty Hadoop configuration: {path}")
    tree = ET.parse(path)
    if tree.getroot().tag != "configuration":
        raise SystemExit(f"Invalid Hadoop configuration root element: {path}")

for filename in ("spark-defaults.conf", "spark-env.sh"):
    path = spark / filename
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"Missing or empty Spark configuration: {path}")

spark_properties = {}
for raw_line in (spark / "spark-defaults.conf").read_text(encoding="utf-8").splitlines():
    line = raw_line.partition("#")[0].strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) == 2:
        spark_properties[parts[0]] = parts[1].strip()
if spark_properties.get("spark.master") != "yarn":
    raise SystemExit("config/spark/spark-defaults.conf must set spark.master to yarn.")
if spark_properties.get("spark.submit.deployMode") != "client":
    raise SystemExit("CineScope expects spark.submit.deployMode=client.")
if spark_properties.get("spark.yarn.archive") != "hdfs://master:8020/spark-archive/spark-libs-3.5.9.zip":
    raise SystemExit("spark.yarn.archive must match the pinned Spark 3.5.9 archive path.")

if not (root / "app/frontend/package-lock.json").is_file() and (root / "app/frontend/package.json").is_file():
    raise SystemExit("app/frontend/package-lock.json is missing. Generate it before preparing the master.")

workers = [line.strip() for line in (hadoop / "workers").read_text(encoding="utf-8").splitlines() if line.strip()]
if workers != ["worker1", "worker2"]:
    raise SystemExit("config/hadoop/workers must contain worker1 then worker2, one per line.")
print("Authoritative Hadoop and Spark configuration passed validation.")
PY

# Set the real host name.
hostnamectl set-hostname "$ROLE"

# Maintain only the tagged CineScope block in /etc/hosts.
python3 - "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP" <<'PY'
import os
import re
import tempfile
import sys
from pathlib import Path

master, worker1, worker2 = sys.argv[1:]
start = "# BEGIN CINESCOPE PHYSICAL CLUSTER"
end = "# END CINESCOPE PHYSICAL CLUSTER"
block = "\n".join((
    start,
    f"{master}\tmaster",
    f"{worker1}\tworker1",
    f"{worker2}\tworker2",
    end,
))
path = Path("/etc/hosts")
original = path.read_text(encoding="utf-8")
pattern = r"(?ms)^" + re.escape(start) + r"\n.*?^" + re.escape(end) + r"\n?"
updated = re.sub(pattern, "", original).rstrip() + "\n\n" + block + "\n"
stat = path.stat()
fd, temporary = tempfile.mkstemp(prefix=".hosts.", dir="/etc")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(updated)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, stat.st_mode)
    os.chown(temporary, stat.st_uid, stat.st_gid)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("Managed CineScope entries written to /etc/hosts.")
PY

# Create a dedicated non-login-by-password daemon account.
if ! getent group hadoop >/dev/null; then
    groupadd --system hadoop
fi
if ! id hadoop >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /home/hadoop \
        --shell /bin/bash --gid hadoop hadoop
fi

HADOOP_HOME_ACTUAL="$(getent passwd hadoop | cut -d: -f6)"
HADOOP_SHELL="$(getent passwd hadoop | cut -d: -f7)"
if [[ "$HADOOP_HOME_ACTUAL" != "/home/hadoop" || "$HADOOP_SHELL" != "/bin/bash" ]]; then
    echo "Existing hadoop account has an unexpected home or shell." >&2
    echo "Expected /home/hadoop and /bin/bash; inspect it manually." >&2
    exit 1
fi
if [[ "$(id -gn hadoop)" != "hadoop" ]]; then
    usermod --gid hadoop hadoop
fi

# A locked shadow entry can cause OpenSSH to reject the account even
# when public-key authentication is used. Assign an unguessable random
# password hash, discard the plaintext immediately, and use SSH keys.
PASSWORD_STATUS="$(passwd -S hadoop | awk '{print $2}')"
if [[ "$PASSWORD_STATUS" != "P" ]]; then
    RANDOM_PASSWORD="$(openssl rand -base64 48)"
    PASSWORD_HASH="$(printf '%s' "$RANDOM_PASSWORD" | openssl passwd -6 -stdin)"
    unset RANDOM_PASSWORD
    usermod --password "$PASSWORD_HASH" hadoop
    unset PASSWORD_HASH
fi

install -d -o hadoop -g hadoop -m 0750 /home/hadoop
install -d -o hadoop -g hadoop -m 0700 /home/hadoop/.ssh

# Local Hadoop directories. All are writable only by the daemon account.
install -d -o hadoop -g hadoop -m 0750 \
    /var/lib/hadoop/tmp \
    /var/lib/hadoop/pids \
    /var/lib/hadoop/yarn/local \
    /var/log/hadoop \
    /var/log/hadoop/yarn/container-logs

if [[ "$ROLE" == "master" ]]; then
    install -d -o hadoop -g hadoop -m 0750 \
        /var/lib/hadoop/namenode \
        "$DATA_ROOT/raw" \
        "$DATA_ROOT/results" \
        "$DATA_ROOT/downloads" \
        "$DATA_ROOT/frontend-build"
else
    install -d -o hadoop -g hadoop -m 0750 /var/lib/hadoop/datanode
fi

# Ensure the required Hadoop installation exists before copying config.
if [[ ! -x /opt/hadoop/bin/hadoop ]]; then
    echo "Hadoop is missing. Run install-distributed-tools.sh $ROLE first." >&2
    exit 1
fi
if [[ ! -f /etc/cinescope/cluster.env ]]; then
    echo "Java environment file is missing. Run install-distributed-tools.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source /etc/cinescope/cluster.env
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE 'version "11\.'; then
    echo "The configured CineScope Java runtime must be Java 11." >&2
    exit 1
fi

# Copy code; the physical config tree is the sole source of truth.
install -d -m 0755 "$PROJECT_ROOT"
rsync -a \
    --exclude='.git/' \
    --exclude='**/__pycache__/' \
    --exclude='**/*.pyc' \
    --exclude='**/node_modules/' \
    --exclude='**/.venv/' \
    --exclude='**/dist/' \
    --exclude='app/cluster/' \
    --exclude='data/' \
    "$SOURCE_ROOT/" "$PROJECT_ROOT/"
rm -rf -- "$PROJECT_ROOT/app/cluster"
chown -R root:hadoop "$PROJECT_ROOT"
find "$PROJECT_ROOT" -type d -exec chmod 0750 {} +
find "$PROJECT_ROOT" -type f -exec chmod 0640 {} +
chmod 0750 "$PROJECT_ROOT/scripts/"*.sh
chmod 0750 "$PROJECT_ROOT/app/scripts/"*.sh

# Install the same Hadoop configuration on every PC.
install -d -m 0755 /opt/hadoop/etc/hadoop
install -m 0644 "$PROJECT_ROOT/config/hadoop/"* /opt/hadoop/etc/hadoop/

# Recheck that the installed configuration is not empty or malformed.
python3 - <<'PY'
import xml.etree.ElementTree as ET
from pathlib import Path
base = Path('/opt/hadoop/etc/hadoop')
for name in ('core-site.xml', 'hdfs-site.xml', 'yarn-site.xml', 'mapred-site.xml', 'capacity-scheduler.xml'):
    path = base / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f'Installed Hadoop config is missing or empty: {path}')
    ET.parse(path)
PY

if [[ "$ROLE" == "master" ]]; then
    if [[ ! -x /opt/spark/bin/spark-submit || ! -x /opt/node/bin/npm ]]; then
        echo "Spark or Node.js is missing. Run the master installer first." >&2
        exit 1
    fi

    install -d -m 0755 /opt/spark/conf
    install -m 0644 "$PROJECT_ROOT/config/spark/"* /opt/spark/conf/
    if [[ ! -s /opt/spark/conf/spark-defaults.conf || ! -s /opt/spark/conf/spark-env.sh ]]; then
        echo "Installed Spark configuration is empty." >&2
        exit 1
    fi

    # The API environment is isolated from Ubuntu's externally-managed Python.
    install -d -o hadoop -g hadoop -m 0750 "$PROJECT_ROOT/.venv"
    chown -R hadoop:hadoop "$PROJECT_ROOT/.venv"
    if [[ ! -x "$PROJECT_ROOT/.venv/bin/python" ]]; then
        runuser -u hadoop -- python3 -m venv "$PROJECT_ROOT/.venv"
    fi
    runuser -u hadoop -- "$PROJECT_ROOT/.venv/bin/python" -m pip install --upgrade pip
    runuser -u hadoop -- "$PROJECT_ROOT/.venv/bin/python" -m pip install -r "$PROJECT_ROOT/requirements.txt"

    # Require a lockfile so future frontend installations are reproducible.
    if [[ ! -s "$PROJECT_ROOT/app/frontend/package-lock.json" ]]; then
        echo "app/frontend/package-lock.json is missing." >&2
        echo "On the source project run: /opt/node/bin/npm install --package-lock-only --ignore-scripts" >&2
        echo "Commit/copy package-lock.json, then rerun prepare-node.sh master." >&2
        exit 1
    fi

    BUILD_DIR="$(mktemp -d "$DATA_ROOT/frontend-build/build.XXXXXX")"
    chown hadoop:hadoop "$BUILD_DIR"
    cleanup_build() { rm -rf -- "${BUILD_DIR:-}"; }
    trap cleanup_build EXIT
    rsync -a "$PROJECT_ROOT/app/frontend/" "$BUILD_DIR/"
    runuser -u hadoop -- env HOME=/home/hadoop PATH="/opt/node/bin:/usr/local/bin:/usr/bin:/bin" \
        bash -c 'set -Eeuo pipefail; cd "$1"; npm ci --no-audit --no-fund; npm run build' _ "$BUILD_DIR"
    if [[ ! -s "$BUILD_DIR/dist/index.html" ]]; then
        echo "Frontend build did not produce dist/index.html." >&2
        exit 1
    fi

    install -d -o root -g hadoop -m 0750 "$PROJECT_ROOT/web"
    rsync -a --delete "$BUILD_DIR/dist/" "$PROJECT_ROOT/web/"
    chown -R root:hadoop "$PROJECT_ROOT/web"
    find "$PROJECT_ROOT/web" -type d -exec chmod 0750 {} +
    find "$PROJECT_ROOT/web" -type f -exec chmod 0640 {} +
    cleanup_build
    trap - EXIT

    install -m 0644 "$PROJECT_ROOT/deploy/cinescope-api.service" /etc/systemd/system/cinescope-api.service
    systemctl daemon-reload
    systemctl enable --now cinescope-api.service
fi

# Verify the host-file answers match the supplied LAN addresses.
python3 - "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP" <<'PY'
import socket
import sys
expected = dict(zip(('master', 'worker1', 'worker2'), sys.argv[1:]))
for host, address in expected.items():
    actual = socket.gethostbyname(host)
    if actual != address:
        raise SystemExit(f'{host} resolves to {actual}, expected {address}. Check earlier /etc/hosts entries.')
    print(f'{host} -> {actual}')
PY

echo
echo "=========================================="
echo "CineScope physical node prepared."
echo "Role: $ROLE"
echo "Hostname: $(hostname -f)"
echo "Project: $PROJECT_ROOT"
echo "=========================================="
if [[ "$ROLE" == "master" ]]; then
    systemctl --no-pager --full status cinescope-api.service || true
fi
