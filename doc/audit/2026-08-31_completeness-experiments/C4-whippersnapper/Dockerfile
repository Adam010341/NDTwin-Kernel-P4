# PREREG-C4 Whippersnapper period container — INSTALL-ONLY recon (R2)
#
# STATUS 2026-08-31: every step below has been made to complete, but NOT yet in
# one end-to-end image on this host — the local disk (5 GB free of 98 GB) could
# not hold the full build. Steps 1-16/20 completed in build 2 (bmv2 included,
# 145.9 s); steps 17-18/20 (pip, pktgen) were validated separately in throwaway
# containers. Run this file on nslab to produce the image. See RECON-R2-install.md.
# Mirrors p4benchmark/install_bmv2.sh (commit e1b22c1) section by section, in
# the script's order. Every departure from the script is tagged DEVIATION-n and
# documented in RECON-R2-install.md. No measurement is run in this image build.
#
# Base decision: ubuntu:16.04 (xenial). Probed 2026-08-31: archive.ubuntu.com
# STILL serves xenial, so no old-releases rewrite was needed (see RECON doc).
# The artifact's own CRAN line names "trusty" (14.04); 16.04 tried first per
# task instruction, 14.04 held as fallback (probed viable).
#
# [Co-developed with claude code -- Adam]

FROM ubuntu:16.04

ARG DEBIAN_FRONTEND=noninteractive
# Pins recorded at recon time (2026-08-31). p4benchmark HEAD = repo master.
ARG P4BENCH_COMMIT=e1b22c106c3458f757a362f57027670cee286c47

# DEVIATION-1 (container baseline): install_bmv2.sh assumes a full Ubuntu host
# that already has sudo/git/wget/gnupg/ca-certs and the repo checked out. The
# docker base image has none of these. This layer only fills that baseline gap.
RUN apt-get update && apt-get install -y sudo git wget ca-certificates gnupg

# Repo checkout (the script runs from inside an existing clone).
# DEVIATION-2 (pin): checkout pinned to the HEAD observed at recon time so the
# recipe stays byte-stable; upstream master == this commit on 2026-08-31.
RUN git clone https://github.com/usi-systems/p4benchmark.git /opt/p4benchmark \
    && cd /opt/p4benchmark && git checkout ${P4BENCH_COMMIT}
WORKDIR /opt/p4benchmark

# ---- install_bmv2.sh lines 5-7: CRAN repo + key ----
# DEVIATION-8 (spoofed short key ID): the script fetches the CRAN key by 32-bit
# short ID E084DAB9. In 2026 keyserver.ubuntu.com returns an evil32-style
# collision for that short ID — build 1 imported:
#   gpg: key E084DAB9: public key "Totally Legit Signing Key <mallory@example.org>" imported
# and apt then failed with NO_PUBKEY 51716619E084DAB9 / "unauthenticated
# packages". Fixed by fetching the key the script intended (Michael Rutter's
# CRAN Ubuntu key) by FULL fingerprint; repo line kept verbatim.
RUN sudo sh -c 'echo "deb http://cran.rstudio.com/bin/linux/ubuntu trusty/" >> /etc/apt/sources.list' \
    && gpg --keyserver keyserver.ubuntu.com --recv-key E298A3A825C0D65DFD57CBB651716619E084DAB9 \
    && gpg -a --export E298A3A825C0D65DFD57CBB651716619E084DAB9 | sudo apt-key add -

# ---- line 9 ----
RUN sudo apt-get update -y

# ---- line 12: R dependencies (verbatim) ----
RUN sudo apt-get -y install libcurl4-gnutls-dev libxml2-dev libssl-dev libcairo-dev

# ---- lines 15-16: behavioral-model dependencies (verbatim; mktemp exists in xenial) ----
RUN sudo apt-get install -y git autoconf python-pip build-essential python-dev \
    cmake libjudy-dev libgmp-dev libpcap-dev mktemp libffi-dev r-base gawk

# ---- lines 18-19: submodules (verbatim position; these are PINNED gitlinks) ----
# behavioral-model -> e182c0f1876541221fdeb27c596cc95d054b391f (tag 1.3.0, 2016-09-23)
# p4c-bm           -> a9edd780e39b5a6c834f05aac3f906e849ca5ad1 (2016-10-06)
RUN git submodule init && git submodule update

# ---- lines 22-24: thrift build deps (verbatim) ----
RUN sudo apt-get install -y libboost-dev libboost-test-dev libboost-program-options-dev \
    libboost-filesystem-dev libboost-thread-dev libevent-dev automake libtool \
    flex bison pkg-config g++ libssl-dev

# DEVIATION-3 (pip): stock xenial pip 8.1.1 predates Requires-Python metadata,
# so every unpinned `pip install` in the script now grabs py3-only releases and
# fails (probed 2026-08-31: cffi, nnpy, sphinx, sphinx-autobuild, thrift, scapy
# all fail verbatim; log in RECON doc). Bootstrap the LAST py2 pip (20.3.4),
# which honors Requires-Python and auto-selects py2-compatible versions, leaving
# every requirement line of theirs unmodified. Inserted before the script's
# first pip use (install-nnpy.sh).
RUN wget -q https://bootstrap.pypa.io/pip/2.7/get-pip.py -O /tmp/get-pip.py \
    && python2 /tmp/get-pip.py 'pip==20.3.4' && pip --version

# ---- lines 25-35: thrift 0.9.3 ----
# DEVIATION-4 (dead mirror): script wgets mirror.switch.ch which no longer
# resolves the path (probed: exit 8). Same tarball fetched from the canonical
# Apache archive instead. configure line and make -j2 kept verbatim.
RUN tmpdir=`mktemp -d -p .` && cd $tmpdir \
    && wget https://archive.apache.org/dist/thrift/0.9.3/thrift-0.9.3.tar.gz \
    && tar -xf thrift-0.9.3.tar.gz \
    && cd thrift-0.9.3 \
    && ./configure --with-cpp=yes --with-c_glib=no --with-java=no --with-ruby=no \
       --with-erlang=no --with-go=no --with-nodejs=no \
    && sudo make -j2 \
    && sudo make install \
    && cd ../.. && sudo rm -rf $tmpdir

# ---- lines 38-39: nanomsg via bmv2's own travis script (verbatim mechanism) ----
RUN tmpdir=`mktemp -d -p .` && cd $tmpdir \
    && bash ../behavioral-model/travis/install-nanomsg.sh \
    && sudo ldconfig \
    && cd .. && sudo rm -rf $tmpdir

# ---- line 42: nnpy via bmv2's travis script (verbatim; needs DEVIATION-3 pip) ----
RUN tmpdir=`mktemp -d -p .` && cd $tmpdir \
    && bash ../behavioral-model/travis/install-nnpy.sh \
    && cd .. && sudo rm -rf $tmpdir

# ---- lines 48-53: behavioral-model build ----
# The configure line below is the artifact's LIVE line (Arm S of the prereg).
# The commented line right above it in their script is Arm F:
#   #./configure --disable-logging-macros --disable-elogger CXXFLAGS=-O3
# DEVIATION-5 (parallelism only): script says bare `sudo make`; -j4 used per
# resource-courtesy cap. No configure/CXXFLAGS change.
RUN cd behavioral-model \
    && ./autogen.sh \
    && ./configure \
    && sudo make -j4

# ---- lines 55-58: p4c-bm (verbatim; p4-hlir comes from git master = floating) ----
RUN cd p4c-bm \
    && sudo pip install -r requirements.txt \
    && sudo pip install -r requirements_v1_1.txt \
    && sudo python setup.py install

# ---- line 61: top-level python requirements ----
# DEVIATION-9 (one pin, then their file verbatim): running their unmodified
# requirements.txt fails today because the unpinned `thrift` line resolves to a
# modern sdist whose build backend demands setuptools>=61.0, which does not
# exist for py2.7 (max 44.1.1). Build 2 verbatim:
#   ERROR: Could not find a version that satisfies the requirement setuptools>=61.0
#   ERROR: No matching distribution found for setuptools>=61.0
# `--no-build-isolation` alone does NOT fix it (probed: BackendUnavailable).
# Minimal fix: pre-install thrift pinned to 0.9.3 — the SAME version their own
# script builds from source at lines 25-35 — after which their requirements.txt
# runs verbatim and unmodified (validated: exit 0). Everything else stays
# unpinned and resolves to: scapy 2.5.0, sphinx 1.8.6, sphinx-autobuild 0.7.1,
# nose 1.3.7, nose-parameterized 0.6.0.
RUN sudo pip install --no-cache-dir 'thrift==0.9.3' \
    && sudo pip install -r requirements.txt

# DEVIATION-10 (undeclared dependency): benchmark/parse_results.py does
# `import numpy as np` (line 8) and emits avg/min/max/p95/p99/std/cv latency
# from it, but numpy appears in NO requirements file in the artifact. Verified
# missing after a faithful install: `ImportError: No module named numpy`.
# Pinned to the last py2 release. Needed only if the primary metric list draws
# on parse_results.py; harmless otherwise.
RUN sudo pip install --no-cache-dir 'numpy==1.16.6'

# DEVIATION-6 (runtime step deferred): line 62 `sudo ./veth_setup.sh` creates
# veth pairs — impossible in a docker build (no NET_ADMIN) and it is runtime
# environment setup, not installation. Run it inside the container at start:
#   docker run --cap-add=NET_ADMIN ... /opt/p4benchmark/veth_setup.sh
# (NOT run during this recon: install-only.)

# ---- lines 64-68: pktgen (verbatim) ----
RUN cd pktgen && mkdir -p build && cd build && cmake .. && make

# ---- lines 72-77: environment (bashrc append kept; ENV added for non-login shells) ----
RUN sh -c 'echo "export P4BENCHMARK_ROOT=/opt/p4benchmark" >> $HOME/.bashrc' \
    && sh -c 'echo "export PYTHONPATH=\$PYTHONPATH:/opt/p4benchmark" >> $HOME/.bashrc'
ENV P4BENCHMARK_ROOT=/opt/p4benchmark
ENV PYTHONPATH=/opt/p4benchmark

# ---- line 79 skipped: `sudo chown -R $USER:$USER /usr/local/lib/R` is a
# cosmetic ownership fix for their non-root user; as root it is a no-op and
# $USER is unset in docker builds. (DEVIATION-7, cosmetic) ----

# Enumeration snapshot (static identity data only — no measurement):
RUN { echo '== identity snapshot (install recon) =='; \
      date -u +%Y-%m-%dT%H:%M:%SZ; \
      gcc --version | head -1; \
      g++ --version | head -1; \
      thrift --version; \
      python2 --version 2>&1; \
      pip --version; \
      echo '-- p4benchmark commit --'; git -C /opt/p4benchmark rev-parse HEAD; \
      echo '-- bmv2 commit --'; git -C /opt/p4benchmark/behavioral-model rev-parse HEAD; \
      echo '-- p4c-bm commit --'; git -C /opt/p4benchmark/p4c-bm rev-parse HEAD; \
      echo '-- pip freeze --'; pip freeze 2>/dev/null; \
      echo '-- simple_switch binary --'; ls -la /opt/p4benchmark/behavioral-model/targets/simple_switch/ | head; \
      echo '-- sha256 --'; sha256sum /opt/p4benchmark/behavioral-model/targets/simple_switch/.libs/lt-simple_switch 2>/dev/null || sha256sum /opt/p4benchmark/behavioral-model/targets/simple_switch/simple_switch; \
    } | tee /opt/versions.txt

CMD ["/bin/bash"]
