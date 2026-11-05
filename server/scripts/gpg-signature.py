#!/usr/bin/env python3
from cmspkg_utils import get_gpg_signature
from sys import argv, exit
gpg=get_gpg_signature(argv[1])
if not gpg:
  exit(1)
print(gpg)
