# Analysis image for agent-written code in the sandbox (w2-sbx-image, D-025 option A; C4).
#
# Built by ACR Tasks (scripts/build-sandbox-image.sh build) FROM a copy of the Docker Official Image
# python:3.12-slim-bookworm imported into our own registry and referenced by digest, so the build doesn't depend on
# an outside registry and the base can't change under the same name.
#   Source: docker.io/library/python:3.12-slim-bookworm
#   Index digest (pinned): sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70 (2026-10-23)
#   linux/amd64 manifest: sha256:57d96f71de145a98e7ceca18ee4ade77bba4103a33a72dfaea026b23625c6bf0
#
# Two stages: numpy and pandas are installed with pip --require-hashes in the build stage; the runtime stage gets
# only the installed packages, has pip and ensurepip removed, and runs as a non-root user. Nothing can be installed
# at run time, and the sandbox's egress is default-deny anyway (D-025).
# No "# syntax=" line: that would pull a BuildKit frontend image from Docker Hub during the build.

# BASE_REPO is our ACR copy (<registry>.azurecr.io/base/python) for real builds; docker.io/library/python for a local
# test build only. The digest is the same either way.
ARG BASE_REPO
ARG BASE_DIGEST=sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70

FROM ${BASE_REPO}@${BASE_DIGEST} AS build
COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir --disable-pip-version-check --require-hashes --only-binary=:all: \
        --no-deps --target /opt/analysis -r /tmp/requirements.txt \
 && PYTHONPATH=/opt/analysis python -c "import numpy, pandas; print('import check: numpy', numpy.__version__, 'pandas', pandas.__version__)" \
 && echo "=== PYTHON PACKAGES (pip freeze) ===" \
 && python -m pip freeze --path /opt/analysis \
 && echo "=== END PYTHON PACKAGES ==="

FROM ${BASE_REPO}@${BASE_DIGEST} AS runtime
# Remove the package installer from the runtime: no pip, no ensurepip, no pip entry points.
RUN rm -rf /usr/local/lib/python3.12/site-packages/pip /usr/local/lib/python3.12/site-packages/pip-* \
        /usr/local/lib/python3.12/ensurepip /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.12 \
 && useradd --uid 10001 --create-home --shell /usr/sbin/nologin analysis \
 && echo "=== OS PACKAGES (dpkg-query) ===" \
 && dpkg-query -W -f='${binary:Package} ${Version}\n' \
 && echo "=== END OS PACKAGES ==="
COPY --from=build /opt/analysis /opt/analysis
ENV PYTHONPATH=/opt/analysis \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN python -c "import numpy, pandas" \
 && ! python -c "import pip" 2>/dev/null \
 && ! python -c "import ensurepip" 2>/dev/null \
 && echo "runtime check: numpy and pandas import; pip and ensurepip absent"
USER 10001
WORKDIR /home/analysis
CMD ["python3"]
