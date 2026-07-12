#!/usr/bin/env bash
# Shared exact-set coverage validator for triage-assess.yml (PR #456 round 2, researcher-requested): a
# confidently incomplete/corrupt model output is worse than none, so every model output that carries a
# per-ticket array — both blind assessments (Fable, Sol) and the sighted adjudication — is checked here,
# immediately after parsing and before anything downstream consumes it. Asserts the returned ticket-number
# set exactly equals the gathered packets set (no omissions, duplicates, or invented numbers); on any
# mismatch it fails loudly with the diff and the caller's `set -e` takes down the run before adjudication
# (or posting) ever starts.
#
# Usage: validate_coverage.sh <label> <packets_file> <output_file> <array_field>
#   label:        human-readable name for error messages, e.g. "Fable blind assessment"
#   packets_file: triage-packets.json (the gathered set of truth)
#   output_file:  the model output file to validate
#   array_field:  jq field holding the per-ticket array, e.g. ".assessments" or ".tickets"
set -euo pipefail

label="$1"
packets_file="$2"
output_file="$3"
array_field="$4"

gathered=$(jq -c '[.tickets[].number] | sort' "$packets_file")
returned_sorted=$(jq -c "[${array_field}[].number] | sort" "$output_file")
returned_unique=$(jq -c "[${array_field}[].number] | unique" "$output_file")

if [ "$returned_sorted" != "$returned_unique" ]; then
  echo "::error::${label} returned duplicate ticket numbers. returned=${returned_sorted}"
  exit 1
fi

if [ "$gathered" != "$returned_unique" ]; then
  missing=$(jq -nc --argjson g "$gathered" --argjson r "$returned_unique" '$g - $r')
  extra=$(jq -nc --argjson g "$gathered" --argjson r "$returned_unique" '$r - $g')
  echo "::error::${label} ticket-number set does not match the gathered set. missing=${missing} extra=${extra} gathered=${gathered} returned=${returned_unique}"
  exit 1
fi

echo "${label} covers all $(jq 'length' <<< "$gathered") gathered ticket(s) exactly, no duplicates/invented numbers"
