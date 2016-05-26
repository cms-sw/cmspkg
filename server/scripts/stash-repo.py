#!/usr/bin/env python
from sys import argv, exit
from os import readlink, stat, utime
from os.path import exists, join, basename, dirname, abspath
from glob import glob
from time import time
from commands import getstatusoutput
from hashlib import sha256
from json import loads, dumps
import traceback, re

#Format: Order list of repo where for each repo once should have a list with 3 items
#[ RepoNameTo Match, Days-to-keep, max-transactions-to-keep]
STASH_CONFIG = [
  ["^cms$",             30, 30],
  ["^cms[.]week[0-9]$",  1, 10],
  ["^cms[.].+$",         7, 10],
  ["^comp$",            30, 10],
  ["^comp[.]pre$",      30, 30],
  ["^comp[.]pre[.].+$",  7,  5],
  ["^.*$",               2,  5],
]

#Default upload transaction. This is available for all archs and can not be stashed/removed
DEFAULT_HASH = "0000000000000000000000000000000000000000000000000000000000000000"

#Helper function to format a string
def format(s, **kwds): return s % kwds

#Merge Two transactions
def merge_meta(arch_dir, default, uHash, dryRun=False):
  data=loads(open(join(arch_dir,default,"RPMS.json")).read())
  updates=loads(open(join(arch_dir,uHash,"RPMS.json")).read())
  for pkg in updates:
    if pkg == 'hash': continue
    if not pkg in data:
      data[pkg]=updates[pkg]
    else:
      for revision in updates[pkg]: data[pkg][revision]=updates[pkg][revision]
  data.pop('hash', None)
  data['hash'] = sha256(dumps(data,sort_keys=True,separators=(',',': '))).hexdigest()
  if not dryRun:
    with open(join(arch_dir,default,"RPMS.json-"+uHash), 'w') as outfile:
      outfile.write(dumps(data,sort_keys=True,indent=2,separators=(',',': ')))
      outfile.close()
  return

#Starting from a upload transaction for an architecture, this function returns 
#All the parents reachable but not including DEFAULT_HASH
def getUploadChain(arch_dir, uHash):
  commits = []
  while uHash and (uHash != DEFAULT_HASH):
    hash_dir = join (arch_dir, uHash)
    st = stat(hash_dir)
    commits.append([uHash, st.st_mtime])
    parent = join (hash_dir, "parent")
    if exists (parent): uHash = basename(readlink(parent))
    else: uHash = ""
  return commits

def stashArch (repo_dir, arch, uHash, dryRun=False):
  if uHash==DEFAULT_HASH: return
  arch_dir = join(repo_dir, arch)
  repoInfo = {"hash_dir"    : join(arch_dir, uHash),
              "default_dir" : join(arch_dir, DEFAULT_HASH),
              "repo_dir"    : repo_dir,
              "arch"        : arch,
              "hash"        : uHash,
              "rsync"       : "rsync --chmod=a+rX -a --ignore-existing",
             }
  cmd = "%(rsync)s --link-dest %(hash_dir)s/RPMS/ %(hash_dir)s/RPMS/ %(default_dir)s/RPMS/"
  if exists (join(repoInfo["hash_dir"], "SOURCES", "cache")):
    cmd = cmd + " && mkdir -p %(repo_dir)s/SOURCES/cache"
    cmd = cmd + " && %(rsync)s --link-dest %(hash_dir)s/SOURCES/cache/ %(hash_dir)s/SOURCES/cache/ %(repo_dir)s/SOURCES/cache/"
    cmd = cmd + " && %(rsync)s --exclude cache %(hash_dir)s/SOURCES/ %(repo_dir)s/SOURCES/"
    cmd = cmd + " && rm -f %(repo_dir)s/SOURCES/links/%(arch)s-%(hash)s"
  if exists (join(repoInfo["hash_dir"], "WEB")):
    cmd = cmd + " && %(rsync)s --link-dest %(hash_dir)s/WEB/ %(hash_dir)s/WEB/ %(repo_dir)s/WEB/"
  if exists (join(repoInfo["hash_dir"], "drivers")):
    cmd = cmd + " && mkdir -p %(repo_dir)s/drivers && cp -rf %(hash_dir)s/drivers/%{arch}-*.txt %(repo_dir)s/drivers/"
  err, out = getstatusoutput("find %s -maxdepth 1 -mindepth 1 -type f" % (repoInfo["hash_dir"]))
  if err:
    print out
    return False
  for common_file in out.split("\n"):
    if common_file.endswith("RPMS.json"): continue
    cmd = cmd + " && cp -rf "+common_file+" %(repo_dir)s/"
  try:
    merge_meta (arch_dir, DEFAULT_HASH, uHash, dryRun)
  except Exception, e:
    print e
    traceback.print_exc()
    return False
  cmd = format (cmd , **repoInfo)
  new_meta = join(repoInfo["default_dir"],"RPMS.json")
  if not dryRun:
    err, out = getstatusoutput (cmd)
    if err:
      print out
      getstatusoutput("rm -f %s-%s" % (new_meta, uHash))
      return False
  else:
    print cmd
  cmd = "mv %s-%s %s" % (new_meta, uHash, new_meta)
  if not dryRun:
    err, out = getstatusoutput (cmd)
    if err:
      print out
      return False
  else:
    print cmd
  history_dir = join(arch_dir, "history", uHash[0:2])
  cmd = "mkdir -p %s && cp -f %s/%s/RPMS.json %s/%s.json" % (history_dir, arch_dir, uHash, history_dir, uHash)
  if not dryRun:
    getstatusoutput(cmd)
  else:
    print cmd
  return True
  
#This function looks for all the archs of a repo and stash the oldest transactions in to default
# - Only stash if total transaction f an arch are greater than max transactions
# - Only stash a transaction if it is older than days to keep
def stashRepo(repo_dir, days=7, max_trans=10, dryRun=False):
  if days<1: days=1
  if days>30: days=30
  if max_trans<1: max_trans=1
  if max_trans>50: max_trans=50
  keeptime = days * 86400
  has_error=False
  #Loop over all the archs of this repo
  repo = basename (repo_dir)
  print ">> Working on ",repo
  for arch_dir in glob (join(repo_dir,"*")):
    #Get the hash of latest transaction
    latest = join(arch_dir, "latest")
    if exists (latest):
      arch    = basename(arch_dir)
      print "  >> %s/%s" %(repo, arch)
      uHash   = readlink (latest)
      commits = getUploadChain (arch_dir, uHash)
      commits_count = len(commits)
      print "    Total transactions: %s (%s)" % (commits_count, max_trans)
      while commits_count>1:
        #Start with the first child of DEFAULT_HASH i.e. commits[-1]
        firstChild = commits[-1][0]
        dtime = int(time() - commits[-1][1])
        #we keep the transaction if it is newer than days and
        #total trans are less than max transactions to keep
        print "    Checking %s" % firstChild
        print "      Age (sec)   : %s (%s)" % (dtime, keeptime)
        print "      Transactions: %s (%s)" % (commits_count, max_trans)
        if (dtime<=keeptime) and (commits_count<=max_trans):
          print "    Keeping %s" % firstChild
          break
        print "    Stashing %s" % firstChild
        ret = stashArch(repo_dir, arch, firstChild, dryRun)
        if not ret:
          has_error=True
          break
        nextChild =  commits[-2][0]
        print "    Done %s" % firstChild
        if not dryRun:
          getstatusoutput ("ln -nsf ../%s %s/%s/parent && touch %s/%s/cleanup" % (DEFAULT_HASH, arch_dir, nextChild, arch_dir, firstChild))
          utime(join(arch_dir, nextChild), (commits[-2][1], commits[-2][1]))
        del commits[-1]
        commits_count = len(commits)
  return has_error
# ================================================================================
def usage():
  print "usage: ", basename(argv[0])," [-d|--dry-run] [-h|--help]"
  return

if __name__ == "__main__" :
  import getopt
  options = argv[1:]
  try:
    opts, args = getopt.getopt(options, 'hdt', ['help','dry-run'])
  except getopt.GetoptError:
    usage()
    exit(-2)

  dryRun = False
    
  for o, a in opts:
    if o in ('-h', '--help'):
      usage()
      exit(1)
    elif o in ('-d','--dry-run',):
      dryRun = True

  tmpDirs = {}
  basedir = "/data/cmssw/repos"
  for d in glob(join(basedir,"*", ".cmspkg-auto-cleanup")):
    repo_dir = dirname(d)
    repo_name = basename(repo_dir)
    for conf in STASH_CONFIG:
      if re.match(conf[0],repo_name):
        tmpDirs[abspath(repo_dir+"/../tmp")]=1
        stashRepo(repo_dir, conf[1], conf[2], dryRun)
        break
