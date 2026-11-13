#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-}"
HADOOP_VERSION="3.4.3"
SPARK_VERSION="3.5.9"
NODE_VERSION="22.23.5"

if (( EUID != 0 )); then
    echo "Run this installer with sudo." >&2
    exit 1
fi

case "$ROLE" in
    master|worker1|worker2) ;;
    *)
        echo "Usage: sudo bash scripts/install-distributed-tools.sh master|worker1|worker2" >&2
        exit 2
        ;;
esac

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot identify the operating system." >&2
    exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "This installer is designed for Ubuntu. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
fi
if [[ "${VERSION_CODENAME:-}" != "noble" ]]; then
    echo "This project snapshot is validated for Ubuntu 24.04 LTS (Noble)." >&2
    echo "Detected: ${PRETTY_NAME:-unknown} (${VERSION_CODENAME:-unknown})." >&2
    echo "Do not continue on a different Ubuntu release without validating it first." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64)
        NODE_ARCH="x64"
        HADOOP_SUFFIX=""
        ;;
    aarch64|arm64)
        NODE_ARCH="arm64"
        HADOOP_SUFFIX="-aarch64"
        ;;
    *)
        echo "Unsupported CPU architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

apt-get update
apt-get install -y \
    ca-certificates curl wget gnupg openssl \
    unzip zip rsync \
    openssh-client openssh-server \
    procps net-tools dnsutils \
    python3 python3-venv python3-pip python3-dev

# Keep Java 11 for this Hadoop 3.4.3 / Spark 3.5.9 baseline.
# Remember any current system alternatives before installing Temurin;
# other applications on these PCs may rely on a different Java version.
PREVIOUS_JAVA=""
PREVIOUS_JAVAC=""
if command -v java >/dev/null 2>&1; then
    PREVIOUS_JAVA="$(readlink -f "$(command -v java)")"
fi
if command -v javac >/dev/null 2>&1; then
    PREVIOUS_JAVAC="$(readlink -f "$(command -v javac)")"
fi
install -d -m 0755 /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/adoptium.gpg ]]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public |
        gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
    chmod 0644 /etc/apt/keyrings/adoptium.gpg
fi
if [[ -z "${VERSION_CODENAME:-}" ]]; then
    echo "Ubuntu release codename was not found in /etc/os-release." >&2
    exit 1
fi
cat > /etc/apt/sources.list.d/adoptium.list <<EOF_ADOPTIUM
deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main
EOF_ADOPTIUM
apt-get update
apt-get install -y temurin-11-jdk

# Restore the user's pre-existing system-wide defaults. CineScope invokes
# its own Java 11 by JAVA_HOME; other software keeps its selected Java.
if [[ -n "$PREVIOUS_JAVA" ]] && update-alternatives --list java 2>/dev/null | grep -Fxq "$PREVIOUS_JAVA"; then
    update-alternatives --set java "$PREVIOUS_JAVA"
fi
if [[ -n "$PREVIOUS_JAVAC" ]] && update-alternatives --list javac 2>/dev/null | grep -Fxq "$PREVIOUS_JAVAC"; then
    update-alternatives --set javac "$PREVIOUS_JAVAC"
fi

JAVA_11_BIN="$(find /usr/lib/jvm -path '*/temurin-11-*/bin/java' -executable -print -quit 2>/dev/null || true)"
if [[ -z "$JAVA_11_BIN" || ! -x "$JAVA_11_BIN" ]]; then
    echo "Could not locate the Temurin 11 Java executable under /usr/lib/jvm." >&2
    echo "Inspect the installed package before continuing." >&2
    exit 1
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$JAVA_11_BIN")")")"
if ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE 'version "11\.'; then
    echo "The selected CineScope Java runtime is not Java 11." >&2
    exit 1
fi

install -d -m 0755 /etc/cinescope
ENV_TEMP="$(mktemp /etc/cinescope/cluster.env.XXXXXX)"
printf 'JAVA_HOME=%s\n' "$JAVA_HOME" > "$ENV_TEMP"
chown root:root "$ENV_TEMP"
chmod 0644 "$ENV_TEMP"
mv -f -- "$ENV_TEMP" /etc/cinescope/cluster.env

verify_sha512() {
    local archive="$1"
    local checksum_file="$2"
    local checksum
    checksum="$(awk 'match($0, /[[:xdigit:]]{128}/) {print substr($0, RSTART, RLENGTH); exit}' "$checksum_file")"
    if [[ "${#checksum}" -ne 128 ]]; then
        echo "Could not read a SHA-512 checksum for $archive." >&2
        return 1
    fi
    printf '%s  %s\n' "$checksum" "$archive" | sha512sum --check --status
}

check_managed_link() {
    local link="$1"
    local target="$2"
    if [[ -e "$link" && ! -L "$link" ]]; then
        echo "Refusing to replace a non-symlink at $link." >&2
        echo "Inspect and back it up manually before continuing." >&2
        exit 1
    fi
    if [[ -L "$link" ]]; then
        local actual
        actual="$(readlink -f "$link" || true)"
        if [[ "$actual" != "$target" ]]; then
            echo "Refusing to replace existing symlink $link -> $(readlink "$link")." >&2
            echo "Expected it to point to $target." >&2
            exit 1
        fi
    fi
}

install -d -m 0755 /opt

# Hadoop is installed on all three computers.
HADOOP_HOME="/opt/hadoop"
HADOOP_TARGET="/opt/hadoop-${HADOOP_VERSION}"
check_managed_link "$HADOOP_HOME" "$HADOOP_TARGET"
if [[ -e "$HADOOP_TARGET" && ! -x "$HADOOP_TARGET/bin/hadoop" ]]; then
    echo "An incomplete directory already exists at $HADOOP_TARGET." >&2
    echo "Inspect it; the installer will not delete it automatically." >&2
    exit 1
fi
if [[ ! -x "$HADOOP_TARGET/bin/hadoop" ]]; then
    TEMP_DIR="$(mktemp -d /tmp/cinescope-hadoop.XXXXXX)"
    trap 'rm -rf -- "${TEMP_DIR:-}"' EXIT
    HADOOP_ARCHIVE="hadoop-${HADOOP_VERSION}${HADOOP_SUFFIX}.tar.gz"
    HADOOP_URL="https://downloads.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_ARCHIVE}"
    echo "Downloading Apache Hadoop ${HADOOP_VERSION}."
    curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/$HADOOP_ARCHIVE" "$HADOOP_URL"
    curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/${HADOOP_ARCHIVE}.sha512" "${HADOOP_URL}.sha512"
    ( cd "$TEMP_DIR" && verify_sha512 "$HADOOP_ARCHIVE" "${HADOOP_ARCHIVE}.sha512" )
    tar -xzf "$TEMP_DIR/$HADOOP_ARCHIVE" -C "$TEMP_DIR"
    HADOOP_EXTRACTED="$TEMP_DIR/hadoop-${HADOOP_VERSION}"
    if [[ ! -x "$HADOOP_EXTRACTED/bin/hadoop" ]]; then
        echo "Hadoop archive did not contain the expected installation directory." >&2
        exit 1
    fi
    mv "$HADOOP_EXTRACTED" "$HADOOP_TARGET"
    rm -rf -- "$TEMP_DIR"
    trap - EXIT
fi
if [[ ! -L "$HADOOP_HOME" ]]; then
    ln -s "$HADOOP_TARGET" "$HADOOP_HOME"
fi

# Spark and Node.js are master-only.
SPARK_HOME="/opt/spark"
if [[ "$ROLE" == "master" ]]; then
    SPARK_TARGET="/opt/spark-${SPARK_VERSION}"
    check_managed_link "$SPARK_HOME" "$SPARK_TARGET"
    if [[ -e "$SPARK_TARGET" && ! -x "$SPARK_TARGET/bin/spark-submit" ]]; then
        echo "An incomplete directory already exists at $SPARK_TARGET." >&2
        echo "Inspect it; the installer will not delete it automatically." >&2
        exit 1
    fi
    if [[ ! -x "$SPARK_TARGET/bin/spark-submit" ]]; then
        TEMP_DIR="$(mktemp -d /tmp/cinescope-spark.XXXXXX)"
        trap 'rm -rf -- "${TEMP_DIR:-}"' EXIT
        SPARK_ARCHIVE="spark-${SPARK_VERSION}-bin-hadoop3.tgz"
        SPARK_URL="https://downloads.apache.org/spark/spark-${SPARK_VERSION}/${SPARK_ARCHIVE}"
        echo "Downloading Apache Spark ${SPARK_VERSION}."
        curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/$SPARK_ARCHIVE" "$SPARK_URL"
        curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/${SPARK_ARCHIVE}.sha512" "${SPARK_URL}.sha512"
        ( cd "$TEMP_DIR" && verify_sha512 "$SPARK_ARCHIVE" "${SPARK_ARCHIVE}.sha512" )
        tar -xzf "$TEMP_DIR/$SPARK_ARCHIVE" -C "$TEMP_DIR"
        SPARK_EXTRACTED="$TEMP_DIR/spark-${SPARK_VERSION}-bin-hadoop3"
        if [[ ! -x "$SPARK_EXTRACTED/bin/spark-submit" ]]; then
            echo "Spark archive did not contain the expected installation directory." >&2
            exit 1
        fi
        mv "$SPARK_EXTRACTED" "$SPARK_TARGET"
        rm -rf -- "$TEMP_DIR"
        trap - EXIT
    fi
    if [[ ! -L "$SPARK_HOME" ]]; then
        ln -s "$SPARK_TARGET" "$SPARK_HOME"
    fi

    NODE_HOME="/opt/node"
    NODE_TARGET="/opt/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
    check_managed_link "$NODE_HOME" "$NODE_TARGET"
    if [[ -e "$NODE_TARGET" && ! -x "$NODE_TARGET/bin/npm" ]]; then
        echo "An incomplete directory already exists at $NODE_TARGET." >&2
        echo "Inspect it; the installer will not delete it automatically." >&2
        exit 1
    fi
    if [[ ! -x "$NODE_TARGET/bin/npm" ]]; then
        TEMP_DIR="$(mktemp -d /tmp/cinescope-node.XXXXXX)"
        trap 'rm -rf -- "${TEMP_DIR:-}"' EXIT
        NODE_ARCHIVE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
        NODE_BASE="https://nodejs.org/dist/v${NODE_VERSION}"
        curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/$NODE_ARCHIVE" "${NODE_BASE}/${NODE_ARCHIVE}"
        curl -fL --retry 4 --retry-delay 2 -o "$TEMP_DIR/SHASUMS256.txt" "${NODE_BASE}/SHASUMS256.txt"
        NODE_SHA="$(awk -v file="$NODE_ARCHIVE" '$2 == file || $2 == "*" file {print $1; exit}' "$TEMP_DIR/SHASUMS256.txt")"
        if [[ "${#NODE_SHA}" -ne 64 ]]; then
            echo "Could not read a valid Node.js SHA-256 checksum." >&2
            exit 1
        fi
        printf '%s  %s\n' "$NODE_SHA" "$TEMP_DIR/$NODE_ARCHIVE" | sha256sum --check
        tar -xJf "$TEMP_DIR/$NODE_ARCHIVE" -C "$TEMP_DIR"
        NODE_EXTRACTED="$TEMP_DIR/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
        if [[ ! -x "$NODE_EXTRACTED/bin/npm" ]]; then
            echo "Node.js archive extraction failed." >&2
            exit 1
        fi
        mv "$NODE_EXTRACTED" "$NODE_TARGET"
        rm -rf -- "$TEMP_DIR"
        trap - EXIT
    fi
    if [[ ! -L "$NODE_HOME" ]]; then
        ln -s "$NODE_TARGET" "$NODE_HOME"
    fi
fi

systemctl enable --now ssh.service

# Capture the entire output first to avoid pipefail/SIGPIPE surprises.
HADOOP_VERSION_OUTPUT="$("$HADOOP_HOME/bin/hadoop" version 2>&1)"
printf '%s\n' "$HADOOP_VERSION_OUTPUT" | sed -n '1,3p'
if ! grep -Fq "Hadoop ${HADOOP_VERSION}" <<< "$HADOOP_VERSION_OUTPUT"; then
    echo "Installed Hadoop version does not match ${HADOOP_VERSION}." >&2
    exit 1
fi

if [[ "$ROLE" == "master" ]]; then
    SPARK_VERSION_OUTPUT="$("$SPARK_HOME/bin/spark-submit" --version 2>&1)"
    printf '%s\n' "$SPARK_VERSION_OUTPUT" | sed -n '1,8p'
    if ! grep -Fq "version ${SPARK_VERSION}" <<< "$SPARK_VERSION_OUTPUT"; then
        echo "Installed Spark version does not match ${SPARK_VERSION}." >&2
        exit 1
    fi
    printf 'Node.js: '
    "$NODE_HOME/bin/node" --version
    printf 'npm: '
    "$NODE_HOME/bin/npm" --version
    if [[ "$("$NODE_HOME/bin/node" --version)" != "v${NODE_VERSION}" ]]; then
        echo "Installed Node.js version does not match ${NODE_VERSION}." >&2
        exit 1
    fi
fi

echo
echo "Java selected for CineScope: $JAVA_HOME"
echo "Distributed tools installed successfully for role: $ROLE"
