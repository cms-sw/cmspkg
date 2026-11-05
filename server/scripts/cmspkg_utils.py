from json import loads, dumps
from hashlib import sha256
from subprocess import getstatusoutput
import re

CMS_GPG_SIGN = 'CMSPKG-METADATA-SIGNATURE-V1'
ReSha256Hash = r'^([0-9a-f]{64})$'

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

def get_gpg_signature(sha256_hash):
  if not re.match(ReSha256Hash, sha256_hash): return ""
  err, gpg = getstatusoutput("echo -n '%s %s' | gpg --batch --yes --armor --detach-sign | base64 -w 0" % (CMS_GPG_SIGN, sha256_hash))
  if err:
    return ""
  return gpg

def fix_cache(cache, gpg):
  cache.pop("hash", None)
  cache.pop("gpg", None)
  cache['hash'] = sha256(dumps(cache,sort_keys=True,separators=(',',': ')).encode()).hexdigest()
  res = True
  if gpg:
    cache['gpg'] = get_gpg_signature(cache['hash'])
    if not cache['gpg']:
      res = False
  return res
