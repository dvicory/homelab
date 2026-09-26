# Usage: agenix-restart-guard NAME SECRET_PATH UNIT...
#
# Try-restart UNIT... only when the content of SECRET_PATH differs from the
# last content recorded for NAME.
#
# agenix re-creates every decrypted secret on every activation, so a path
# unit watching the secret fires even when its content is unchanged. This
# guard turns "the file was touched" into "the content changed".
#
# Stamps hold a SHA-256 of the secret and live in /run: secrets are
# re-decrypted and services start fresh at boot, so a baseline recorded at
# boot is correct, and hashes of secrets never reach persistent storage.

if [ "$#" -lt 3 ]; then
  echo "usage: agenix-restart-guard NAME SECRET_PATH UNIT..." >&2
  exit 64
fi

name="$1"
secret="$2"
shift 2

stamp_dir=/run/agenix-restart
stamp="$stamp_dir/$name.sha256"

umask 077
mkdir -p "$stamp_dir"

if [ ! -e "$secret" ]; then
  echo "agenix-restart: $secret does not exist; nothing to compare"
  exit 0
fi

read -r new _ < <(sha256sum "$secret")

if [ ! -e "$stamp" ]; then
  # No baseline yet. At boot the units start with this content, and on the
  # first run after the guard is deployed nothing proves a change.
  printf '%s\n' "$new" >"$stamp"
  echo "agenix-restart: recorded baseline for $name; not restarting"
  exit 0
fi

read -r old <"$stamp" || old=
if [ "$new" = "$old" ]; then
  echo "agenix-restart: $name content unchanged; not restarting $*"
  exit 0
fi

echo "agenix-restart: $name content changed; restarting $*"
systemctl try-restart "$@"
# Record the new content only after a successful restart, so a failed restart
# is retried on the next activation.
printf '%s\n' "$new" >"$stamp.new"
mv -f "$stamp.new" "$stamp"
