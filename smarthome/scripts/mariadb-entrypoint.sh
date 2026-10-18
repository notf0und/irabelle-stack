#!/bin/sh
# Start hook for the Home Assistant history database.
#
# The image tag follows MariaDB's latest release, so a container restart can
# cross a major version (12.2 -> 13.0, ...). Two things have to survive that:
#
#   * The legacy /var/lib/mysql/tc.log. It only exists for binary-log/2PC crash
#     recovery, and this stack runs with binary logging off — but when it is
#     left over from an older server, the new one refuses to open it:
#         [ERROR] Recovering after a crash using tc.log
#         [ERROR] Bad magic header in tc log
#         [ERROR] Can't init tc log ... Aborting
#     which is a restart loop, not an upgrade. There is nothing to recover here,
#     so drop it before the server looks at it.
#   * The system tables. MARIADB_AUTO_UPGRADE (set in compose.yml) makes the
#     image's own entrypoint run mariadb-upgrade while it holds the temporary
#     server, so the first start on a new major finishes the upgrade.
#
# Everything else (first-run initialization, the MARIADB_* environment, the
# temporary server, gosu) stays with the image's entrypoint.
set -eu

rm -f /var/lib/mysql/tc.log
exec docker-entrypoint.sh mariadbd
