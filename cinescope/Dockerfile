FROM node:22-bookworm AS frontend-build
WORKDIR /frontend
COPY app/frontend/package.json ./
RUN npm install --no-audit --no-fund
COPY app/frontend/ ./
RUN npm run build

FROM eclipse-temurin:11-jdk-jammy

ARG HADOOP_VERSION=3.4.3
ARG SPARK_VERSION=3.5.9

ENV HADOOP_HOME=/opt/hadoop \
    HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop \
    SPARK_HOME=/opt/spark \
    HADOOP_LOG_DIR=/var/log/hadoop \
    HADOOP_PID_DIR=/var/run/hadoop \
    PATH=/opt/hadoop/bin:/opt/hadoop/sbin:/opt/spark/bin:/opt/spark/sbin:${PATH} \
    PYSPARK_PYTHON=/usr/bin/python3

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl unzip zip python3 python3-pip procps netcat-openbsd ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system hadoop \
 && useradd --system --create-home --gid hadoop --shell /bin/bash hadoop \
 && pip3 install --no-cache-dir fastapi 'uvicorn[standard]' httpx pandas pyarrow

# The Apache projects publish SHA-512 files in two valid text formats:
#   SHA512 (archive.tar.gz) = <digest>   (Hadoop)
#   <digest>  archive.tgz                (Spark)
# Accept either published format, require exactly 128 hexadecimal characters,
# then verify before extracting. Never bypass this check.
RUN set -eux; \
    cd /tmp; \
    checksum_from_url() { \
      curl -fsSL "$1" | tr -d '\r' | sed -nE \
        -e 's/^SHA512[[:space:]]+\([^)]*\)[[:space:]]*=[[:space:]]*([[:xdigit:]]{128})[[:space:]]*$/\1/p' \
        -e 's/^([[:xdigit:]]{128})[[:space:]].*$/\1/p' | head -n 1; \
    }; \
    hadoop_url="https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz"; \
    curl -fsSLO "$hadoop_url"; \
    hadoop_sha="$(curl -fsSL "${hadoop_url}.sha512" | sed -nE 's/^SHA512 \([^)]*\) = ([[:xdigit:]]{128})$/\1/p')"; \
    test "${#hadoop_sha}" -eq 128; \
    printf '%s  %s\n' "$hadoop_sha" "hadoop-${HADOOP_VERSION}.tar.gz" | sha512sum -c -; \
    tar -xzf "hadoop-${HADOOP_VERSION}.tar.gz" -C /opt; \
    mv "/opt/hadoop-${HADOOP_VERSION}" /opt/hadoop; \
    spark_url="https://dlcdn.apache.org/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz"; \
    curl -fsSLO "$spark_url"; \
    spark_sha="$(checksum_from_url "${spark_url}.sha512")"; \
    test "${#spark_sha}" -eq 128; \
    printf '%s  %s\n' "$spark_sha" "spark-${SPARK_VERSION}-bin-hadoop3.tgz" | sha512sum -c -; \
    tar -xzf "spark-${SPARK_VERSION}-bin-hadoop3.tgz" -C /opt; \
    mv "/opt/spark-${SPARK_VERSION}-bin-hadoop3" /opt/spark; \
    rm -f /tmp/hadoop-* /tmp/spark-*; \
    mkdir -p /var/lib/hadoop/{namenode,datanode,tmp} /var/log/hadoop /var/run/hadoop /data/results; \
    chown -R hadoop:hadoop /var/lib/hadoop /var/log/hadoop /var/run/hadoop /data /opt/hadoop /opt/spark

COPY app/cluster/conf/ ${HADOOP_CONF_DIR}/
COPY app/cluster/spark-conf/ ${SPARK_HOME}/conf/
COPY app/cluster/entrypoint.sh /usr/local/bin/cinescope-entrypoint
COPY --from=frontend-build /frontend/dist /opt/cinescope-web

RUN chmod 0755 /usr/local/bin/cinescope-entrypoint \
 && chown -R hadoop:hadoop ${HADOOP_CONF_DIR} ${SPARK_HOME}/conf

WORKDIR /workspace
EXPOSE 8000 8088 9870 18080 19888
ENTRYPOINT ["/usr/local/bin/cinescope-entrypoint"]
CMD ["master"]
