# syntax=docker/dockerfile:1.7
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# ci/Dockerfile - a Cloudberry that test/run/run.sh can drive.
#
# No published image carries an installed Cloudberry built from main, and the
# extension needs main: it is written against PostgreSQL 16, which the released
# 2.x line is not.  So this builds one, on top of the image Apache Cloudberry's
# own CI builds in, with that CI's own configure and build scripts - the same
# prefix and the same configure options as the cluster the suites were written
# against, without which the results would not be comparable.
#
# The source arrives as a named build context rather than a clone:
#
#   docker buildx build -f ci/Dockerfile \
#     --build-context cloudberry-src=<a checkout of apache/cloudberry> .
#
# That keeps the commit under the caller's control - the workflow pins it - and
# keeps the network out of the slowest layer.  Strip .git from the checkout
# first: Cloudberry's getversion asks git for a version when it can, and the
# answer should not depend on how the source was fetched.

FROM apache/incubator-cloudberry:cbdb-build-rocky9-latest

ARG RUST_VERSION=1.91.0
ARG PROTOC_VERSION=24.3

# Cloudberry: configure, build and install, then keep only the install and the
# gpdemo scripts.  It is one RUN with the source bind-mounted rather than
# copied, so neither the 500 MB of source nor the build tree ends up in a
# layer - the image is cached between CI runs, and the cache is finite.
#
# gpdemo goes to /home/gpadmin/demo because that is where the suites and the
# stability scripts read the cluster's data directories from; the cluster
# itself is created when a container starts (ci/start-cluster.sh), since
# gpinitsystem needs sshd and a build has neither.
#
# sudo, which the build scripts use throughout, was refused on the GitHub
# runner - "PAM account management error: Authentication service cannot
# retrieve authentication info" - for gpadmin, run directly or through su,
# while the same image built cleanly on a workstation.  pam_unix says that
# when it cannot read the user's shadow entry, and the image keeps
# /etc/shadow at mode 000, readable only through CAP_DAC_OVERRIDE.
#
# What the runner showed is narrower than "the capability is missing": a
# step run as root there had it (CapEff a80425fb) and read the file; sudo,
# raised to euid 0 from gpadmin through its setuid bit, could not.  Giving
# the owner read access fixed it, since a process with euid 0 is the owner
# and needs no capability for that.  Why a setuid escalation there comes
# without the capability is not established.  The lines below print what a
# step is granted and check sudo before the build depends on it, so that a
# change of base image that breaks this again says so at once.
USER root
RUN grep -E '^Cap(Eff|Bnd):' /proc/self/status \
 && if head -c0 /etc/shadow 2>/dev/null && grep -q '^gpadmin:' /etc/shadow 2>/dev/null; \
    then echo "root reads /etc/shadow, gpadmin entry present"; \
    else echo "root cannot read /etc/shadow at mode $(stat -c %a /etc/shadow)"; fi \
 && chmod 0400 /etc/shadow
USER gpadmin
RUN sudo -n true && echo "sudo works for gpadmin"

# The scripts log under build-logs/ and expect the caller to have made it, as
# Cloudberry's own workflow does before it calls them.  The build runs as
# gpadmin, the image's own user, and copies the source rather than
# preserving it, so gpadmin owns it without a chown.
USER gpadmin
WORKDIR /home/gpadmin
RUN --mount=type=bind,from=cloudberry-src,target=/mnt/cloudberry-src \
    cp -R /mnt/cloudberry-src /home/gpadmin/cloudberry \
 && export SRC_DIR=/home/gpadmin/cloudberry BUILD_DESTINATION=/usr/local/cloudberry-db \
 && cd "$SRC_DIR" \
 && mkdir -p build-logs/details \
 && ./devops/build/automation/cloudberry/scripts/configure-cloudberry.sh \
 && ./devops/build/automation/cloudberry/scripts/build-cloudberry.sh \
 && cp -R "$SRC_DIR/gpAux/gpdemo" /home/gpadmin/demo \
 && cd /home/gpadmin \
 && rm -rf "$SRC_DIR"

USER root
# protoc: Rocky 9's 3.14 refuses the substrait crate's protos ("proto3
# optional fields, but --experimental_allow_proto3_optional was not set").  The
# release archive also carries the well-known types under include/, which the
# distribution's protobuf-compiler alone does not.
RUN arch=$(uname -m) \
 && case "$arch" in x86_64) parch=x86_64 ;; aarch64) parch=aarch_64 ;; \
      *) echo "no protoc build for $arch" >&2; exit 1 ;; esac \
 && curl -fsSL --http1.1 --retry 5 --retry-all-errors -o /tmp/protoc.zip \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${parch}.zip" \
 && unzip -q -o /tmp/protoc.zip -d /usr/local bin/protoc 'include/*' \
 && rm /tmp/protoc.zip \
 && /usr/local/bin/protoc --version
ENV PROTOC=/usr/local/bin/protoc

# Rust for lance-c, at the version its Cargo.toml declares as rust-version.
USER gpadmin
WORKDIR /home/gpadmin
RUN curl -fsSL --http1.1 --retry 5 --retry-all-errors https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}" \
 && /home/gpadmin/.cargo/bin/rustc --version
ENV PATH=/home/gpadmin/.cargo/bin:$PATH
