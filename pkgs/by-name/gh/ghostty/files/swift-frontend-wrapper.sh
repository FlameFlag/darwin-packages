#!/usr/bin/env bash
# Wrapper around swift-frontend that strips -external-plugin-path flags.
# The Swift driver adds these pointing to swift-plugin-server which doesn't
# exist in the nixpkgs SDK, causing the frontend to crash in the Nix sandbox.
#
# The raw swift-frontend path is passed via the GHOSTTY_RAW_SWIFT_FRONTEND
# env var.
filtered=()
skip_next=0
total=$#
plugin_count=0
for arg in "$@"; do
  if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
  if [ "$arg" = "-external-plugin-path" ]; then skip_next=1; plugin_count=$((plugin_count+1)); continue; fi
  filtered+=("$arg")
done
echo "swift-frontend-shim: filtered $plugin_count plugin paths from $total args, passing ${#filtered[@]} args" >&2
"$GHOSTTY_RAW_SWIFT_FRONTEND" "${filtered[@]}"
rc=$?
if [ $rc -ne 0 ]; then
  echo "swift-frontend-shim: FAILED with exit code $rc" >&2
  echo "swift-frontend-shim: first arg was: ${filtered[0]}" >&2
fi
exit $rc
