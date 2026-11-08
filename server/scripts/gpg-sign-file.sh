#!/bin/bash -e
[ -e "$1" ] || exit 1
$(dirname $0)/gpg-signature.py $(sha256sum "$1" | cut -d' ' -f1)
