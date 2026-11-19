# Reproducible environment for the pyuvm bench, regression, bug injection and
# synthesis: the same tool versions the published results were produced with.
# Works on Apple Silicon and Intel Macs (Docker Desktop, OrbStack or Colima).
#
#   docker build -t hbm3-mc .
#   docker run --rm -it -v "$PWD":/work hbm3-mc make test TEST=test_smoke
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        verilator yosys make g++ python3 python3-pip python3-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install "cocotb==1.9.2" "pyuvm==3.0.0"

WORKDIR /work
CMD ["bash"]
