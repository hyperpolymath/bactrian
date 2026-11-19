#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
doctor="$ROOT/scripts/bactrian/doctor.sh"
bash_cmd=$(command -v bash)

help_output=$(bash "$doctor" --help)
grep -q 'cannot establish a proof' <<<"$help_output"

# Control tools, pins, and implementation files independently of checkout readiness.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/bactrian" "$tmp/.machine_readable/bactrian" "$tmp/bin"
cp "$doctor" "$tmp/scripts/bactrian/doctor.sh"
fixture_doctor="$tmp/scripts/bactrian/doctor.sh"
lock="$tmp/.machine_readable/bactrian/authorities.lock"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/tool"
chmod +x "$tmp/bin/tool"
for tool in dune ocamlc why3 apalache idris2 zig dkcheck coqc lean echidna; do
  ln -s tool "$tmp/bin/$tool"
done
ln -s "$(command -v dirname)" "$tmp/bin/dirname"

# Synthetic format-valid pins, never used as provenance or proof evidence.
printf -v revision '%040d' 1
printf -v digest '%064d' 2
authorities=(MPR choreographic-types secret-types echo-types epistemic-types occupancy-types tropical-types ECHIDNA)
for name in "${authorities[@]}"; do
  printf '%s\t%s\t%s\n' "$name" "$revision" "$digest"
done >"$lock"
cp "$lock" "$tmp/valid.lock"

run_doctor() {
  local expected_status=$1 status
  shift
  if output=$(PATH="$tmp/bin" BACTRIAN_ECHIDNA_CMD=echidna "$bash_cmd" "$fixture_doctor" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'expected preflight exit %s, got %s\n%s\n' "$expected_status" "$status" "$output" >&2
    exit 1
  fi
}

run_doctor 2
grep -q 'Bactrian MVP preflight (not a proof check)' <<<"$output"
grep -q 'Canonical authority lock syntax' <<<"$output"
grep -q 'No verification or proof status was produced' <<<"$output"

run_doctor 64 --definitely-invalid

# Dune scaffolding alone must remain blocked even with all tools and pins present.
mkdir -p "$tmp/src/ppx" "$tmp/src/driver"
printf '(lang dune 3.0)\n' >"$tmp/dune-project"
printf '(library (name ppx))\n' >"$tmp/src/ppx/dune"
printf '(library (name driver))\n' >"$tmp/src/driver/dune"
run_doctor 2
grep -q 'src/ppx/firewall.ml absent or empty' <<<"$output"

modules=(src/core/ir.ml src/ppx/firewall.ml src/frontend/typed_ast.ml
  src/why3/translate.ml src/actors/protocol.ml src/abi/manifest.ml src/driver/status.ml)
for path in "${modules[@]}"; do
  mkdir -p "$tmp/$(dirname "$path")"
  printf 'let available = true\n' >"$tmp/$path"
done
run_doctor 0
grep -q 'Preflight READY:.*NOT verification and grants no proof status' <<<"$output"

# Each named module is required; an empty module must also block readiness.
for path in "${modules[@]}"; do
  mv "$tmp/$path" "$tmp/module.ml"
  run_doctor 2
  grep -Fq "$path absent or empty" <<<"$output"
  mv "$tmp/module.ml" "$tmp/$path"
done
: >"$tmp/src/driver/status.ml"
run_doctor 2
grep -q 'src/driver/status.ml absent or empty' <<<"$output"
printf 'let available = true\n' >"$tmp/src/driver/status.ml"

# Malformed MPR rows must fail shape validation before any pin-format checks.
for row in \
  "MPR" \
  $'MPR\t'"$revision" \
  $'\t'"$revision"$'\t'"$digest" \
  $'MPR\t\t'"$digest" \
  $'MPR\t'"$revision"$'\t' \
  $'MPR\t\t'"$revision"$'\t'"$digest" \
  $'MPR\t'"$revision"$'\t\t'"$digest" \
  $'MPR\t'"$revision"$'\t'"$digest"$'\t' \
  $'MPR\t'"$revision"$'\t'"$digest"$'\textra'; do
  grep -v '^MPR' "$tmp/valid.lock" >"$lock"
  printf '%s' "$row" >>"$lock" # Exercise the final row without a newline too.
  run_doctor 2
  grep -q 'malformed lock row (expected three nonempty TSV fields)' <<<"$output"
  if grep -q 'MPR pin fields populated' <<<"$output"; then
    printf 'malformed MPR row reached pin-format checks:\n%s\n' "$output" >&2
    exit 1
  fi
done

cp "$tmp/valid.lock" "$lock"
printf 'MPR\tUNPINNED\tUNPINNED\n' >>"$lock"
run_doctor 2
grep -q 'duplicate authority row: MPR' <<<"$output"

# Comments, blank lines, and a valid final row without a newline are permitted.
printf '# fixture lock\n\n' >"$lock"
grep -v '^MPR' "$tmp/valid.lock" >>"$lock"
printf 'MPR\t%s\t%s' "$revision" "$digest" >>"$lock"
run_doctor 0


# ECHIDNA coprocessor probe: an optional hint row that never changes the result.
# A fake echidna comes first on PATH; the fixture tools follow it.
real_timeout=$(command -v timeout || true) # Linked in only after the no-timeout case.
rm "$tmp/bin/echidna" # Each case below supplies its own fake, or none.
caps='{"schema":"echidna.coprocessor.capabilities/1"}'
good='{"schema":"echidna.coprocessor.result/1","status":"computed","outcome":{"BigInt":"6"},"proof":false}'

# Run doctor with a fake echidna. $1 is the fake's body, "none" for no echidna.
run_cop() {
  local body=$1 dir status
  if [[ "$body" == none ]]; then
    dir="$tmp/bin"
  else
    dir="$tmp/fake"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '#!/bin/sh\n%s\n' "$body" >"$dir/echidna"
    chmod +x "$dir/echidna"
    dir="$dir:$tmp/bin"
  fi
  if output=$(PATH="$dir" BACTRIAN_ECHIDNA_CMD="$tmp/bin/tool" "$bash_cmd" "$fixture_doctor" 2>&1); then
    status=0
  else
    status=$?
  fi
  cop_status=$status
  cop_row=$(grep 'ECHIDNA coprocessor' <<<"$output")
  without_row=$(grep -v 'ECHIDNA coprocessor' <<<"$output")
}
# A fake that answers per subcommand: $1 capabilities output, $2 dispatch output.
fake() {
  printf 'case "$2" in capabilities) %s;; dispatch) read -r _; %s;; *) exit 2;; esac' "$1" "$2"
}
require_row() { # $1 pattern that the row must match
  grep -Fq "[optional]" <<<"$cop_row" || { printf "row lacks [optional]:\n%s\n" "$cop_row" >&2; exit 1; }
  grep -Fq -- "$1" <<<"$cop_row" || { printf 'row lacks %s:\n%s\n' "$1" "$cop_row" >&2; exit 1; }
}
forbid_present() {
  if grep -Fq -e "[ready]" -e "[blocked]" <<<"$cop_row"; then
    printf "row uses a counted marker:\n%s\n" "$cop_row" >&2; exit 1
  fi
  if grep -q 'coprocessor present' <<<"$cop_row"; then
    printf 'must not be present:\n%s\n' "$cop_row" >&2; exit 1
  fi
}

# Baselines: the overall result without a coprocessor, ready and blocked.
run_cop none; require_row 'unavailable: no echidna on PATH'
ready_status=$cop_status; ready_rest=$without_row
[[ "$ready_status" -eq 0 ]]
mv "$tmp/src/driver/status.ml" "$tmp/module.ml"
run_cop none
blocked_status=$cop_status; blocked_rest=$without_row
[[ "$blocked_status" -eq 2 ]]
mv "$tmp/module.ml" "$tmp/src/driver/status.ml"

same_result() { # the row must change neither the exit code nor any other line
  run_cop "$1"
  [[ "$cop_status" -eq "$ready_status" && "$without_row" == "$ready_rest" ]] || { printf 'ready result changed:\n%s\n' "$output" >&2; exit 1; }
  mv "$tmp/src/driver/status.ml" "$tmp/module.ml"
  run_cop "$1"
  mv "$tmp/module.ml" "$tmp/src/driver/status.ml"
  [[ "$cop_status" -eq "$blocked_status" && "$without_row" == "$blocked_rest" ]] || { printf 'blocked result changed:\n%s\n' "$output" >&2; exit 1; }
  run_cop "$1"
}

# No timeout tool on PATH: the probe must not run, even with a fake echidna present.
marker="$tmp/echidna-called"
rm -f "$marker"
same_result "$(fake ": >\"$marker\"; printf '%s\\n' '$caps'" ": >\"$marker\"; printf '%s\\n' '$good'")"
require_row 'unavailable: no timeout tool, probe not run'; forbid_present
[[ ! -e "$marker" ]] || { printf 'the fake echidna was called without timeout\n' >&2; exit 1; }
if [[ -z "$real_timeout" ]]; then
  printf 'PASS (no timeout tool here: the timeout-dependent probe cases were skipped).\n'
  exit 0
fi
ln -s "$real_timeout" "$tmp/bin/timeout"

# (a) correct answers: present.
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '$good'")"
require_row '[optional]'; require_row 'coprocessor present'; require_row 'no proof status'
! grep -Fq -e "[ready]" -e "[blocked]" <<<"$cop_row"
# (b) no echidna: unavailable.
same_result none; require_row 'unavailable: no echidna on PATH'; forbid_present
# (c) echidna without the subcommand: unavailable, never present.
same_result 'echo "error: unrecognized subcommand" >&2; exit 2'
require_row 'unavailable: echidna has no coprocessor subcommand'; forbid_present
# (d) wrong schemas: drift.
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '${good/result\/1/result\/2}'")"
require_row 'drift: result schema'; forbid_present
same_result "$(fake "printf '%s\\n' '${caps/capabilities\/1/capabilities\/2}'" "printf '%s\\n' '$good'")"
require_row 'drift: capabilities schema'; forbid_present
# Wrong status, wrong outcome, non-zero exit on the request: never present.
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '${good/computed/refused}'")"
require_row 'drift: result status'; forbid_present
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '${good/\"6\"/\"7\"}'")"
require_row 'drift: gcd'; forbid_present
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '$good'; exit 1")"
require_row 'failed: dispatch exited 1'; forbid_present
# (e) "proof":true is never present, even when everything else is right.
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '${good/\"proof\":false/\"proof\":true}'")"
require_row 'drift: result claims "proof":true'; forbid_present
# (f) two stdout lines are never present.
same_result "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n%s\\n' '$good' '$good'")"
require_row 'failed: dispatch did not print exactly one line'; forbid_present
same_result "$(fake "printf '%s\\n%s\\n' '$caps' '$caps'" "printf '%s\\n' '$good'")"
require_row 'failed: capabilities did not print exactly one line'; forbid_present
# A present coprocessor never unblocks anything: BLOCKED output stays blocked.
mv "$tmp/src/driver/status.ml" "$tmp/module.ml"
run_cop "$(fake "printf '%s\\n' '$caps'" "printf '%s\\n' '$good'")"
mv "$tmp/module.ml" "$tmp/src/driver/status.ml"
[[ "$cop_status" -eq 2 ]]; require_row 'coprocessor present'
grep -q 'Preflight BLOCKED' <<<"$output"

printf 'PASS: Bactrian doctor checks controlled blocked/ready fixtures and rejects malformed locks.\n'
