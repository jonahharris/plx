#!/usr/bin/env bash
# Attempt to build the CommandPrompt native PL/PHP and PL/Ruby against PG 18.
# Records whether they build and, if so, leaves the .so for benchmarking.
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/pgsql/bin:$PATH
PGC=/usr/local/pgsql/bin/pg_config
apt-get install -y --no-install-recommends ruby-dev php-dev git build-essential >/dev/null 2>&1 || true

echo "===== PL/Ruby (commandprompt/plruby) ====="
rm -rf /root/plruby_cp
if git clone --depth 1 https://github.com/commandprompt/plruby /root/plruby_cp 2>&1 | tail -2; then
  cd /root/plruby_cp
  ls
  ( ruby extconf.rb --with-pg-config="$PGC" && make ) 2>&1 | tail -30
  echo "PLRUBY_EXIT=${PIPESTATUS:-?}"
fi

echo
echo "===== PL/PHP (commandprompt/PL-php) ====="
rm -rf /root/plphp_cp
if git clone --depth 1 https://github.com/commandprompt/PL-php /root/plphp_cp 2>&1 | tail -2; then
  cd /root/plphp_cp
  ls
  php-config --version 2>&1 | head -1
  ( ./configure --with-postgres=/usr/local/pgsql --with-php=/usr/bin/php-config 2>&1 || \
    make USE_PGXS=1 PG_CONFIG="$PGC" 2>&1 ) | tail -30
  echo "PLPHP_EXIT=$?"
fi
echo NATIVE_ATTEMPT_DONE
