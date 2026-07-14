#!/usr/bin/env bash
# Reconfigure the source-built PostgreSQL with Perl + Python and install the
# in-tree PL/Perl and PL/Python3 language modules (for benchmark comparison).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends libperl-dev python3-dev

cd /usr/local/src/postgresql
./configure --prefix=/usr/local/pgsql --enable-debug --enable-cassert \
  --with-openssl --with-icu --with-libxml --with-perl --with-python

# In-tree PLs: build and install just these two subtrees.
make -C src/pl/plperl -j"$(nproc)"
make -C src/pl/plperl install
make -C src/pl/plpython -j"$(nproc)"
make -C src/pl/plpython install

# Report what got installed.
ls -l /usr/local/pgsql/lib/plperl.so /usr/local/pgsql/lib/plpython3.so || true
echo PLS_BUILD_DONE
