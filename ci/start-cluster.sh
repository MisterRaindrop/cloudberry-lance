#!/usr/bin/env bash
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
# ci/start-cluster.sh - bring up the cluster test/run/run.sh expects.
#
# Run as gpadmin inside a container started from ci/Dockerfile with
# "-h cdw", once the image's own init script has started sshd.  It creates
# the gpdemo cluster in exactly the shape the suites and the stability scripts
# read literally: coordinator on 7000, primaries on 7002-7004, data
# directories under /home/gpadmin/demo/datadirs.  ORCA is turned off because
# the expected output is the planner's.
#
set -eo pipefail

say() { echo "start-cluster: $*"; }

# The cluster tools ssh to cdw.  init_system.sh, the image's command, starts
# sshd and finishes by writing known_hosts, so that file is the signal.
for _ in $(seq 1 60); do
	[ -s /home/gpadmin/.ssh/known_hosts ] && break
	sleep 1
done
[ -s /home/gpadmin/.ssh/known_hosts ] ||
	{ say "sshd did not come up within 60s" >&2; exit 1; }

# shellcheck disable=SC1091
source /usr/local/cloudberry-db/cloudberry-env.sh

# The suites were written against a cluster initialised under C.UTF-8, and
# some of their expected output is that locale's: ordering text by code point
# puts every non-ASCII value after 'z', a linguistic collation does not.  The
# image's environment says en_US.UTF-8, and initdb takes its locale from there.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

say "creating the gpdemo cluster under /home/gpadmin/demo/datadirs (locale $LC_ALL)"
cd /home/gpadmin/demo
# shellcheck disable=SC1091
source gpdemo-defaults.sh
./demo_cluster.sh >/tmp/demo_cluster.log 2>&1 ||
	{ tail -40 /tmp/demo_cluster.log >&2; say "demo_cluster.sh failed" >&2; exit 1; }
# shellcheck disable=SC1091
source gpdemo-env.sh

say "turning ORCA off"
gpconfig -c optimizer -v off >/dev/null
gpstop -u >/dev/null

up=$(psql -p 7000 -d postgres -Atc \
	"SELECT count(*) FROM gp_segment_configuration WHERE status = 'u'")
total=$(psql -p 7000 -d postgres -Atc "SELECT count(*) FROM gp_segment_configuration")
optimizer=$(psql -p 7000 -d postgres -Atc "SHOW optimizer")
collate=$(psql -p 7000 -d postgres -Atc \
	"SELECT datcollate FROM pg_database WHERE datname = 'template1'")
say "$up of $total segments up, optimizer=$optimizer, collation=$collate"
[ "$up" = "$total" ] && [ "$optimizer" = off ] && [ "$collate" = C.UTF-8 ] ||
	{ say "the cluster is not in the expected state" >&2; exit 1; }
