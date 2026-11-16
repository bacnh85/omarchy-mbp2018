#!/bin/bash
# Runnable check for the one non-obvious thing in fix-fan-daemon.sh: detecting a
# *masked* unit.
#
# `systemctl is-enabled` prints "masked" but exits 1 for a masked unit, so under
# `set -o pipefail` the natural test
#
#     systemctl is-enabled X | grep -qx masked
#
# is ALWAYS false -- grep exits 0 but the pipeline takes systemctl's 1. That made
# `--revert` refuse to unmask anything and apply's "already masked" branch dead.
#
# Stubs `systemctl` on PATH (no root, no real unit) and asserts both branches of
# the script take the masked path. Run it after editing the script.

set -uo pipefail

script=$(dirname "$(readlink -f "$0")")/fix-fan-daemon.sh
[[ -f $script ]] || { echo "FAIL: cannot find $script" >&2; exit 1; }

stub=$(mktemp -d) || exit 1
trap 'rm -rf "$stub"' EXIT
calls="$stub/calls"

# A `systemctl` that reports a masked unit the way the real one does: the string
# on stdout, exit status 1.
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
[[ -n ${CALLS:-} ]] && echo "systemctl $*" >> "$CALLS"
case "$1" in
is-enabled) echo masked; exit 1 ;;
*) exit 0 ;;
esac
EOF
chmod +x "$stub/systemctl"

# pkexec is what the script uses for root; make it a passthrough.
cat > "$stub/pkexec" <<'EOF'
#!/bin/bash
"$@"
EOF
chmod +x "$stub/pkexec"

fail=0
check() {
  local desc=$1 want=$2 got=$3
  if [[ $got == "$want" ]]; then
    printf 'ok   %s\n' "$desc"
  else
    printf 'FAIL %s\n       want: %s\n       got:  %s\n' "$desc" "$want" "$got" >&2
    fail=1
  fi
}

# --- apply: an already-masked unit must NOT be masked again -------------------
: > "$calls"
out=$(PATH="$stub:$PATH" CALLS="$calls" "$script" 2>&1)
check "apply detects an already-masked unit" \
  "yes" "$(grep -q 'Already masked' <<<"$out" && echo yes || echo no)"
check "apply does not re-mask" \
  "no" "$(grep -q 'systemctl mask' "$calls" && echo yes || echo no)"

# --- --revert: must unmask AND re-enable -------------------------------------
: > "$calls"
out=$(PATH="$stub:$PATH" CALLS="$calls" "$script" --revert 2>&1)
check "--revert unmask is called" \
  "yes" "$(grep -q 'systemctl unmask' "$calls" && echo yes || echo no)"
check "--revert enable --now is called" \
  "yes" "$(grep -q 'systemctl enable --now' "$calls" && echo yes || echo no)"
check "--revert reports success" \
  "yes" "$(grep -q 'Unmasked' <<<"$out" && echo yes || echo no)"

# --- the trap itself: prove the pipeline form is broken and ours is not -------
# Same stub, but called the naive way, must land in the else branch; called the
# way the script does it, must report masked. If someone rewrites the script's
# check back into a pipeline, this pair explains why that is wrong.
naive=$(PATH="$stub:$PATH" bash -c '
  set -o pipefail
  if systemctl is-enabled x | grep -qx masked; then echo masked; else echo else-branch; fi')
check "naive pipeline misdetects a masked unit (why the fix looks odd)" \
  "else-branch" "$naive"

fixed=$(PATH="$stub:$PATH" bash -c '
  s=$(systemctl is-enabled x 2>/dev/null || true)
  if [[ $s == masked ]]; then echo masked; else echo else-branch; fi')
check "capturing the string detects it" \
  "masked" "$fixed"

echo
if (( fail )); then
  echo "FAILED" >&2
  exit 1
fi
echo "all checks passed"
