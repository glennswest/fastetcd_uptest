#!/usr/bin/env bash
# Clean teardown — removes DNS record + destroys the VM. Safe to
# call when the VM doesn't exist.
#
#   ./scripts/destroy-test.sh [--name=kubetest] [--vmid=113]
#                              [--keep-dns]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dns.sh
source "${HERE}/dns.sh"
# shellcheck source=vm.sh
source "${HERE}/vm.sh"

NAME="kubetest"
VMID="113"
KEEP_DNS=0
for arg in "$@"; do
    case "${arg}" in
        --name=*)    NAME="${arg#--name=}";;
        --vmid=*)    VMID="${arg#--vmid=}";;
        --keep-dns)  KEEP_DNS=1;;
        -h|--help)   grep -E '^#' "$0" | head -10; exit 0;;
        *) echo "unknown arg: ${arg}" >&2; exit 2;;
    esac
done

destroy_vm "${VMID}"
if (( KEEP_DNS == 0 )); then
    delete_a_record "${NAME}"
fi
ssh-keygen -R "${NAME}.g8.lo" >/dev/null 2>&1 || true
echo "teardown complete"
