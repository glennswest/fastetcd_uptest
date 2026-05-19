#!/usr/bin/env bash
# Render the cloud-init templates for both variants and produce
# seed ISOs that Proxmox can attach. Output goes to build/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_cmd jq

# Prefer xorrisofs (works on macOS via homebrew); fall back to
# genisoimage (Linux). cloud-init seed ISOs need ISO 9660 + Joliet.
ISO_TOOL=""
if command -v xorrisofs >/dev/null 2>&1; then
    ISO_TOOL=xorrisofs
elif command -v genisoimage >/dev/null 2>&1; then
    ISO_TOOL=genisoimage
elif command -v mkisofs >/dev/null 2>&1; then
    ISO_TOOL=mkisofs
else
    echo "need one of: xorrisofs / genisoimage / mkisofs" >&2
    exit 3
fi

BUILD="${REPO_ROOT}/build"
mkdir -p "${BUILD}"

render() {
    local variant="$1"
    local dst="${BUILD}/${variant}"
    mkdir -p "${dst}"
    # Replace ${...} placeholders in the template with values from
    # our config.env. Use envsubst so we don't accidentally drop
    # literal `${...}` strings that should pass through.
    cat "${REPO_ROOT}/cloud-init/${variant}.yaml.tpl" \
        | envsubst '${K8S_VERSION} ${K8S_MINOR} ${POD_CIDR} ${SERVICE_CIDR} ${FASTETCD_IMAGE} ${HOSTNAME}' \
        > "${dst}/user-data"
    cp "${REPO_ROOT}/cloud-init/meta-data" "${dst}/meta-data"
    # cloud-init seed ISOs are tiny; volid must be cidata.
    "${ISO_TOOL}" -volid cidata -joliet -rock \
        -output "${dst}/seed.iso" \
        "${dst}/user-data" "${dst}/meta-data"
    echo "built ${dst}/seed.iso"
}

# Common HOSTNAME differs per variant.
HOSTNAME=upstream-a render variant-a
HOSTNAME=upstream-b render variant-b
