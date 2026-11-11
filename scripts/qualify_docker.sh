#!/bin/sh
# Source test/generator check in the explicitly prepared local Docker image.
set -eu
sdk_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${WEBMANIA_CONTRACT_SOURCE:?Set WEBMANIA_CONTRACT_SOURCE to the pinned OpenAPI repository}"
: "${WEBMANIA_PERL_IMAGE:=webmania-perl-controlled:5.36-alpha1}"
docker run --rm --network none --cpus 2 --memory 1024m \
  -v "$sdk_dir:/sdk:ro" -v "$WEBMANIA_CONTRACT_SOURCE:/contracts:ro" -w /sdk \
  "$WEBMANIA_PERL_IMAGE" sh -c 'python3 scripts/generate.py --source /contracts --check && prove -Ilib t/*.t'
