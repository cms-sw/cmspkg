#!/usr/bin/env python
from sys import argv,stdout
from hashlib import sha256
from json import dumps,load

with open(argv[1]) as ref:
  cache = load(ref)
  cache.pop("hash",None)
  cache['hash'] = sha256(dumps(cache,sort_keys=True,separators=(',',': '))).hexdigest()
  stdout.write(dumps(cache,sort_keys=True,indent=2,separators=(',',': ')))
