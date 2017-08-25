#!/usr/bin/env python
from sys import argv, exit
from os import readlink, stat, utime, getpid
from os.path import exists, join, basename, dirname, abspath
from glob import glob
from time import time
from commands import getstatusoutput
from hashlib import sha256
from json import loads, dumps
import traceback, re
from cmspkg_utils import merge_meta
from pwd import getpwuid

#Format: Order list of repo where for each repo one should have a list with 3 items
#[ RepoNameTo Match, Days-to-keep, max-transactions-to-keep]
STASH_CONFIG = [
  ["^cms$",             30, 30],
  ["^cms[.]week[0-9]$",  7, 10],
  ["^cms[.].+$",         7, 10],
  ["^comp$",            30, 10],
  ["^comp[.]pre$",      30, 30],
  ["^comp[.]pre[.].+$",  7,  5],
  ["^.*$",               2,  5],
]

#Default upload transaction. This is available for all archs and can not be stashed/removed
DEFAULT_HASH = "0000000000000000000000000000000000000000000000000000000000000000"

#Repository owner
DEFAULT_REPO_OWNER = "cmsbuild"
REPO_OWNER = DEFAULT_REPO_OWNER

#Helper function to format a string
def format(s, **kwds): return s % kwds

#function to run system command under a user
def run_command(cmd, user=None):
  if user: cmd = "sudo -u %s /bin/bash -c '" % user + cmd.replace("'", "\'")+"'"
  return getstatusoutput(cmd)

#Cleanup in-active transactions
def cleanup_transactions(repo_dir, tmp_dir, delme_dir, dryRun=False, keep_threshhold_hours=24):
  for cfile in glob(join(repo_dir,"*","*","cleanup")):
    age = int((time()-stat(cfile)[8])/3600)
    tdir = dirname(cfile)
    print "Inactive Transaction %s: %s Hours (max: %s)" % (tdir, age, keep_threshhold_hours)
    if age < keep_threshhold_hours: continue
    print "  Deleting"
    items = tdir.split("/")
    delme_trans = join(delme_dir, items[-3], items[-2])
    if not dryRun:
      err, out = run_command("mkdir -p %s" % delme_trans)
      if err:
        print "Error: Unable to create directory %s: %s" % (delme_trans, out)
        continue
      err, out = run_command("mv %s %s" % (tdir, delme_trans))
      if err: print "Error: Unable to move transation: %s" % out
  return

#cleanup in-complete uploads in tmp directory
def cleanup_tmp_uploads(tmp_dir, delme_dir, dryRun=False, keep_threshhold_hours=8):
  for tdir in glob (join(tmp_dir,"tmp-*")):
    age = int((time()-stat(tdir)[8])/3600)
    if age < keep_threshhold_hours: continue
    print "Deleting tmp %s: %s(%s) Hours" % (tdir, age, keep_threshhold_hours)
    if not dryRun: run_command("mv %s %s" % (tdir, delme_dir))
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
    cmd = cmd + " && mkdir -p %(repo_dir)s/drivers && cp -rf %(hash_dir)s/drivers/%(arch)s-*.txt %(repo_dir)s/drivers/"
  err, out = run_command("find %s -maxdepth 1 -mindepth 1 -type f" % (repoInfo["hash_dir"]))
  if err:
    print out
    return False
  for common_file in out.split("\n"):
    if common_file.endswith("RPMS.json"): continue
    cmd = cmd + " && cp -rf "+common_file+" %(repo_dir)s/"
  default_meta = join(repoInfo["default_dir"],"RPMS.json")
  try:
    merge_meta (default_meta, join(repoInfo["hash_dir"],"RPMS.json"), default_meta+"-"+uHash, dryRun)
  except Exception, e:
    print e
    traceback.print_exc()
    return False
  cmd = format (cmd , **repoInfo)
  if not dryRun:
    err, out = run_command (cmd, REPO_OWNER)
    if err:
      print out
      run_command("rm -f %s-%s" % (default_meta, uHash))
      return False
  else:
    print cmd
  cmd = "mv %s-%s %s" % (default_meta, uHash, default_meta)
  cmd = cmd + " && chown %s: %s" % (REPO_OWNER, default_meta)
  if not dryRun:
    err, out = run_command (cmd)
    if err:
      print out
      return False
  else:
    print cmd
  history_dir = join(arch_dir, "history", uHash[0:2])
  cmd = "mkdir -p %s && cp -f %s/%s/RPMS.json %s/%s.json" % (history_dir, arch_dir, uHash, history_dir, uHash)
  if not dryRun:
    run_command(cmd, REPO_OWNER)
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
          run_command ("ln -nsf ../%s %s/%s/parent && touch %s/%s/cleanup" % (DEFAULT_HASH, arch_dir, nextChild, arch_dir, firstChild), REPO_OWNER)
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

  basedir = "/data/cmssw/repos"
  tmp_dir = join(basedir, "tmp")
  delme_dir = join(tmp_dir, "delete", "delme-%s" % getpid())
  if not dryRun:
    err, out = run_command("rm -rf %s; mkdir -p %s" % (delme_dir, delme_dir))
    if err:
      print out
      run_command("rm -rf %s/delete/*" % tmp_dir)
      exit(1)
  cleanup_tmp_uploads(tmp_dir, delme_dir, dryRun)
  for d in glob(join(basedir,"*", ".cmspkg-auto-cleanup")):
    repo_dir = dirname(d)
    try:
      REPO_OWNER = getpwuid(stat(d).st_uid).pw_name
    except KeyError, e:
      REPO_OWNER = DEFAULT_REPO_OWNER
      print "ERROR: Looks like owner does not exists any more:", str(e)
      print "       Changing default owner to :", REPO_OWNER
      err, out = run_command ("chown -R %s: %s" % (REPO_OWNER, repo_dir))
      if err:
        print "ERROR: Unable to change owner"
        print out
        continue
    repo_name = basename(repo_dir)
    for conf in STASH_CONFIG:
      if re.match(conf[0],repo_name):
        stashRepo(repo_dir, conf[1], conf[2], dryRun)
        cleanup_transactions(repo_dir, tmp_dir, delme_dir, dryRun)
        break
  if not dryRun: run_command("rm -rf %s/delete/*" % tmp_dir)
