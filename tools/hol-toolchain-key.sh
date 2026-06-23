#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 HOL_REV [stdknl|trknl]" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
poly=${HOLBUILD_POLY:-poly}
HOLBUILD_TOOLCHAIN_KEY_REV=$1 HOLBUILD_TOOLCHAIN_KERNEL_VARIANT=${2:-stdknl} exec "$poly" --script "$script_dir/hol-toolchain-key.sml"
