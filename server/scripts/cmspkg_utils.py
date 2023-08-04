from json import loads, dumps
from hashlib import sha256

#Merge Two transactions
def merge_meta(bHash, uHash, nHash="", dryRun=False):
  data=loads(open(bHash).read())
  updates=loads(open(uHash).read())
  for pkg in updates:
    if pkg == 'hash': continue
    if not pkg in data:
      data[pkg]=updates[pkg]
    else:
      for revision in updates[pkg]: data[pkg][revision]=updates[pkg][revision]
  data.pop('hash', None)
  data['hash'] = sha256(dumps(data,sort_keys=True,separators=(',',': ')).encode()).hexdigest()
  if not dryRun:
    if not nHash: nHash=bHash
    with open(nHash, 'w') as outfile:
      outfile.write(dumps(data,sort_keys=True,indent=2,separators=(',',': ')))
  return

