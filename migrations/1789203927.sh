echo "Install WasmEdge Agent as a lazy launcher"

# Somebody who removed the preinstalls does not get one back by updating. The
# command writes the launcher and installs nothing, so this costs one file write.
if [[ ! -f $HOME/.local/state/omarchy/preinstalls-removed ]]; then
  omarchy-install-wasmedge-agent || true
fi
