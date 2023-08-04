#!/usr/bin/env python3
from os import stat
from sys import argv, exit
from os.path import exists, join
from glob import glob
from hashlib import sha256
import re
from json import dumps
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
md5dir  = basedir
if len(argv)>2: md5dir = argv[2]

RPMS_dir=join(basedir,"RPMS")
if not exists (RPMS_dir):
  print ("Error: No such directory %s" % RPMS_dir)
  exit(99)

md5sums = {}
if exists (md5dir):
  err, out =  getstatusoutput("cat %s/*.md5cache" % md5dir)
  for line in out.split("\n"):
    items = line.split(" ")
    md5sums [ items[0] ] = items[1]

cache={}
arch=None
for r in glob(join(RPMS_dir,"*","*","*.rpm")):
  if not arch:
    arch = r.split(".")[-2]
    ReRPM = re.compile('(.+)[-]1[-]((1|\d+)(.%s|))\.%s\.rpm' % (arch,arch))
  items = r.split("/")
  rpm   = items[-1]
  rHash = items[-2]
  pack, rev = rpm2cmspkg(rpm)
  if pack not in cache: cache[pack]={}
  size = stat(r)[6]
  md5sum = ""
  if rpm in md5sums:
    md5sum = md5sums[rpm]
  else:
    print ("Running MD5SUM : %s" % rpm)
    err, md5sum = getstatusoutput("md5sum %s | sed 's| .*||'" % r)
    if err: exit(1)
  deps = []
  dep_file = r[:-3]+"dep"
  if exists(dep_file):
    with open(dep_file) as ref:
      deps = [d for l in ref.readlines() for d in l.strip().split(" ") if d]
  cache[pack][rev] = [rHash, rpm, md5sum, size, deps]

cache['hash'] = sha256(dumps(cache,sort_keys=True,separators=(',',': ')).encode()).hexdigest()
with open(RPMS_dir+".json", 'w') as outfile:
  outfile.write(dumps(cache,sort_keys=True,indent=2,separators=(',',': ')))        
  outfile.close()

