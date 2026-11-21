#!/usr/bin/env bash
# Round-trip the SOPS-encrypted Home Assistant ConfigMaps to editable files.
#
#   hack/ha-config.sh unpack DIR   # decrypt to DIR/configuration.yaml + DIR/packages/*.yaml
#   hack/ha-config.sh pack DIR     # regenerate + re-encrypt both ConfigMaps from DIR
#
# Keep DIR outside the repo so plaintext never lands in the working tree.
set -euo pipefail

app=clusters/sno/applications/homeassistant
cmd=${1:?usage: $0 unpack|pack DIR}
dir=${2:?usage: $0 unpack|pack DIR}
cd "$(git rev-parse --show-toplevel)"

case "$(realpath -m "$dir")" in
"$PWD"/*) echo "refusing: $dir is inside the repo" >&2; exit 1 ;;
esac

case $cmd in
unpack)
	mkdir -p "$dir/packages"
	printf "%s\n" "$(sops -d "$app/config.yaml" | yq '.data["configuration.yaml"]')" >"$dir/configuration.yaml"
	plain=$(sops -d "$app/packages.yaml")
	for key in $(yq '.data | keys | .[]' <<<"$plain"); do
		printf "%s\n" "$(yq ".data[\"$key\"]" <<<"$plain")" >"$dir/packages/$key"
	done
	echo "unpacked to $dir"
	;;
pack)
	# Encrypt from stdin so plaintext is never written into the repo.
	encrypt() {
		local out=$1 tmp
		tmp=$(mktemp "$out.XXXXXX")
		yq 'del(.metadata.creationTimestamp)' |
			sops -e --input-type yaml --output-type yaml --filename-override "$out" /dev/stdin >"$tmp"
		mv "$tmp" "$out"
	}
	kubectl create configmap homeassistant-config \
		--from-file=configuration.yaml="$dir/configuration.yaml" \
		--dry-run=client -o yaml | encrypt "$app/config.yaml"
	args=()
	for f in "$dir"/packages/*.yaml; do args+=("--from-file=$(basename "$f")=$f"); done
	kubectl create configmap homeassistant-packages "${args[@]}" \
		--dry-run=client -o yaml | encrypt "$app/packages.yaml"
	echo "packed and encrypted $app/{config,packages}.yaml"
	;;
*)
	echo "usage: $0 unpack|pack DIR" >&2
	exit 1
	;;
esac
