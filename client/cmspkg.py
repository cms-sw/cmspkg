#!/usr/bin/env python
from re import compile, match, escape
from re import search as research
from re import IGNORECASE as reIGNORECASE
from threading import Lock, Thread
from sys import exit, argv
from sys import version_info,stdout
from sys import exc_info, platform
from os import system as syscall
from os import getpid, getcwd, mkdir, stat, kill
from os.path import join, exists, abspath, dirname, basename, isdir
from time import sleep, time
from glob import glob
try: import json
except:import simplejson as json

#to work with python 2 and 3
def cmspkg_print(msg): stdout.write(msg+"\n")

cmd_md5sum="md5sum"
cmd_sha256sum="sha256sum"
if platform.startswith("darwin"):
  cmd_md5sum="md5 -q"
  cmd_sha256sum="shasum -a 256"

if version_info < (3,):
  get_user_input=raw_input
else:
  get_user_input=input

if version_info < (2,6):
  def get_alive_threads(threads): return [t for t in threads if t.isAlive()]
else:
  def get_alive_threads(threads): return [t for t in threads if t.is_alive()]

try: from urllib import quote
except: from urllib.parse import quote

try: from commands import getstatusoutput
except:
  try: from subprocess import getstatusoutput
  except:
    def getstatusoutput(command2run):
      from subprocess import Popen, PIPE, STDOUT
      cmd = Popen(command2run, shell=True, stdout=PIPE, stderr=STDOUT)
      (output, errout) = cmd.communicate()
      if isinstance(output,bytes): output =  output.decode()
      if output[-1:] == '\n': output = output[:-1]
      return (cmd.returncode, output)

try:
  from hashlib import sha256
  def cmspkg_sha256(data, tmpdir=None): return sha256(data).hexdigest()
except:
  from tempfile import mkstemp
  def cmspkg_sha256(data, tmpdir=None):
    fd, tmpfile = mkstemp(prefix="tmp_sha256",dir=tmpdir)
    sha = ""
    try:
      fref = open(tmpfile, "w")
      fref.write(data)
      fref.close()
      err, out = getstatusoutput("%s %s" % (cmd_sha256sum, tmpfile))
      if not err: sha = out.split()[0]
      else: cmspkg_print("Error: Unable to get sha256. %s" % out)
    except Exception: 
      cmspkg_print("Error: Unable to get sha256. %s" % str(exc_info()[1]))
    getstatusoutput("rm -f %s" % tmpfile)
    return sha

cmspkg_tag   = "V00-00-31"
cmspkg_cgi   = 'cgi-bin/cmspkg'
opts         = None
cache_dir    = None
pkgs_dir     = None
rpm_download = None
rpm_env      = None
rpm_partial  = "partial"
getcmd       = None
cmspkg_agent = "CMSPKG/1.0"
pkgs_to_keep = ["cms[+](local-cern-siteconf|afs-relocation-cern)[+]","external[+](apt|rpm)[+]","cms[+](cmspkg|cmssw|cmssw-patch|cms-common|cmsswdata)[+]"]
getcmds = [ 
            ['curl','--version','--connect-timeout 60 --max-time 600 -L -q -f -s -H "Cache-Control: max-age=0" --user-agent "%s"' % (cmspkg_agent),"-o %s"],
            ['wget','--version','--timeout=600 -q --header="Cache-Control: max-age=0" --user-agent="%s" -O -' % (cmspkg_agent),"-O %s"],
          ]

knowledge_based_errors = {}
knowledge_based_errors['unable to allocate memory for mutex|resize mutex region'] = \
"Add/update the following line in @INSTALL_PREFIX@/@ARCH@/var/lib/rpm/DB_CONFIG file and rebuild rpm databse.\nmutex_set_max 10000000"
knowledge_based_found = {}
try:
  script_path = __file__
except:
  script_path = argv[0]
script_path = abspath(script_path)
#####################################
#Utility functions:
######################################
#Return a package name from a RPM File name
#RPM file name format: <group>+<pkg-name>+<pkg-version>-1-([0-9]+|<arch>).<arch>.rpm
#Returns: <group>+<pkg-name>+<pkg-version>
def rpm2package(rpm, arch):
  ReRPM = compile('(.+)[-]1[-]((1|\d+)(.%s|))\.%s\.rpm' % (arch,arch))
  g,p,vx = rpm.split("+",2)
  m = ReRPM.match (vx)
  v = m.group(1)
  r = m.group(3)
  return "+".join([g,p,v])

def check_kbe(error_msg):
  for err in knowledge_based_errors:
    if research(err, error_msg, flags=reIGNORECASE):
      sol = knowledge_based_errors[err].replace("@INSTALL_PREFIX@",opts.install_prefix).replace("@ARCH@", opts.architecture)
      if not err in knowledge_based_found:
        cmspkg_print("ERROR: Following error found.\n  %s" % error_msg)
        cmspkg_print("Solution:\n  %s" % sol)
        knowledge_based_found[err]=1
      if opts.IgnoreKbe: return True
      exit(1)
  return False

def print_msg(msg, type):
  for m in msg.split("\n"): cmspkg_print("[%s]: %s" % (type, m))

def get_cache_hash(cache, tmpdir=None):
  return cmspkg_sha256(json.dumps(cache, sort_keys=True, separators=(',',': ')).encode('utf-8'),tmpdir)

def save_cache(cache, cache_file):
  outfile = open(cache_file+"-tmp", 'w')
  if outfile:
    outfile.write(json.dumps(cache, indent=2,separators=(',',': ')))
    outfile.close()
  run_cmd("mv %s-tmp %s" %(cache_file, cache_file))

def newer_version(new_ver, prev_ver):
  return int(new_ver[1:].replace("-",""))>int(prev_ver[1:].replace("-",""))

def cleanup_package_dir(package):
  pkg_dir = join(opts.install_prefix, opts.architecture, *package.split("+",2))
  if isdir (pkg_dir): err, out = run_cmd("rm -rf %s" % pkg_dir)

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
def ask_user_to_continue(msg):
  res = get_user_input(msg)
  res = res.strip()
  if not res in ["y", "Y"]: exit(0)

#Returns cmspkg url to access
def cmspkg_url(params):
  url = "http://%s/%s/%s?version=%s&repo_uri=%s" % (opts.server, cmspkg_cgi, params['uri'],cmspkg_tag, opts.server_path)
  if opts.debug: url = url + "&debug=1"
  del params['uri']
  for dup_param in ["version","repo_uri","debug"]: params.pop(dup_param,None)
  for p in params: url = url + "&" + p + "=" + str(params[p])
  if opts.debug: cmspkg_print("[DEBUG]: Accessing %s" % (url))
  return url

#Check server reply: print any debug/warning/error message
def check_server_reply(reply, exit_on_error=True):
  if 'debug'  in reply:
    print_msg(reply.pop('debug'), "DEBUG")
  if 'warning'  in reply:
    print_msg(reply['warning'],"WARN")
  if 'information'  in reply:
    print_msg(reply['information'],"INFO")
  if 'error' in reply:
    print_msg(reply['error'],"ERROR")
    if exit_on_error: exit(1)
  return

#Use available command (curl or wget) to download url
def set_get_cmd():
  global getcmd
  if getcmd: return
  for cmd in getcmds:
    err, out = run_cmd("%s %s 2>&1 >/dev/null" %(cmd[0],cmd[1]),False,False)
    if not err:
      if opts.download_options: cmd[2] = cmd[2]+" "+opts.download_options
      getcmd = cmd
      return
  cmspkg_print("Error: Unable to find any of the following commands. Please make sure you have any one of these installed.")
  cmspkg_print(" "+"\n  ".join([x[0] for x in getcmds]))
  exit(1)

def download_file_if_changed(uri, ofile, optional=False):
  err, out = fetch_url({'uri': uri, 'info':1}, exit_on_error=not optional)
  if optional and err:
    print_msg("Optional file not available on server: " + uri, "DEBUG")
    return
  reply = json.loads(out)
  check_server_reply(reply)
  if (not 'size' in reply) or (not 'sha' in reply):
    cmspkg_print("Error: Server error: unable to find size/checksum of file: %s" % uri)
    exit(1)
  if exists (ofile) and verify_download(ofile, reply['size'], reply['sha'], debug=False): return True
  tmpfile = ofile+".tmp"
  err, out = fetch_url({'uri': uri}, outfile=tmpfile)
  if err: exit(1)
  if not verify_download(tmpfile, reply['size'], reply['sha']): exit(1)
  run_cmd("mv %s %s" % (tmpfile, ofile))
  return

def fetch_url(data, outfile=None, debug=False, exit_on_error=True):
  set_get_cmd ()
  url = cmspkg_url(data)
  cmd = [getcmd[0], getcmd[2]]
  if outfile:
    outdir = dirname(outfile)
    if not exists (outdir): makedirs(outdir,True)
    cmd.append(getcmd[3] % outfile)
  cmd.append('"'+url+'"')
  cmd_str = " ".join(cmd)
  return run_cmd(cmd_str, outdebug=debug, exit_on_error=exit_on_error)

#Run a shell command
def run_cmd (cmd,outdebug=False,exit_on_error=True):
  if opts.debug: cmspkg_print("[CMD]: %s" % cmd)
  err, out = getstatusoutput(cmd)
  if err:
    if exit_on_error:
      cmspkg_print(out)
      exit(1)
  elif outdebug:
    cmspkg_print(out)
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
    err, out = run_cmd(cmd_str, outdebug=opts.debug, exit_on_error=False)
    if err: continue
    if out == "CMSPKG OK": return cgi_server, join(*items[1:])
  cmspkg_print("Error: Unable to find /cgi-bin/cmspkg on %s" % server_url)
  exit(1)

def makedirs(path, force=False):
  if exists(path): return
  opt =''
  if force: opt='-p'
  run_cmd("mkdir %s %s" % (opt,path))
  return

#Varifies a file size and md5sums
def verify_download(ofile, size, md5sum, debug=True):
  sinfo = stat(ofile)
  if sinfo[6] != size:
    if debug: cmspkg_print("Error: Download error: Size mismatch for %s (%s vs %s)." % (ofile, str(sinfo[6]), str(size)))
    return False
  err, out = run_cmd("%s %s | sed 's| .*||'" % (cmd_md5sum, ofile))
  if out != md5sum:
    if debug: cmspkg_print("Error: Download error: Checksum mismatch for %s (%s vs %s)." % (ofile, out, md5sum))
    return False
  return True

#Download a packge from cmsrep. If package's size and mk5sums are not passed/available
#then first get this information from cmsrep so that download package can be varified
#After the successful download it puts the downlaod file in rpm_download directory
def download_rpm(package, tries=5):
  if (package[2]=="") or (package[3]==""):
    udata = {'uri':'RPMS/%s/%s/%s/%s' % (opts.repository, opts.architecture, package[0], quote(package[1])), 'ref_hash':package[-1]}
    if package[2]=="": udata["sha"]=1
    if package[3]=="": udata["size"]=1 
    err, out = fetch_url(udata)
    reply = json.loads(out)
    check_server_reply(reply)
    if 'sha' in udata:
      if not 'sha' in reply:
        cmspkg_print("Error: Server error: unable to find checksum of package: %s" % package[1])
        return False
      else:
        package[2] = reply['sha']
    if 'size' in udata:
      if not 'size' in reply:
        cmspkg_print("Error: Server error: unable to find size of package: %s" % package[1])
        return False
      else:
        package[3] = reply['size']

  ofile_tmp = join(rpm_download, rpm_partial, package[1])
  first_try = True
  for i in range(tries):
    if not first_try: cmspkg_print("Retry downloading %s" % package[1])
    first_try = False
    err, out = fetch_url({'uri':'RPMS/%s/%s/%s/%s' % (opts.repository, opts.architecture, package[0], quote(package[1])), 'ref_hash':package[-1]}, outfile=ofile_tmp, exit_on_error=False)
    if (not err) and exists(ofile_tmp) and verify_download(ofile_tmp, package[3], package[2]):
      err, out = run_cmd("mv %s %s" % (ofile_tmp, join(rpm_download, package[1])))
      return not err
  return False

#Returns rpm dependencies using rpm -qp --requires command
def get_pkg_deps(rpm):
  cmd = "%s; rpm -qp --requires %s" % (rpm_env, join(rpm_download, rpm))
  err, out = run_cmd(cmd)
  deps = []
  ReReq = compile('^(cms|external|lcg)[+][^+]+[+].+')
  for line in out.split("\n"):
    line = line.strip()
    if check_kbe(line): continue
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
  except Exception: cmspkg_print("Error: Downloading RPMS: %s" % str(exc_info()[1]))

#get RPM Command-line Options
def getRPMOptions(rpm_options, opts):
  for xopt in opts.Add_Options:
    for opt in [ o.strip() for o in xopt.split(',')]:
      if not opt in rpm_options: rpm_options.append(opt)
  for xopt in opts.Remove_Options:
    for opt in [ o.strip() for o in xopt.split(',')]:
      if opt in rpm_options: rpm_options.remove(opt)
  return ' '.join(rpm_options)

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
      kill(pid, 0)
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
      mkdir(self.piddir)
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
    self.lock = Lock()

  def run(self, packages):
    total = len(packages)
    index = 0
    threads = []
    while(index < total):
      threads = get_alive_threads(threads)
      if(len(threads) < self.parallel):
        package = packages[index]
        index += 1
        self.counter = self.counter + 1
        cmspkg_print("Get:%s http://%s cmssw/%s/%s %s" % (self.counter, opts.server, opts.repository, opts.architecture, package[1]))
        try:
          t = Thread(target=download_package, args=(package,))
          t.start()
          threads.append(t)
        except Exception:
          cmspkg_print("Error: Downloading RPMS: %s" % str(exc_info()[1]))
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
      r = r.strip()
      if check_kbe(r): continue
      if not r: continue
      n, rv = r.split(" ")
      self.rpm_cache[n]=rv
    return

  #Read RPM database to get a package size
  def package_size(self, pkg):
    pkg_file = join(rpm_download, pkg)
    err, out = run_cmd("%s; rpm -qip  %s | grep '^Size\s*:' | awk '{print $3}'"  % (rpm_env, pkg_file))
    st = stat(pkg_file)
    return st.st_size, int(out)

  #Download cmspkg caches from server. It is identical to "apt-get update"
  #It first fetches the list of all caches from server and then only download the new caches.
  #Note that the cache name include the timestamp of information. So if a cache was updated on server
  #then it will have a different timestamp which will force us to fetch it.
  def update(self, force=False, silent=False):
    if not silent: cmspkg_print("Updating cmspkg caches ...")
    #fetch list of all caches from cmspkg server
    err, out = fetch_url({'uri':'caches/%s/%s' % (opts.repository, opts.architecture), "stamp": int(time()*1000000)})
    caches = json.loads(out)
    check_server_reply(caches)
    if not 'caches' in caches:
      cmspkg_print("Error: Server error: No caches received from server")
      exit(1)
    new_caches = []
    caches_added = 0
    caches_removed = 0
    if not silent:
      cmspkg_print("  Remote  caches: %s" % len(caches['caches']))
      if force: cmspkg_print("Refreshing all caches....")
    #check for new caches
    for c in caches['caches']:
      rfile = "-".join(c)
      cfile = cache_dir+"/"+rfile
      new_caches.append(rfile)
      #if we have a cache then do not need to fetch unless forced
      if not force and exists (cfile): continue
      if opts.debug: cmspkg_print("Gettings cache %s/%s" % (c[0], c[1]))
      err, out = fetch_url({'uri':'cache/%s/%s/%s' % (c[0], opts.architecture, c[1]), "stamp": int(time()*1000000)})
      cache = json.loads(out)
      check_server_reply(cache)
      if not 'hash' in cache:
        cmspkg_print("Error: server error: hash of cache missing in server reply")
        exit(1)
      sr_sha = cache.pop('hash')
      #Varify the newly download cache by checking its checksum
      cl_sha = get_cache_hash(cache, dirname(cfile))
      if cl_sha != sr_sha:
        cmspkg_print("Error: Communication error: Cache size mismatch %s vs %s" % (cl_sha , sr_sha))
        exit(1)
      cache['hash'] = sr_sha
      #save the cache for future use
      save_cache(cache, cfile)
      caches_added += 1
    local_caches = 0
    #check for all available caches and delete those which are not on server any more
    for cfile in glob(cache_dir+"/*-*-*"):
      local_caches += 1
      cname = cfile.replace(cache_dir+"/","")
      if not cname in new_caches:
        if opts.debug: cmspkg_print("[DEBUG]: Cleaning up unused cmspkg cache: %s" % cname)
        err, out = run_cmd("rm -f %s" %(cfile))
        caches_removed += 1
    if not silent:
      cmspkg_print("  Local   caches: %s" % local_caches)
      cmspkg_print("  Caches updated: %s" % caches_added)
      cmspkg_print("  Caches deleted: %s" % caches_removed)
    if ((caches_added+caches_removed) == 0):
      local_caches  = pkgCache(False)
      diff = list(set(new_caches)-set(local_caches.active))+list(set(local_caches.active)-set(new_caches))
      if not diff:
        if not silent: cmspkg_print("Package cache up-to-date")
        return
    #Save list of all active caches. It is important that we read the caches in order
    cfile = cache_dir+"/active"
    outfile = open(cfile+"-tmp", 'w')
    if outfile:
      outfile.write(json.dumps(new_caches, indent=2,separators=(',',': ')))
      outfile.close()
    run_cmd("mv %s-tmp %s" %(cfile, cfile))
    if not silent: cmspkg_print("cmspkg update done")
    return

  #Get the latest revision of a package. Mostly used for packages with multile revisions
  def latest_revision(self, name):
    return sorted(self.cache.packs[name],key=int)[-1]

  #Returns the package information for a package name
  #If package is already installed then return None
  def package_data(self, name, reinstall=False):
    if (name in self.rpm_cache) and (not reinstall): return None
    if not name in self.cache.packs:
      cmspkg_print("Error: unknown pakcage: %s" % name)
      exit(1)
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
    if not self.downloader.run(list(to_download)): exit(1)
    ndeps = []
    for d in to_download:
      for xd in get_pkg_deps(d[1])+d[4]:
        if xd in deps_cache: continue
        deps_cache[xd] = self.package_data(xd)
        ndeps.append(xd)
    if ndeps:
      cmspkg_print("Downloading indirect dependencies....")
      cmspkg_print("0 upgraded, %s newly installed, 0 removed and 0 not upgraded" % len(ndeps))
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
      cmspkg_print("Reading Package Lists...")
      self.cache = pkgCache()
    #Error is unknow package
    if not package in self.cache.packs:
      cmspkg_print("error: unknown pakcage: %s" % package)
      exit(1)

    #Read rpm database
    self.update_rpm_cache()
    pk = self.package_data(package, reinstall)
    if (not reinstall) and (not pk):
      cmspkg_print("%s is already the newest version.\n0 upgraded, 0 newly installed, 0 removed and 0 not upgraded." % package)
      package_installed(package)
      return

    #make sure that rpm download directory is available
    makedirs(join(rpm_download,rpm_partial),True)

    #download the package
    if not self.downloader.run([pk]): exit(1)
    deps={}
    npkgs = []
    
    #Find out package dependencies
    cmspkg_print("Building Dependency Tree...")
    for d in get_pkg_deps(pk[1])+pk[4]:
      if d in deps: continue
      p = self.package_data(d)
      deps[d] = p
      if p: npkgs.append(d)
    npkgs.sort()
    pkg_to_install = "  "+package+"\n  "+"\n  ".join(npkgs)
    cmspkg_print("The following NEW packages will be installed:")
    cmspkg_print(pkg_to_install)
    pkg_len = len(npkgs)+1
    cmspkg_print("0 upgraded, %s newly installed, 0 removed and 0 not upgraded." % pkg_len)
    
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
    cmspkg_print("Downloaded %s of archives." % human_readable_size(size_compress))
    cmspkg_print( "After unpacking %s of additional disk space will be used." % human_readable_size(size_uncompress))
    ex_opts  = ['-U', '-v', '-h', '-r %s' % opts.install_prefix, '--prefix %s' % opts.install_prefix, '--force', '--ignoreos', '--ignorearch', '--oldpackage']
    if reinstall and (package in self.rpm_cache): ex_opts += ['--replacepkgs', '--replacefiles', '--nodeps']
    if opts.IgnoreSize: ex_opts.append('--ignoresize')
    rcmd = "%s; rpm %s" % (rpm_env, getRPMOptions(ex_opts, opts))
    cmspkg_print("Executing RPM (%s)..." % rcmd)
    cmd = "cd %s && %s %s" %(rpm_download, rcmd,  pkg_to_install)

    #Install the nwly downloaded packages(s)
    if syscall(cmd)>0: exit(1)
    self.update_rpm_cache(True)
    if package in self.rpm_cache:
      package_installed(package)
      self.clean()
    return

  #print the packages name which matched the pkg_search pattren. 
  #If -f option is used the exact package name is matched
  def search(self, pkg_search="", exact=False):
    self.cache = pkgCache()
    pkgs = []
    if pkg_search=="": pkgs=self.cache.packs.keys()
    elif exact:
      if pkg_search in self.cache.packs: pkgs.append(pkg_search)
    else:
      for pk in self.cache.packs:
        if pkg_search in pk: pkgs.append(pk)
    pkgs = sorted(pkgs)
    for pk in pkgs:
      rev = sorted(self.cache.packs[pk],key=int)[-1]
      data = self.cache.packs[pk][rev]
      srev=""
      if opts.show_revision: srev=" %s" % rev
      cmspkg_print("%s - CMS Experiment package SpecChecksum:%s%s" % (pk, data[0],srev))
    return
   
  #print the packages name and all its revisions.
  def showpkg(self, package):
    self.cache = pkgCache()
    cmspkg_print("%s - CMS Experiment package" % package)
    cmspkg_print("Versions:")
    if package in self.cache.packs:
      for rev in sorted(self.cache.packs[package], key=int, reverse=True):
        cmspkg_print("1-"+str(rev)+"."+opts.architecture+"(available in remote repository)")
      return
    cmspkg_print("W: Unable to locate package")
    return
   
  #print the packages dependencies
  def depends(self, package):
    self.cache = pkgCache()
    if not package in self.cache.packs:
      cmspkg_print("W: Unable to locate package %s" % package)
      return
    rev = self.latest_revision(package)
    pk = self.cache.packs[package][rev]
    makedirs(join(rpm_download,rpm_partial),True)
    download_package(pk)
    cmspkg_print("%s-1-%s" % (package, rev))
    for d in get_pkg_deps(pk[1]): cmspkg_print("  Depends: %s" % d)
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
    cmspkg_print("Package: "+pkg_items[0])
    cmspkg_print("Section: "+pkg_xinfo[0])
    cmspkg_print("Packager: CMS <hn-cms-sw-develtools@cern.ch>")
    cmspkg_print("Version: "+pkg_items[1]+"-"+pkg_items[2])
    cmspkg_print("Architecture: "+pkg_info[1])
    cmspkg_print("Size: 1")
    cmspkg_print("MD5Sum: ")
    cmspkg_print("Filename: ")
    cmspkg_print("Summary: CMS Experiment package SpecChecksum:"+pkg_data[0])
    cmspkg_print("Description: \n No description\n")
    return

  #Help function to just download a package without installing it.
  def download(self, package):
    if not self.cache:
      cmspkg_print("Reading Package Lists...")
      self.cache = pkgCache()
    makedirs(join(rpm_download,rpm_partial),True)
    if package.endswith('.rpm'): package = rpm2package (package, opts.architecture)
    if not package in self.cache.packs:
      cmspkg_print("error: unknown pakcage: %s" % package)
      exit(1)
    pk = self.cache.packs[package][self.latest_revision(package)]
    if not self.downloader.run([pk]): exit(1)
    return

  #Clone the remote repository for local distribution
  def clone(self, clone_dir):
    if not self.cache:
      cmspkg_print("Reading Package Lists...")
      self.cache = pkgCache()
    default_trans    = "0000000000000000000000000000000000000000000000000000000000000000"
    repo_dir         = join(clone_dir, opts.repository)
    trans_dir        = join(repo_dir, opts.architecture, default_trans, "RPMS")
    driver_dir       = join(repo_dir, "drivers")
    rpm_download_dir = join(rpm_download,rpm_partial)
    for xdir in [trans_dir, driver_dir, rpm_download_dir]:
      if not exists (xdir): makedirs(xdir, True)

    #Creat Object store shared b/w all repos if requested
    obj_store        = join(clone_dir, ".obj_store", "RPMS", opts.architecture)
    if opts.useStore and not exists(obj_store):  makedirs(obj_store, True)

    #download system files: cmsos
    for sfile in ["cmsos"]:
      download_file_if_changed('file/%s/%s/%s' % (opts.repository, opts.architecture, sfile), join(repo_dir, sfile))
    #download the driver file
    aitems = opts.architecture.split("_")
    driver_arch = opts.architecture
    download_file_if_changed('driver/%s/%s' % (opts.repository, driver_arch), join(driver_dir, driver_arch+"-driver.txt"))
    aitems[-1] = "common"
    driver_arch = "_".join(aitems)
    download_file_if_changed('driver/%s/%s' % (opts.repository, driver_arch), join(driver_dir, driver_arch+"-driver.txt"), optional=True)
    aitems[-2] = "common"
    driver_arch = "_".join(aitems)
    download_file_if_changed('driver/%s/%s' % (opts.repository, driver_arch), join(driver_dir, driver_arch+"-driver.txt"), optional=True)
    #Read existsing package cache
    clone_cache_file = trans_dir+".json"
    clone_cache = {}
    if exists (clone_cache_file):
      clone_cache = json.loads(open(clone_cache_file).read())
      clone_cache.pop('hash',None)
    files2download=[]
    update_hash = False
    on_server = 0 
    on_clone = 0
    valid_clone_files = []
    for pkg in self.cache.packs:
      for r in self.cache.packs[pkg]:
        on_server += 1
        pk = self.cache.packs[pkg][r]
        rcfile = join(pk[0][:2], pk[0], pk[1])
        valid_clone_files.append(rcfile)
        if (pkg in clone_cache) and (r in clone_cache[pkg]) and (clone_cache[pkg][r][0]==pk[0]):
          on_clone += 1
          continue
        if not pkg in clone_cache: clone_cache[pkg]={}
        update_hash = True
        clone_cache[pkg][r]=pk[:-1]
        clone_file = join(trans_dir, rcfile)
        if exists (clone_file): on_clone += 1
        elif opts.useStore:
          obj_store_file = join(obj_store, rcfile)
          if not exists (obj_store_file): files2download.append(pk)
          else:
            run_cmd ("mkdir -p %s && ln %s %s" % (dirname(clone_file), obj_store_file, clone_file))
            on_clone += 1
        else: files2download.append(pk)

    cmspkg_print("Packages on Server: %s" % on_server)
    cmspkg_print("Packages on clone:  %s" % on_clone)
    #download any package which are only available on server
    if files2download:
      ok = self.downloader.run(files2download)
      for pk in files2download:
        download_file = join (rpm_download, pk[1])
        if exists (download_file):
          clone_file = join(trans_dir, pk[0][:2], pk[0], pk[1])
          if opts.useStore:
            obj_store_file = join(obj_store, pk[0][:2], pk[0], pk[1])
            if not exists (obj_store_file): run_cmd ("mkdir -p %s && mv %s %s" % (dirname(obj_store_file), download_file, obj_store_file))
            run_cmd ("mkdir -p %s && ln %s %s" % (dirname(clone_file), obj_store_file, clone_file))
          else:
            run_cmd ("mkdir -p %s && mv %s %s" % (dirname(clone_file), download_file, clone_file))
        else:
          cmspkg_print("Unable to download: %s/%s/%s/%s" % (opts.repository, opts.architecture, pk[0], pk[1]))
          ok = False
      if not ok: exit(1)
    err, all_pakages = run_cmd ("find %s -mindepth 3 -maxdepth 3 -type f -name '*.rpm' | sed 's|^%s/||'" % (trans_dir,trans_dir))
    for rcfile in all_pakages.split("\n"):
      if rcfile in valid_clone_files: continue
      run_cmd ("rm -f %s/%s" % (trans_dir,rcfile))
      cmspkg_print ("Deleted unused file: %s" % rcfile)
    #update hash if needed
    if update_hash:
      clone_cache['hash'] = get_cache_hash(clone_cache, dirname(clone_cache_file))
      save_cache(clone_cache, clone_cache_file)
      if not exists (join(clone_dir, opts.repository, opts.architecture, "latest")):
        run_cmd("ln -s %s %s/%s/%s/latest" % (default_trans, clone_dir, opts.repository, opts.architecture))
    cmspkg_print("Repo successfully cloned")
    return

  #uninstall a package and remove its stamp file
  def remove(self, package):
    self.update_rpm_cache()
    if package in self.rpm_cache:
      if not opts.force: ask_user_to_continue("Are you sure to delete %s (Y/n): " % package)
      cmspkg_print("Removing package %s" % package)
      err, out = run_cmd("%s; rpm %s %s" % (rpm_env, getRPMOptions(['-e'], opts), package))
      package_removed (package)
      cmspkg_print("Removed %s" % package)
      if opts.delete_directory: cleanup_package_dir(package)
    else:
      cmspkg_print("Package %s not installed" % package)
    return

  #upgrade cmspkg client
  def upgrade(self):
    cmspkg_print("Current cmspkg version:   %s" % cmspkg_tag)
    err, out = fetch_url({'uri':'upgrade','info':1})
    reply = json.loads(out)
    check_server_reply(reply)
    cmspkg_print("Available cmspkg version: %s" % reply['version'])
    if not newer_version(reply['version'], cmspkg_tag): return
    if 'changelog' in reply:
      cmspkg_print("---- Change logs ----")
      cmspkg_print("\n".join(reply['changelog'])+"\n")
    if not opts.force: ask_user_to_continue("Are you sure to continue with upgrade (Y/n): ")
    ofile = join(rpm_download, rpm_partial, "cmspkg.py")
    err, out = fetch_url({'uri':'upgrade'},outfile=ofile)
    if not exists(ofile):
      cmspkg_print(out)
      exit(1)
    verify_download(ofile, reply['size'], reply['sha'])
    self.setup(reply['version'], ofile)
    run_cmd("rm -f %s" % ofile)
    cmspkg_print("Running setup for the newly downloaded version.")
    run_cmd("%s/common/cmspkg --architecture %s setup" % (opts.install_prefix, opts.architecture))
    cmspkg_print("Newer cmspkg client installed")
    return

  #setup cmspkg area 
  def setup(self, version, client_file):
    pkg_dir = join(opts.install_prefix, opts.architecture, "cms", "cmspkg", version)
    if not exists (pkg_dir):
      makedirs(pkg_dir, True)
      run_cmd("cp -f %s %s/cmspkg.py && chmod +x %s/cmspkg.py" % (client_file, pkg_dir, pkg_dir))
      outfile = open("%s/rpm_env.sh" % pkg_dir, 'w')
      if outfile:
        outfile.write('source $(ls %s/$1/external/rpm/*/etc/profile.d/init.sh | sed "s|/etc/profile.d/init.sh||" | sort | tail -1)/etc/profile.d/init.sh\n' % opts.install_prefix)
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
      err, prev_version = run_cmd("grep '^###CMSPKG_VERSION=V' %s | sed 's|.*=V|V|'" % common_cmspkg, outdebug=False, exit_on_error=False)
      if (prev_version=="") or newer_version(cmspkg_tag, prev_version): force=True
    self.update_common_cmspkg(common_cmspkg, force)
    cmspkg_print("cmspkg setup done.")
    return

  def update_common_cmspkg(self, common_cmspkg, force=False):
    if not force and exists(common_cmspkg): return
    makedirs(dirname(common_cmspkg))
    exOpt=""
    if opts.useDev: exOpt="--use-dev"
    if opts.server_path: exOpt=exOpt + " --server-path %s " % opts.server_path
    cmspkg_str = ["#!/bin/bash","#This file is automatically generated by cmspkg setup command. Please do not edit it.", "###CMSPKG_VERSION=%s" % cmspkg_tag]
    cmspkg_str.append('$(/bin/ls %s/share/cms/cmspkg/V*/cmspkg.py | tail -1) --path %s --repository %s --server %s %s "$@"\n' % (opts.install_prefix, opts.install_prefix, opts.repository, opts.server, exOpt))
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
  def dist_clean(self):
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

    keep_regexp = [compile("^"+x+".*$") for x in pkgs_to_keep]
    explicit_pkgs = {}
    if exists(pkgs_dir):
      for pkg in glob(pkgs_dir+"/*+*+*"):
        explicit_pkgs[basename(pkg)]=1
    cmsdistrc_dir = join(opts.install_prefix, opts.architecture, ".cmsdistrc")
    if exists (cmsdistrc_dir):
      for pkg in glob(cmsdistrc_dir+"/PKG_*+*+*"):
        explicit_pkgs[basename(pkg)[4:]]=1
    for pkg in explicit_pkgs:
      keep_regexp.append(compile("^"+escape(pkg)+"$"))
    self.update_rpm_cache(True)
    cache = {"RPMS" : {}, "KEPT": {}, "CHECK" : {}}
    for pkg in self.rpm_cache:
      if not match("^(cms|external|lcg)[+].+",pkg): continue
      cache["RPMS"][pkg]={"USEDBY":{}}

    for pkg in sorted(cache["RPMS"].keys()):
      for exp in keep_regexp:
        if not match(exp, pkg): continue
        keepPack(pkg, cache)
        break

    for pkg in sorted(cache["RPMS"].keys()): checkDeps(pkg, cache)
    if not cache["RPMS"]:
      cmspkg_print("Nothing to clean")
      return

    cmspkg_print("Following packages will be removed from the installation:")
    cmspkg_print("  "+"\n  ".join(sorted(cache["RPMS"].keys())))
    if not opts.force: ask_user_to_continue("Are you sure to remove above packages (Y/n): ")
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
        cmspkg_print("Removing %s" % pkgs)
        err, out = run_cmd("%s; rpm -e %s" % (rpm_env, pkgs))
        if opts.delete_directory:
          for pkg in rpms2del: cleanup_package_dir(pkg)
        rpms2del =[]
    if rpms2del:
      pkgs = " ".join(rpms2del)
      cmspkg_print("Removing %s" % pkgs)
      err, out = run_cmd("%s; rpm -e %s" % (rpm_env, pkgs))
      if opts.delete_directory:
        for pkg in rpms2del: cleanup_package_dir(pkg)
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
    if syscall(cmd)>0: exit(1)
  if args[0] in ["rpmenv", "env"]:
    cmd = rpm_env+" ; "+args[1]
    for a in args[2:]: cmd+=" '"+a+"'"
    if syscall(cmd)>0: exit(1)

  if not exists (cache_dir): makedirs(cache_dir,True)
  err, out = run_cmd("touch %s/check.write.permission && rm -f %s/check.write.permission" % (cache_dir, cache_dir), exit_on_error=False)
  if err:
    cmspkg_print("Error: You do not have write permission for installation area %s" % opts.install_prefix)
    exit(1)
  lock = None
  if args[0] not in ["download"]:
    lock = cmsLock(cache_dir)
    if not lock:
      cmspkg_print("Error: Unable to obtain lock, there is already a process running")
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
      for pkg in args[1:]: repo.remove(pkg)
      if opts.dist_clean:  repo.dist_clean()
    elif args[0] in ["dist-clean"]:
      repo.dist_clean()
    elif args[0] in ["clone"]:
      repo.update(force=opts.force)
      repo.clone(opts.install_prefix)
    elif args[0] == "search":
      if not exists (join(cache_dir , "active")): repo.update(True)
      pkg = ""
      if len(args)==2: pkg =args[1]
      repo.search(pkg, exact=opts.force)
    elif args[0] == "showpkg":
      if not exists (join(cache_dir , "active")): repo.update(True)
      repo.showpkg(args[1])
    elif args[0] == "depends":
      if not exists (join(cache_dir , "active")): repo.update(True)
      repo.depends(args[1])
    elif args[0] == "show":
      if not exists (join(cache_dir , "active")): repo.update(True)
      repo.show(args[1])
    elif args[0] == "upgrade":
      repo.upgrade()

if __name__ == '__main__':
  from optparse import OptionParser
  cmspkg_cmds = ["update","search","install","reinstall","clean","remove","dist-clean","show","download", "rpm", "rpmenv", "env", "clone", "setup","upgrade", "showpkg", "depends", "repository"]
  parser = OptionParser(usage=basename(argv[0])+" -a|--architecture <arch>\n"
  "              -s|--server <server>\n"
  "              -r|--repository <repository>\n"
  "              -p|--path <path>\n"
  "              [-j|--jobs num]\n"
  "              [-f|-y|--force]\n"
  "              [-d|--debug]\n"
  "              [-c|--dist-clean]\n"
  "              [-v|--version]\n"
  "              [--show-revision]\n"
  "              [--use-dev]\n"
  "              [--reinstall]\n"
  "              "+" | ".join(cmspkg_cmds)+" [package| -- <rpm-args>]\n\n")
  parser.add_option("--reinstall",         dest="reinstall", action="store_true", default=False, help="Reinstall a package e.g. its latest revision")
  parser.add_option("-f", "--force",       dest="force",     action="store_true", default=False, help="Force an update or installation")
  parser.add_option("-y",                  dest="force",     action="store_true", default=False, help="Assume yes for installation")
  parser.add_option("-d", "--debug",       dest="debug",     action="store_true", default=False, help="Print more debug outputs")
  parser.add_option("-v", "--version",     dest="version",   action="store_true", default=False, help="Print version string")
  parser.add_option("--show-revision",     dest="show_revision", action="store_true", default=False, help="Used with search command to show also the revision of the package(s)")
  parser.add_option("--use-dev",           dest="useDev",    action="store_true", default=False, help="Use development server instead of production")
  parser.add_option("--ignore-known",      dest="IgnoreKbe", action="store_true", default=False, help="Ignore known errors")
  parser.add_option("--use-store",         dest="useStore",  action="store_true", default=False, help="Use object store when running clone. This avoids downloading same file if exists in multiple repositories.")
  parser.add_option("--ignore-size",       dest="IgnoreSize",     action="store_true", default=False, help="Ignore RPM size checks")
  parser.add_option("--add-options",       dest="Add_Options",    action='append',     default=[], help="Add extra RPM install options. You can use it multiple time or CSV to add more than one options")
  parser.add_option("--remove-options",    dest="Remove_Options", action='append',     default=[], help="Remove default RPM install options. You can use it multiple time or CSV to remove more than one options")
  parser.add_option("-a", "--architecture",dest="architecture", default=None,                    help="Architecture string")
  parser.add_option("-r", "--repository",  dest="repository",   default="cms",                   help="Repository name defalut is cms")
  parser.add_option("-p", "--path",        dest="install_prefix",default=getcwd(),               help="Install path.")
  parser.add_option("-j", "--jobs",        dest="jobs",         default=4, type="int",           help="Max parallel downloads")
  parser.add_option("-s", "--server",      dest="server",       default="cmsrep.cern.ch",        help="Name of cmsrep server, default is cmsrep.cern.ch")
  parser.add_option("-S", "--server-path", dest="server_path",  default=None,                    help="Path of repo on server.")
  parser.add_option("-c", "--dist-clean",  dest="dist_clean",   action="store_true", default=False,   help="Only used with 'remove' command to do the distribution cleanup after the package removal.")
  parser.add_option("-D", "--delete-dir",  dest="delete_directory",action="store_true",default=False, help="Only used with 'remove/dist_clean' command to do cleanup the package install directory.")
  parser.add_option("-o", "--download-options",  dest="download_options", default=None,          help="Extra options to pass to wget/curl.")

  opts, args = parser.parse_args()
  if opts.version:
    cmspkg_print(cmspkg_tag)
    exit(0)
  if len(args) == 0: parser.error("Too few arguments")
  if not opts.architecture: parser.error("Missing architecture string")
  if not opts.server: parser.error("Missing repository server name")
  if not opts.repository: parser.error("Missing repository name")
  if not opts.install_prefix: parser.error("Missing install path string")
  if opts.useDev: cmspkg_cgi = cmspkg_cgi+'-dev'
  if not opts.server_path: opts.server, opts.server_path = get_server_paths (opts.server)

  if args[0]=="repository":
    print "Server:",opts.server
    print "Repository:",opts.repository
    print "ServerPath:",opts.server_path
    exit (0)
  cmspkg_local_dir = join(opts.install_prefix, opts.architecture, 'var/cmspkg')
  if not args[0] in ["clone", "download", "setup"]:
    rpm_env = join(dirname(script_path), "rpm_env.sh")
    if not exists (rpm_env):
      cmspkg_print("Error: Unable to find rpm installation. Are you sure you have a bootstrap area?")
      exit(1)
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
  elif (args[0] in ["showpkg", "depends"]):
    if len(args) != 2: parser.error("Too many/few arguments")
  if args[0] == "reinstall": opts.reinstall = True

  process(args, opts, cache_dir)
