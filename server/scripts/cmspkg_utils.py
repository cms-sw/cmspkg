from json import loads, dumps
from hashlib import sha256
from subprocess import getstatusoutput

CMS_GPG_SIGN = 'CMSPKG-METADATA-SIGNATURE-V1'

#Merge Two transactions
def merge_meta(bHash, uHash, nHash="", dryRun=False):
  data=loads(open(bHash).read())
  updates=loads(open(uHash).read())
  gpg = ("gpg" in updates) or ("gpg" in data)
  for k in ["gpg", "hash"]:
    data.pop(k, None)
    updates.pop(k, None)
  for pkg in updates:
    if not pkg in data:
      data[pkg]=updates[pkg]
    else:
      for revision in updates[pkg]: data[pkg][revision]=updates[pkg][revision]
  fix_cache(data, gpg)
  if not dryRun:
    if not nHash: nHash=bHash
    save_cache(data, nHash)
  return

def cache_data_pretty(cache):
  return dumps(cache,sort_keys=True,indent=2,separators=(',',': '))

def save_cache(cache, cfile):
  with open(cfile, 'w') as outfile:
    outfile.write(cache_data_pretty(cache))

def fix_cache(cache, gpg):
  cache.pop("hash", None)
  cache.pop("gpg", None)
  cache['hash'] = sha256(dumps(cache,sort_keys=True,separators=(',',': ')).encode()).hexdigest()
  res = True
  if gpg:
    err, out = getstatusoutput("echo -n '%s %s' | gpg --batch --yes --armor --detach-sign | base64 -w 0" % (CMS_GPG_SIGN, cache['hash']))
    if err:
      print("Failed GPG sign the cache", out)
      out = ""
      res = False
    cache['gpg'] = out
  return res
