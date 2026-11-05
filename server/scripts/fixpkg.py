#!/usr/bin/env python3
from sys import argv, stdout, exit
from json import load
from cmspkg_utils import fix_cache, cache_data_pretty

with open(argv[1]) as ref:
  cache = load(ref)
  if not fix_cache(cache, 'gpg' in cache):
    exit(1)
  stdout.write(cache_data_pretty(cache))
