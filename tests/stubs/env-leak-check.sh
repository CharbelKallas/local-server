# shellcheck shell=sh
# Sourced by the kubectl and helm stubs: logs an ENV_LEAK line for every
# credential found in the stub's own environment, i.e. exported to it by
# the script under test. The key lists come from scripts/lib.sh, so a key
# added there is checked automatically.
# shellcheck disable=SC2016  # expanded by that shell
leak_keys=$(sh -c '. "$1" && echo $DB_CREDENTIAL_KEYS $KARGO_CREDENTIAL_KEYS' \
  sh "$(dirname -- "$0")/../../scripts/lib.sh")
[ -n "$leak_keys" ] || echo "ENV_LEAK (could not read the credential keys from scripts/lib.sh)" >> "$STUB_LOG"
# Also recorded in $STUB_LEAK_LOG, which tests never truncate (STUB_LOG is
# often cleared mid-test).
for k in $leak_keys; do
  if eval "[ -n \"\${$k+set}\" ]"; then
    echo "ENV_LEAK $k" >> "$STUB_LOG"
    [ -z "${STUB_LEAK_LOG:-}" ] || echo "ENV_LEAK $k" >> "$STUB_LEAK_LOG"
  fi
done
