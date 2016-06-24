#!/usr/bin/env python
from commands import getstatusoutput
import sys, os, re, subprocess, urllib, threading
from os import getpid, getcwd
from time import sleep
from os.path import join, exists, abspath, dirname, basename
from glob import glob
try: import json
except:import simplejson as json

cmspkg_tag   = "V00-00-01"
cmspkg_cgi   = 'cgi-bin/cmspkg'
opts         = None
cache_dir    = None
pkgs_dir     = None
rpm_download = None
rpm_env      = None
rpm_partial  = "partial"
getcmd       = None
cmspkg_agent = "CMSPKG/1.0"
pkgs_to_keep = ["cms[+](local-cern-siteconf|afs-relocation-cern)[+]","external[+](apt|rpm)[+]","cms[+](cmspkg|cmssw|cmssw-patch|cms-common)[+]"]
getcmds = [ 
            ['curl','--version','--connect-timeout 60 --max-time 600 -L -q -f -s -H "Cache-Control: max-age=0" --user-agent "%s"' % (cmspkg_agent),"-o %s"],
            ['wget','--version','--timeout=600 -q --header="Cache-Control: max-age=0" --user-agent="%s" -O -' % (cmspkg_agent),"-O %s"],
          ]
try:
  script_path = __file__
except Exception, e :
  script_path = argv[0]
script_path = abspath(script_path)
#####################################
#Utility functions:
######################################
#Return a package name from a RPM File name
#RPM file name format: <group>+<pkg-name>+<pkg-version>-1-([0-9]+|<arch>).<arch>.rpm
#Returns: <group>+<pkg-name>+<pkg-version>
def rpm2package(rpm, arch):
  ReRPM = re.compile('(.+)[-]1[-]((1|\d+)(.%s|))\.%s\.rpm' % (arch,arch))
  g,p,vx = rpm.split("+",2)
  m = ReRPM.match (vx)
  v = m.group(1)
  r = m.group(3)
  return "+".join([g,p,v])

def print_msg(msg, type):
  for m in msg.split("\n"): print "[%s]: %s" % (type, m)

def get_cache_hash(cache):
  from hashlib import sha256
  return sha256(json.dumps(cache, sort_keys=True, separators=(',',': '))).hexdigest()

def save_cache(cache, cache_file):
  outfile = open(cache_file+"-tmp", 'w')
  if outfile:
    outfile.write(json.dumps(cache, indent=2,separators=(',',': ')))
    outfile.close()
  run_cmd("mv %s-tmp %s" %(cache_file, cache_file))

def newer_version(new_ver, prev_ver):
  return int(new_ver[1:].replace("-",""))>int(prev_ver[1:].replace("-",""))

#create package installation stamp file
def package_installed(package):
  pkg_file = join(pkgs_dir, package)
  if exists (pkg_file): return
  run_cmd("mkdir -p %s; touch %s" % (pkgs_dir, pkg_file))

#remove package installation stamp file
def package_removed(package):
  pkg_file = join(pkgs_dir, package)
  if exists (pkg_file):
    run_cmd("rm -f %s" % pkg_file)
  pkg_file = join(opts.install_prefix, opts.architecture, ".cmsdistrc", "PKG_"+package)
  if exists (pkg_file):
    run_cmd("rm -f %s" % pkg_file)

#get user response
def ask_user_to_continue(msg, exit=True):
  res = raw_input(msg)
  res = res.strip()
  if not res in ["y", "Y"]: sys.exit(0)

#Returns cmspkg url to access
def cmspkg_url(params):
  url = "http://%s/%s/%s?" % (opts.server, cmspkg_cgi, params['uri'])
  if opts.debug: url = url + "debug=1&"
  if opts.server_path: url = url + "repo_uri=%s&" % opts.server_path
  del params['uri']
  for p in params: url = url + p + "=" + str(params[p]) + "&"
  url=url[0:-1]
  if opts.debug: print "[DEBUG]: Accessing %s" % (url)
  return url

#Check server reply: print any debug/warning/error message
def check_server_reply(reply, exit=True):
  if 'debug'  in reply:
    print_msg(reply.pop('debug'), "DEBUG")
  if 'warning'  in reply:
    print_msg(reply['warning'],"WARN")
  if 'information'  in reply:
    print_msg(reply['information'],"INFO")
  if 'error' in reply:
    print_msg(reply['error'],"ERROR")
    if exit: sys.exit(1)
  return

#Use available command (curl or wget) to download url
def set_get_cmd():
  global getcmd
  if getcmd: return
  for cmd in getcmds:
    err, out = run_cmd("%s %s 2>&1 >/dev/null" %(cmd[0],cmd[1]),False,False)
    if not err:
      getcmd = cmd
      return
  print "Error: Unable to find any of the following commands. Please make sure you have any one of these installed."
  print " ","\n  ".join([x[0] for x in getcmds])
  sys.exit(1)

def fetch_url(data, outfile=None, debug=False):
  set_get_cmd ()
  url = cmspkg_url(data)
  cmd = [getcmd[0], getcmd[2]]
  if outfile: cmd.append(getcmd[3] % outfile)
  cmd.append('"'+url+'"')
  cmd_str = " ".join(cmd)
  return run_cmd(cmd_str, outdebug=debug)

#Run a shell command
def run_cmd (cmd,outdebug=False,exit=True):
  if opts.debug: print "[CMD]: ",cmd
  err, out = getstatusoutput(cmd)
  if err:
    if exit:
      print out
      sys.exit(1)
  elif outdebug:
    print out
  return err, out

#Get server cgi-path and repo path from url
def get_server_paths(server_url):
  items = server_url.strip("/").split("/")
  if len(items)==1: return items[0], "cmssw"
  set_get_cmd ()
  cmd = [getcmd[0], getcmd[2]]
  cgi_server = ""
  for subdir in items:
    if not subdir: continue
    cgi_server=join(cgi_server, subdir)
    url = "http://%s/%s?ping=1" % (cgi_server, cmspkg_cgi)
    cmd_str = " ".join(cmd)+' "'+url+'"'
    err, out = run_cmd(cmd_str, outdebug=opts.debug, exit=False)
    if err: continue
    if out == "CMSPKG OK": return cgi_server, join(*items[1:])
  print "Error: Unable to find /cgi-bin/cmspkg on %s" % server_url
  sys.exit(1)

def makedirs(path, force=False):
  if exists(path): return
  opt =''
  if force: opt='-p'
  run_cmd("mkdir %s %s" % (opt,path))
  return

#Varifies a file size and md5sums
def verify_download(ofile, size, md5sum):
  sinfo = os.stat(ofile)
  if sinfo[6] != size:
    print "Error: Download error: Size mismatch for %s (%s vs %s)." % (ofile, str(sinfo[6]), str(size))
    return False
  err, out = run_cmd("md5sum %s | sed 's| .*||'" % ofile)
  if out != md5sum:
    print "Error: Download error: Checksum mismatch for %s (%s vs %s)." % (package[1], out, md5sum)
    return False
  return True

#Download a packge from cmsrep. If package's size and mk5sums are not passed/available
#then first get this information from cmsrep so that download package can be varified
#After the successful download it puts the downlaod file in rpm_download directory
def download_rpm(package, tries=3):
  if (package[2]=="") or (package[3]==""):
    udata = {'uri':'RPMS/%s/%s/%s/%s' % (opts.repository, opts.architecture, package[0], urllib.quote(package[1])), 'ref_hash':package[-1]}
    if package[2]=="": udata["sha"]=1
    if package[3]=="": udata["size"]=1 
    err, out = fetch_url(udata)
    reply = json.loads(out)
    check_server_reply(reply)
    if 'sha' in udata:
      if not 'sha' in reply:
        print "Error: Server error: unable to find checksum of package: %s" % package[1]
        return False
      else:
        package[2] = reply['sha']
    if 'size' in udata:
      if not 'size' in reply:
        print "Error: Server error: unable to find size of package: %s" % package[1]
        return False
      else:
        package[3] = reply['size']

  ofile_tmp = join(rpm_download, rpm_partial, package[1])
  for i in range(tries):
    err, out = fetch_url({'uri':'RPMS/%s/%s/%s/%s' % (opts.repository, opts.architecture, package[0], urllib.quote(package[1])), 'ref_hash':package[-1]}, outfile=ofile_tmp)
    if not err: break
  if not exists(ofile_tmp):
    print "Error: Unable to download package: "+package[1]
    return False
  if not verify_download(ofile_tmp, package[3], package[2]): return False
  err, out = run_cmd("mv %s %s" % (ofile_tmp, join(rpm_download, package[1])))
  return not err

#Returns rpm dependencies using rpm -qp --requires command
def get_pkg_deps(rpm):
  cmd = "%s; rpm -qp --requires %s" % (rpm_env, join(rpm_download, rpm))
  err, out = run_cmd(cmd)
  deps = []
  ReReq = re.compile('^(cms|external|lcg)[+][^+]+[+].+')
  for line in out.split("\n"):
    line = line.strip()
    if ReReq.match(line):
      deps.append(line)
  return deps

def human_readable_size(size):
  schar = 'B'
  if size>1024:
    size = int(size/1024)
    schar = 'KB'
    if size>1024:
      size = int(size/1024)
      schar = 'MB'
  return str(size)+schar

#Download a package if not already downloaed
def download_package(package):
  if exists (join(rpm_download, package[1])): return
  try: download_rpm(package)
  except Exception, e: print "Error: Downloading RPMS: " + str(e)

###############################################
#End of Utility function
###############################################

###############################################
#A Lock class to create a lock using file system files
###############################################
class cmsLock (object):
  def __init__ (self, lock_dir):
    self.piddir  = join(lock_dir,".Lock")
    self.pidfile = join(self.piddir,"pid")
    self.pid     = str(getpid())
    self._hasLock = False
    self._hasLock = self._get()

  def __del__(self):
    self._release ()

  def __nonzero__(self):
    return self._hasLock

  def _isProcessRunning(self, pid):
    running = False
    try:
      os.kill(pid, 0)
      running = True
    except:
      pass
    return running

  def _release (self, force=False):
    if (self._hasLock or force):
      try:
        if exists (self.piddir): run_cmd ("rm -rf %s" % self.piddir)
      except:
        pass
    self._hasLock = False

  def _get(self, count=0):
    if count >= 5: return False
    pid = self._readPid()
    if pid:
      if pid == self.pid: return True
      if self._isProcessRunning(int(pid)): return False
    self._create()
    sleep(0.1)
    return self._get(count+1)

  def _readPid(self):
    pid = None
    try:
      pid = open(self.pidfile).readlines()[0]
    except:
      pid = None
    return pid

  def _create(self):
    self._release(True)
    try:
      err, out = getstatusoutput("mkdir %s" % self.piddir)
      if err:
         raise OSError("makedirs() failed (return: %s):\n%s" % (returncode, out))
      lock = open (self.pidfile, 'w')
      lock.write(self.pid)
      lock.close()
    except:
      pass

###############################################
#Class to read cmspkg caches
###############################################
#Each cache file name is consists of <repo>-<upload-hash>-<uniq-hash-based-on-timestatmp>
#Json format of cache file contains dictionary of packages where each package has dictionary of
#its rivisions e.g.
# "revision"=[ "pkg-md5sum" , "rpm-file-name", "md5sum-of-rpm-file", rpm-file-size, [list-of-any-extra-dependencies]]
class pkgCache (object):
  def __init__(self, readCaches=True):
    self.packs = {}
    self.active = {}
    self.readActive (readCaches)

  def readCache(self, rfile):
    pkgs = json.loads(open(cache_dir+"/"+rfile).read())
    pkgs.pop("hash",None)
    for pk in pkgs:
      if not pk in self.packs: self.packs[pk]={}
      for r in pkgs[pk]:
        if r in self.packs[pk]: continue
        self.packs[pk][r] = pkgs[pk][r]+[rfile.split("-")[1]]
    return

  def readActive(self, readCaches=True):
    activeFile = join(cache_dir, "active")
    if not exists (activeFile): return
    self.active = json.loads(open(activeFile).read())
    if readCaches:
      for c in self.active: self.readCache(c)
    return

###############################################
#Class to do Parallel downloads of packages
###############################################
class rpmDownloader:
  def __init__(self, parallel=4):
    self.parallel = parallel
    self.counter = 0
    self.lock = threading.Lock()

  def run(self, packages):
    total = len(packages)
    index = 0
    threads = []
    while(index < total):
      threads = [t for t in threads if t.is_alive()]
      if(len(threads) < self.parallel):
        package = packages[index]
        index += 1
        self.counter = self.counter + 1
        print "Get:%s http://%s cmssw/%s/%s %s" % (self.counter, opts.server, opts.repository, opts.architecture, package[1])
        try:
          t = threading.Thread(target=download_package, args=(package,))
          t.start()
          threads.append(t)
        except Exception, e:
          print "Error: Downloading RPMS: " + str(e)
          break
      else:
        sleep(0.1)
    for t in threads: t.join()
    if index != total: return False
    for package in packages:
      if not exists (join(rpm_download, package[1])): return False
    return True

###############################################
#cmspkg class for getting caches, and installing packages
###############################################
class CmsPkg:
  def __init__(self, jobs=4):
    self.rpm_cache = {}
    self.cache = None
    self.downloader = rpmDownloader(jobs)
    return

  #Read rpm database for locally installed RPMS
  def update_rpm_cache(self, force=False):
    if (not force) and self.rpm_cache: return
    self.rpm_cache.clear()
    err, out = run_cmd("%s; rpm -qa --queryformat '%%{NAME} %%{RELEASE}\n'" % rpm_env)
    for r in out.split("\n"):
      n, rv = r.split(" ")
      self.rpm_cache[n]=rv
    return

  #Read RPM database to get a package size
  def package_size(self, pkg):
    pkg_file = join(rpm_download, pkg)
    err, out = run_cmd("%s; rpm -qp --queryformat '%%{SIZE}' %s" % (rpm_env, pkg_file))
    st = os.stat(pkg_file)
    return st.st_size, int(out)

  #Download cmspkg caches from server. It is identical to "apt-get update"
  #It first fetches the list of all caches from server and then only download the new caches.
  #Note that the cache name include the timestamp of information. So if a cache was updated on server
  #then it will have a different timestamp which will force us to fetch it.
  def update(self, force=False, silent=False):
    if not silent: print "Updating cmspkg caches ..."
    #fetch list of all caches from cmspkg server
    err, out = fetch_url({'uri':'caches/%s/%s' % (opts.repository, opts.architecture)})
    caches = json.loads(out)
    check_server_reply(caches)
    if not 'caches' in caches:
      print "Error: Server error: No caches received from server"
      sys.exit(1)
    new_caches = []
    caches_added = 0
    caches_removed = 0
    if not silent:
      print "  Remote  caches:",len(caches['caches'])
      if force: print "Refreshing all caches...."
    #check for new caches
    for c in caches['caches']:
      rfile = "-".join(c)
      cfile = cache_dir+"/"+rfile
      new_caches.append(rfile)
      #if we have a cache then do not need to fetch unless forced
      if not force and exists (cfile): continue
      if opts.debug: print "Gettings cache %s/%s" % (c[0], c[1])
      err, out = fetch_url({'uri':'cache/%s/%s/%s' % (c[0], opts.architecture, c[1])})
      cache = json.loads(out)
      check_server_reply(cache)
      if not 'hash' in cache:
        print "Error: server error: hash of cache missing in server reply"
        sys.exit(1)
      sr_sha = cache.pop('hash')
      #Varify the newly download cache by checking its checksum
      cl_sha = get_cache_hash(cache)
      if cl_sha != sr_sha:
        print "Error: Communication error: Cache size mismatch %s vs %s" % (cl_sha , sr_sha)
        sys.exit(1)
      cache['hash'] = sr_sha
      #save the cache for future use
      save_cache(cache, cfile)
      caches_added += 1
    local_caches = 0
    #check for all available caches and delete those which are not on server any more
    for cfile in glob(cache_dir+"/*-*"):
      local_caches += 1
      cname = cfile.replace(cache_dir+"/","")
      if not cname in new_caches:
        if opts.debug: print "[DEBUG]: Cleaning up unused cmspkg cache: %s" % cname
        err, out = run_cmd("rm -f %s" %(cfile))
        caches_removed += 1
    if not silent:
      print "  Local   caches:",local_caches
      print "  Caches updated:",caches_added
      print "  Caches deleted:",caches_removed
    if ((caches_added+caches_removed) == 0):
      local_caches  = pkgCache(False)
      diff = list(set(new_caches)-set(local_caches.active))+list(set(local_caches.active)-set(new_caches))
      if not diff:
        if not silent: print "Package cache up-to-date"
        return
    #Save list of all active caches. It is important that we read the caches in order
    cfile = cache_dir+"/active"
    outfile = open(cfile+"-tmp", 'w')
    if outfile:
      outfile.write(json.dumps(new_caches, indent=2,separators=(',',': ')))
      outfile.close()
    run_cmd("mv %s-tmp %s" %(cfile, cfile))
    if not silent: print "cmspkg update done"
    return

  #Get the latest revision of a package. Mostly used for packages with multile revisions
  def latest_revision(self, name):
    return sorted(self.cache.packs[name],key=int)[-1]

  #Returns the package information for a package name
  #If package is already installed then return None
  def package_data(self, name, reinstall=False):
    if (name in self.rpm_cache) and (not reinstall): return None
    if not name in self.cache.packs:
      print "Error: unknown pakcage: ",name
      sys.exit(1)
    return self.cache.packs[name][self.latest_revision(name)]

  #Recursively download all the dependencies
  def download_deps(self, deps, deps_cache):
    to_download = []
    for dn in deps:
      d = None
      if dn in deps_cache: d = deps_cache[dn]
      if not d: continue
      to_download.append(d)
    if not to_download: return
    if not self.downloader.run(list(to_download)): sys.exit(1)
    ndeps = []
    for d in to_download:
      for xd in get_pkg_deps(d[1])+d[4]:
        if xd in deps_cache: continue
        deps_cache[xd] = self.package_data(xd)
        ndeps.append(xd)
    if ndeps:
      print "Downloading indirect dependencies...."
      print "0 upgraded, ",len(ndeps)," newly installed, 0 removed and 0 not upgraded"
    self.download_deps(sorted(ndeps), deps_cache)
    return

  #Just like apt-get clean, it cleans-up the download rpm from the cmspkg cache directory
  def clean(self):
    if exists (rpm_download):
      run_cmd ("touch %s/tmp.rpm && rm -f %s/*.*" % (rpm_download, rpm_download))
    return

  #Installs a package.
  def install(self, package, reinstall=False, force=False):
    if not self.cache:
      print "Reading Package Lists..."
      self.cache = pkgCache()
    #Error is unknow package
    if not package in self.cache.packs:
      print "error: unknown pakcage: ",package
      sys.exit(1)

    #Read rpm database
    self.update_rpm_cache()
    pk = self.package_data(package, reinstall)
    if (not reinstall) and (not pk):
      print "%s is already the newest version.\n0 upgraded, 0 newly installed, 0 removed and 0 not upgraded." % package
      package_installed(package)
      return

    #make sure that rpm download directory is available
    makedirs(join(rpm_download,rpm_partial),True)

    #download the package
    if not self.downloader.run([pk]): sys.exit(1)
    deps={}
    npkgs = []
    
    #Find out package dependencies
    print "Building Dependency Tree..."
    for d in get_pkg_deps(pk[1])+pk[4]:
      if d in deps: continue
      p = self.package_data(d)
      deps[d] = p
      if p: npkgs.append(d)
    npkgs.sort()
    pkg_to_install = "  "+package+"\n  "+"\n  ".join(npkgs)
    print "The following NEW packages will be installed:"
    print pkg_to_install
    pkg_len = len(npkgs)+1
    print "0 upgraded, ",pkg_len," newly installed, 0 removed and 0 not upgraded."
    
    #If not force and there are extra packages to install then ask user to confirm
    if (not force) and (pkg_len>1): ask_user_to_continue("Continue installation (Y/n): ")

    #download all the dependencies of the package
    self.download_deps (sorted(deps), deps)
    pkg_to_install = pk[1]
    size_compress, size_uncompress = self.package_size (pk[1])
    for d in [p[1] for p in deps.values() if p]:
      s1, s2 = self.package_size(d)
      size_compress += s1
      size_uncompress += s2
      pkg_to_install += "  "+d
    reinstall_opts = ""
    if reinstall and (package in self.rpm_cache): reinstall_opts = "--replacepkgs --replacefiles --nodeps"
    print "Downloaded %s of archives." % human_readable_size(size_compress)
    print "After unpacking %s of additional disk space will be used." % human_readable_size(size_uncompress)
    rcmd = "%s; rpm -Uvh -r %s --force --prefix %s --ignoreos --ignorearch --oldpackage %s" %(rpm_env, opts.install_prefix, opts.install_prefix, reinstall_opts)
    print "Executing RPM (%s)..." % rcmd
    cmd = "cd %s && %s %s" %(rpm_download, rcmd,  pkg_to_install)

    #Install the nwly downloaded packages(s)
    err = subprocess.call(cmd, shell=True)
    if not err:
      self.update_rpm_cache(True)
      if package in self.rpm_cache:
        package_installed(package)
        self.clean()
    return

  #print the packages name which matched the pkg_search pattren. 
  #If -f option is used the exact package name is matched
  def search(self, pkg_search="", exact=False):
    self.cache = pkgCache()
    for pk in self.cache.packs:
      found = False
      if pkg_search=="":
        found = True
      elif exact:
        found = (pk==pkg_search)
      else:
        found = (pkg_search in pk)
      if found:
        data = self.cache.packs[pk][sorted(self.cache.packs[pk],key=int)[-1]]
        print "%s - CMS Experiment package SpecChecksum:%s" % (pk, data[0])
    return
   
  #Shows a package detail just like apt-cache showpkg
  def show(self, pkg):
    self.cache = pkgCache()
    if not pkg in self.cache.packs:
      exit(1)
    pkg_data = self.cache.packs[pkg][self.latest_revision(pkg)]
    pkg_file = pkg_data[1]
    pkg_info = pkg_data[1].rsplit('.',2)
    pkg_items = pkg_info[0].rsplit('-',2)
    pkg_xinfo = pkg_items[0].split('+',2)
    print "Package: "+pkg_items[0]
    print "Section: "+pkg_xinfo[0]
    print "Packager: CMS <hn-cms-sw-develtools@cern.ch>"
    print "Version: "+pkg_items[1]+"-"+pkg_items[2]
    print "Architecture: "+pkg_info[1]
    print "Size: 1"
    print "MD5Sum: "
    print "Filename: "
    print "Summary: CMS Experiment package SpecChecksum:"+pkg_data[0]
    print "Description: \n No description\n"
    return

  #Help function to just download a package without installing it.
  def download(self, package):
    if not self.cache:
      print "Reading Package Lists..."
      self.cache = pkgCache()
    makedirs(join(rpm_download,rpm_partial),True)
    if package.endswith('.rpm'): package = rpm2package (package, opts.architecture)
    if not package in self.cache.packs:
      print "error: unknown pakcage: ",package
      sys.exit(1)
    pk = self.cache.packs[package][self.latest_revision(package)]
    if not self.downloader.run([pk]): sys.exit(1)
    return

  #Clone the remote repository for local distribution
  def clone(self, clone_dir):
    if not self.cache:
      print "Reading Package Lists..."
      self.cache = pkgCache()
    default_trans = "0000000000000000000000000000000000000000000000000000000000000000"
    download_dir = join(clone_dir, opts.repository, opts.architecture, default_trans, "RPMS")
    if not exists (download_dir): makedirs(download_dir,True)
    makedirs(join(rpm_download,rpm_partial),True)
    #download system files: bootstrap.sh, cmsos, cmspkg
    for sfile in ["cmsos", "bootstrap.sh", "README.md"]:
      ofile = join(clone_dir, sfile)
      if not exists (ofile):
        err, out = fetch_url({'uri':'file/%s/%s/%s' % (opts.repository, opts.architecture, sfile)}, outfile=ofile+".tmp")
        if err: sys.exit(1)
        run_cmd("mv %s.tmp %s" % (ofile, ofile))
      ofile1 = join(clone_dir, opts.repository, sfile)
      if not exists (ofile1): run_cmd("cp %s %s" % (ofile, ofile1))
    ofile = join(clone_dir, "cmspkg.py")
    if not exists (ofile): run_cmd("cp %s %s" % (script_path, ofile))
    #download the driver file
    ofile = join(clone_dir, opts.repository, "drivers", opts.architecture+"-driver.txt")
    if not exists (ofile):
      makedirs(join(clone_dir, opts.repository, "drivers"))
      err, out = fetch_url({'uri':'driver/%s/%s' % (opts.repository, opts.architecture)}, outfile=ofile+".tmp")
      if err: sys.exit(1)
      run_cmd("mv %s.tmp %s" % (ofile, ofile))
    #Read existsing package cache
    clone_cache_file = download_dir+".json"
    clone_cache = {}
    if exists (clone_cache_file):
      clone_cache = json.loads(open(clone_cache_file).read())
      clone_cache.pop('hash',None)
    files2download=[]
    update_hash = False
    on_server = 0 
    on_clone = 0
    for pkg in self.cache.packs:
      for r in self.cache.packs[pkg]:
        on_server += 1
        if (pkg in clone_cache) and (r in clone_cache[pkg]):
          on_clone +=1
          continue
        if not pkg in clone_cache: clone_cache[pkg]={}
        update_hash = True
        data = self.cache.packs[pkg][r]
        clone_cache[pkg][r]=data[:-1]
        clone_file = join(download_dir, data[0][:2], data[0], data[1])
        if not exists (clone_file): files2download.append(data)
        else: on_clone +=1
    print "Packages on Server:",on_server
    print "Packages on clone: ",on_clone
    #download any package which are only available on server
    if files2download:
      ok = self.downloader.run(files2download)
      for pk in files2download:
        subdir = join(download_dir, pk[0][:2], pk[0])
        clone_file = join(subdir, pk[1])
        download_file = join (rpm_download, pk[1])
        if exists (download_file):
          run_cmd ("mkdir -p %s && mv %s %s" % (subdir, download_file, clone_file))
        else:
          print "Unable to download: %s/%s/%s/%s" % (opts.repository, opts.architecture, pk[0], pk[1])
          ok = False
      if not ok: sys.exit(1)
    #update hash if needed
    if update_hash:
      clone_cache['hash'] = get_cache_hash(clone_cache)
      save_cache(clone_cache, clone_cache_file)
      if not exists (join(clone_dir, opts.repository, opts.architecture, "latest")):
        run_cmd("ln -s %s %s/%s/%s/latest" % (default_trans, clone_dir, opts.repository, opts.architecture))
    print "Repo successfully cloned"
    return

  #uninstall a package and remove its stamp file
  def remove(self, package, force=False):
    self.update_rpm_cache()
    if package in self.rpm_cache:
      if not force: ask_user_to_continue("Are you sure to delete %s (Y/n): " % package)
      print "Removing package",package
      err, out = run_cmd("%s; rpm -e %s" % (rpm_env, package))
      package_removed (package)
      print "Removed",package
    else:
      print "Package %s not installed" % package
    return

  #upgrade cmspkg client
  def upgrade(self):
    print "Current cmspkg version:  ",cmspkg_tag
    err, out = fetch_url({'uri':'upgrade','info':1, 'version':cmspkg_tag})
    reply = json.loads(out)
    check_server_reply(reply)
    print "Available cmspkg version:",reply['version']
    if not newer_version(reply['version'], cmspkg_tag): return
    if 'changelog' in reply:
      print "---- Change logs ----"
      print "\n".join(reply['changelog']),"\n"
    if not opts.force: ask_user_to_continue("Are you sure to continue with upgrade (Y/n): ")
    ofile = join(rpm_download, rpm_partial, "cmspkg.py")
    err, out = fetch_url({'uri':'upgrade'},outfile=ofile)
    if not exists(ofile):
      print out
      sys.exit(1)
    verify_download(ofile, reply['size'], reply['sha'])
    self.setup(reply['version'], ofile)
    run_cmd("rm -f %s" % ofile)
    print "Running setup for the newly downloaded version."
    run_cmd("%s/common/cmspkg --architecture %s setup" % (opts.install_prefix, opts.architecture))
    print "Newer cmspkg client installed"
    return

  #setup cmspkg area 
  def setup(self, version, client_file):
    pkg_dir = join(opts.install_prefix, opts.architecture, "cms", "cmspkg", version)
    if not exists (pkg_dir):
      makedirs(pkg_dir, True)
      run_cmd("cp -f %s %s/cmspkg.py && chmod +x %s/cmspkg.py" % (client_file, pkg_dir, pkg_dir))
      outfile = open("%s/rpm_env.sh" % pkg_dir, 'w')
      if outfile:
        outfile.write('source $(ls %s/$1/external/rpm/*/etc/profile.d/init.sh | tail -1)\n' % opts.install_prefix)
        outfile.write('[ -e %s/common/apt-site-env.sh ] && source %s/common/apt-site-env.sh\n' % (opts.install_prefix, opts.install_prefix))
        outfile.close()
    pkg_share_dir = join(opts.install_prefix, "share", "cms", "cmspkg")
    if not exists(join(pkg_share_dir, version)):
      makedirs(pkg_share_dir, True)
      run_cmd("rsync -a %s/ %s/tmp-%s/" % (pkg_dir, pkg_share_dir,version))
      run_cmd("mv %s/tmp-%s %s/%s" % (pkg_share_dir, version, pkg_share_dir, version))
    force = False
    common_cmspkg = join(opts.install_prefix, "common", "cmspkg")
    if exists (common_cmspkg) and version==cmspkg_tag:
      err, prev_version = run_cmd("grep '^###CMSPKG_VERSION=' %s | sed 's|.*=V|V|'" % common_cmspkg, outdebug=False, exit=False)
      if (prev_version=="") or newer_version(cmspkg_tag, prev_version): force=True
    self.update_common_cmspkg(common_cmspkg, force)
    print "cmspkg setup done."
    return

  def update_common_cmspkg(self, common_cmspkg, force=False):
    if not force and exists(common_cmspkg): return
    makedirs(dirname(common_cmspkg))
    exOpt=""
    if opts.useDev: exOpt="--use-dev"
    if opts.server_path: exOpt=exOpt + " --server-path %s " % opts.server_path
    cmspkg_str = ["#!/bin/bash","#This file is automatically generated by cmspkg setup command. Please do not edit it.", "###CMSPKG_VERSION=%s" % cmspkg_tag]
    cmspkg_str.append("$(/bin/ls %s/share/cms/cmspkg/V*/cmspkg.py | tail -1) --path %s --repository %s --server %s %s $@\n" % (opts.install_prefix, opts.install_prefix, opts.repository, opts.server, exOpt))
    cmspkg_str.append("")
    outfile = open(common_cmspkg+"-tmp", 'w')
    if outfile:
      outfile.write("\n".join(cmspkg_str))
      outfile.close()
    run_cmd("chmod +x %s-tmp" % common_cmspkg)
    run_cmd("mv %s-tmp %s" % (common_cmspkg, common_cmspkg))
    return

  #cleanup the distributuion. delete RPMs which are not used by
  #explicitly installed packages
  def dist_clean(self, force=False):
    def keepPack(pkg, cache):
      if pkg in cache["KEPT"]: return
      cache["KEPT"][pkg]=1
      cache["RPMS"].pop(pkg,None)
      err, out = run_cmd("%s; rpm -qR --queryformat '%%{NAME}\n' %s" % (rpm_env, pkg))
      for dep in out.split("\n"): cache["RPMS"].pop(dep.strip(),None)

    def checkDeps(pkg, cache):
      if pkg in cache["CHECK"]: return
      cache["CHECK"][pkg]=1
      if not pkg in cache["RPMS"]:
        keepPack(pkg, cache)
        return
      err, out = run_cmd("%s; rpm -q --whatrequires --queryformat '%%{NAME}\n' %s" % (rpm_env, pkg), False, False)
      if err: return
      for req in out.split("\n"):
        req=req.strip()
        checkDeps(req, cache)
        if (req in cache["RPMS"]) and (pkg in cache["RPMS"]):
          cache["RPMS"][pkg]["USEDBY"][req]=1

    keep_regexp = [re.compile("^"+x+".*$") for x in pkgs_to_keep]
    explicit_pkgs = {}
    if exists(pkgs_dir):
      for pkg in glob(pkgs_dir+"/*+*+*"):
        explicit_pkgs[basename(pkg)]=1
    cmsdistrc_dir = join(opts.install_prefix, opts.architecture, ".cmsdistrc")
    if exists (cmsdistrc_dir):
      for pkg in glob(cmsdistrc_dir+"/PKG_*+*+*"):
        explicit_pkgs[basename(pkg)[4:]]=1
    for pkg in explicit_pkgs:
      keep_regexp.append(re.compile("^"+re.escape(pkg)+"$"))
    self.update_rpm_cache(True)
    cache = {"RPMS" : {}, "KEPT": {}, "CHECK" : {}}
    for pkg in self.rpm_cache:
      if not re.match("^(cms|external|lcg)[+].+",pkg): continue
      cache["RPMS"][pkg]={"USEDBY":{}}

    for pkg in cache["RPMS"].keys():
      for exp in keep_regexp:
        if not re.match(exp, pkg): continue
        keepPack(pkg, cache)
        break

    for pkg in cache["RPMS"].keys(): checkDeps(pkg, cache)
    if not cache["RPMS"]:
      print "Nothing to clean"
      return

    print "Following packages will be removed from the installation:"
    print "  "+"\n  ".join(sorted(cache["RPMS"].keys()))
    if not force: ask_user_to_continue("Are you sure to remove above packages (Y/n): ")
    rpms2del = []
    while cache["RPMS"]:
      dels = []
      del_count = len(rpms2del)
      for pkg in sorted(cache["RPMS"].keys()):
        if len(cache["RPMS"][pkg]["USEDBY"])==0:
          dels.append(pkg)
          del_count+=1
          if del_count>=20: break
      for pkg in dels:
        cache["RPMS"].pop(pkg,None)
        for dep in cache["RPMS"]: cache["RPMS"][dep]["USEDBY"].pop(pkg,None)
      rpms2del = rpms2del + dels
      if del_count>=20:
        pkgs = " ".join(rpms2del)
        print "Removing ",pkgs
        err, out = run_cmd("%s; rpm -e %s" % (rpm_env, pkgs))
        rpms2del =[]
    if rpms2del:
      pkgs = " ".join(rpms2del)
      print "Removing ",pkgs
      err, out = run_cmd("%s; rpm -e %s" % (rpm_env, pkgs))
    return

#Process the input command/options
#cmspkg always create a lock
def process(args, opt, cache_dir):
  if args[0] == "setup":
    repo = CmsPkg(opt.jobs)
    repo.setup(cmspkg_tag, script_path)
    return
  if args[0]=="rpm":
    cmd = rpm_env+" ; "+args[0]
    for a in args[1:]: cmd+=" '"+a+"'"
    sys.exit(subprocess.call(cmd , shell=True))

  makedirs(cache_dir,True)
  lock = cmsLock(cache_dir)
  if not lock:
    print "Unable to obtain lock, there is already a process running"
    return

  if True:
    repo = CmsPkg(opt.jobs)
    if args[0] == "update":
      repo.update(force=opts.force)
    elif args[0] == "clean":
      repo.clean()
    elif args[0] in ["install","reinstall"]:
      cDebug = opts.debug
      opts.debug = False
      updateForce=False
      if not exists (join(cache_dir , "active")): updateForce=True
      repo.update(force=updateForce, silent=True)
      opts.debug = cDebug
      for pkg in args[1:]:
        repo.install(pkg, reinstall=opts.reinstall, force=opts.force)
    elif args[0] in ["download"]:
      cDebug = opts.debug
      opts.debug = False
      updateForce=False
      if not exists (join(cache_dir , "active")): updateForce=True
      repo.update(force=updateForce, silent=True)
      opts.debug = cDebug
      for pkg in args[1:]:
        repo.download(pkg)
    elif args[0] in ["remove"]:
      for pkg in args[1:]: repo.remove(pkg, force=opts.force)
      if opts.dist_clean:  repo.dist_clean(force=opts.force)
    elif args[0] in ["dist-clean"]:
      repo.dist_clean(force=opts.force)
    elif args[0] in ["clone"]:
      repo.update(force=opts.force)
      repo.clone(opts.install_prefix)
    elif args[0] == "search":
      if not exists (join(cache_dir , "active")): repo.update(True)
      pkg = ""
      if len(args)==2: pkg =args[1]
      repo.search(pkg, exact=opts.force)
    elif args[0] == "show":
      if not exists (join(cache_dir , "active")): repo.update(True)
      repo.show(args[1])
    elif args[0] == "upgrade":
      repo.upgrade()

if __name__ == '__main__':
  from optparse import OptionParser
  cmspkg_cmds = ["update","search","install","reinstall","clean","remove","dist-clean","show","download", "rpm", "clone", "setup","upgrade"]
  parser = OptionParser(usage=basename(sys.argv[0])+" -a|--architecture <arch>\n"
  "              -s|--server <server>\n"
  "              -r|--repository <repository>\n"
  "              -p|--path <path>\n"
  "              [-j|--jobs num]\n"
  "              [-f|-y|--force]\n"
  "              [-d|--debug]\n"
  "              [-c|--dist-clean]\n"
  "              [-v|--version]\n"
  "              [--dev]\n"
  "              [--reinstall]\n"
  "              "+" | ".join(cmspkg_cmds)+" [package| -- rpm <args>]\n\n")
  parser.add_option("--reinstall",         dest="reinstall", action="store_true", default=False, help="Reinstall a package e.g. its latest revision")
  parser.add_option("-f", "--force",       dest="force",     action="store_true", default=False, help="Force an update or installation")
  parser.add_option("-y",                  dest="force",     action="store_true", default=False, help="Assume yes for installation")
  parser.add_option("-d", "--debug",       dest="debug",     action="store_true", default=False, help="Print more debug outputs")
  parser.add_option("-v", "--version",     dest="version",   action="store_true", default=False, help="Print version string")
  parser.add_option("--use-dev",           dest="useDev",    action="store_true", default=False, help="Use development server instead of production")
  parser.add_option("-a", "--architecture",dest="architecture", default=None,          help="Architecture string")
  parser.add_option("-r", "--repository",  dest="repository",   default="cms",          help="Repository name defalut is cms")
  parser.add_option("-p", "--path",        dest="install_prefix",default=getcwd(),  help="Install path.")
  parser.add_option("-j", "--jobs",        dest="jobs",         default=4, type="int", help="Max parallel downloads")
  parser.add_option("-s", "--server",      dest="server",       default="cmsrep.cern.ch",   help="Name of cmsrep server, default is cmsrep.cern.ch")
  parser.add_option("-S", "--server-path", dest="server_path",  default=None,   help="Path of repo on server.")
  parser.add_option("-c", "--dist-clean",  dest="dist_clean",   action="store_true",   default=False, help="Only used with 'remove' command to do the distribution cleanup after the package removal.")

  opts, args = parser.parse_args()
  if opts.version:
    print cmspkg_tag
    sys.exit(0)
  if len(args) == 0: parser.error("Too few arguments")
  if not opts.architecture: parser.error("Missing architecture string")
  if not opts.server: parser.error("Missing repository server name")
  if not opts.repository: parser.error("Missing repository name")
  if not opts.install_prefix: parser.error("Missing install path string")
  if opts.useDev: cmspkg_cgi = cmspkg_cgi+'-dev'
  if not opts.server_path: opts.server, opts.server_path = get_server_paths (opts.server)

  cmspkg_local_dir = join(opts.install_prefix, opts.architecture, 'var/cmspkg')
  if not args[0] in ["clone", "download", "setup", "upgrade"]:
    rpm_env = join(dirname(script_path), "rpm_env.sh")
    if not exists (rpm_env):
      print "Error: Unable to find rpm installation. Are you sure you have a bootstrap area?"
      sys.exit(1)
    rpm_env = "source %s %s" % (rpm_env, opts.architecture)
  elif args[0] == "clone":
    if len(args) > 1: parser.error("Too many arguments")
    opts.install_prefix = join(opts.install_prefix, "repos")
    cmspkg_local_dir = join(opts.install_prefix, opts.repository, opts.architecture, 'cmspkg')

  cache_dir    = join(cmspkg_local_dir, 'cache')
  pkgs_dir     = join(cmspkg_local_dir, 'pkgs')
  rpm_download = join(cmspkg_local_dir, 'rpms')
  if not args[0] in cmspkg_cmds: parser.error("Unknown command "+args[0])

  if args[0] in ["install","reinstall","download","remove"]: 
    if len(args) < 2: parser.error("Too few arguments")
  elif (args[0] in ["update","clean","dist-clean","setup","upgrade"]):
    if len(args) != 1: parser.error("Too many arguments")
  elif (args[0] in ["search"]):
    if len(args) > 2: parser.error("Too many arguments")
  if args[0] == "reinstall": opts.reinstall = True

  process(args, opts, cache_dir)
