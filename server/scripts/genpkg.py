#!/usr/bin/env python3
from os import stat, environ
from sys import argv, exit
from os.path import exists, join
from glob import glob
import re
from cmspkg_utils import fix_cache, save_cache
from subprocess import getstatusoutput

ReRPM = None

def rpm2cmspkg(rpm):
  global ReRPM
  g,p,vx = rpm.split("+",2)
  m = ReRPM.match (vx)
  v = m.group(1)
  rev = m.group(3)
  pk = "+".join([g,p,v])
  return pk,rev

if len(argv)<2:
  print ("Error: Missing arguments\nUsage: "+argv[0]+" <RPMS-dir> [dir-with-md5cache-file]")
  exit(99)

basedir = argv[1]
chksum_dir  = basedir
if len(argv)>2: chksum_dir = argv[2]

RPMS_dir=join(basedir,"RPMS")
if not exists (RPMS_dir):
  print ("Error: No such directory %s" % RPMS_dir)
  exit(99)

chksums = {}
gpg = True if environ.get("PKG_GPG_SIGN", "false") == "true" else False
if exists (chksum_dir):
  err, out =  getstatusoutput("cat %s/*.md5cache" % chksum_dir)
  for line in out.split("\n"):
    items = line.split(" ")
    chksums [ items[0] ] = items[1]
  gpg = gpg or exists(join(chksum_dir, "gpg.txt"))

cache={}
arch=None
for r in glob(join(RPMS_dir,"*","*","*.rpm")):
  if not arch:
    arch = r.split(".")[-2]
    ReRPM = re.compile(r'(.+)[-]1[-]((1|\d+)(.%s|))\.%s\.rpm' % (arch,arch))
  items = r.split("/")
  rpm   = items[-1]
  rHash = items[-2]
  pack, rev = rpm2cmspkg(rpm)
  if pack not in cache: cache[pack]={}
  size = stat(r)[6]
  chksum = ""
  if rpm in chksums:
    chksum = chksums[rpm]
  else:
    print ("Running CHECKSUM : %s" % rpm)
    err, chksum = getstatusoutput("sha256sum %s |awk '{print \"sha256:\"$1}'" % r)
    if err: exit(1)
  deps = []
  dep_file = r[:-3]+"dep"
  if exists(dep_file):
    with open(dep_file) as ref:
      deps = [d for l in ref.readlines() for d in l.strip().split(" ") if d]
  cache[pack][rev] = [rHash, rpm, chksum, size, deps]

if not fix_cache(cache, gpg):
  exit(1)
save_cache(cache, RPMS_dir+".json")
