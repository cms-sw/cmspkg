#!/usr/bin/env python
from json import loads, dumps
from sys import argv
from hashlib import sha256

data=loads(open(argv[1]).read())
updates=loads(open(argv[2]).read())
for p in updates: data[p]=updates[p]
sr_sha = data.pop('hash', None)
data['hash'] = sha256(dumps(data,sort_keys=True,separators=(',',': '))).hexdigest()
print dumps(data,sort_keys=True,indent=2,separators=(',',': '))
