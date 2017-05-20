#What is cmspkg

`cmspkg` is collection of helper script used by http://github.com/cms-sw/pkgtools for building and distributing http://github.com/cms-sw/cmssw RPMs. It is to replace the `apt` usage.
`cmspkg` puppet package provider documentation is available [here](https://github.com/cms-sw/cmspkg/blob/master/cmspkg-puppet-provider.md)

Converting `apt`-speak to `cmspkg`-speak is mostly replacing `apt-*` commands with `cmspkg -a arch`. Not all apt-* commands are available in cmspkg. See the table below for details

Purpose | APT | CMSPKG
--------|----------|-------------
Retrieve/update new lists of packages | `apt-get update` | `cmspkg -a arch update`
Install new packages | `apt-get -y install package` | `cmspkg -a arch -y install package`
Reinstalling an installed package</td> | `apt-get reinstall package`</td> | `cmspkg -a arch reinstall package`</td>
Reinstalling an installed package | `apt-get --reinstall install package` | `cmspkg -a arch --reinstall install package`
Remove packages | `apt-get remove package` | `cmspkg -a arch remove package`
Cleaup downloaded package files | `apt-get clean` | `cmspkg -a arch clean`
Perform an upgrade | `apt-get upgrade` | `cmspkg -a arch upgrade`
Remove unused not-explicitly installed packages | `-` | `cmspkg -a arch dist-clean`
Search a package | `apt-cache search package` | `cmspkg -a arch search package`
Show some general information for a single package | `apt-cache showpkg package` | `cmspkg -a arch showpkg package`
Show a readable record for the package | `apt-cache show package` | `cmspkg -a arch show package`
Shows listing of dependency of a package | `apt-cache depends package` | `cmspkg -a arch depends package`

`cmspkg` internally sources the latest available `rpm` env, so no need to source `apt/rpm init.[sh|csh]` script before running `cmspkg` commands.

To run `rpm` commands, one can use `cmspkg -a arch rpm -- <rpm command and options>`

#Usage:

##Bootstrap:
  - ARCH=slc6_amd64_gcc530
  - INSTALL_DIR=/path/to/install
  - wget http://cmsrep.cern.ch/cmssw/repos/bootstrap.sh
  - sh -ex ./bootstrap.sh -r cms -a $ARCH -p $INSTALL_DIR setup
  
##Search Packages:
  - $INSTALL_DIR/common/cmspkg -a $ARCH search cmssw
  
##Install Package:
  - $INSTALL_DIR/common/cmspkg -a $ARCH -y installed cms+cmssw+CMSSW_9_2_0

##Releases
###V00-00-00:
 - @smuzaffar 2016-05-24: Initial version with basic commands working

###V00-00-01:
 - @smuzaffar 2016-06-22: Added **setup**, **clone** and **upgrade** commands
   - **setup**: It create wrapper script and RPM environment scripts.
   - **clone**: To clone an existsing repository on to a different server.
   - **upgrade**: Download and install new cmspkg client is available.

###V00-00-02:
 - @smuzaffar 2016-06-24: Correctly find the server cgi-bin path and repository directory from the server URL.

###V00-00-03:
 - @smuzaffar 2016-06-24:
   - Correctly inform user is he/she does not have write permission to install
   - For dist-clean options, force delete the package install directory install-prefix/arch/pkg-group/pkg-name/pkg-version
   - Avoid sending duplicate paramters to server.

###V00-00-04:
 - @smuzaffar 2016-06-24: Bug fix, Fixed re-try logic for downloading packages.

###V00-00-05:
 - @smuzaffar 2016-06-28: New -D|--delete-dir option to force deletion of package directory

###V00-00-06:
 - @smuzaffar 2016-06-30: Always download and verify new cmsos amd drivers file for clone. 

###V00-00-07:
 - @smuzaffar 2016-07-01: Added showpkg command to show all revisions of a package.

###V00-00-08:
 - @smuzaffar 2016-07-01: Bug fix, make sure that download directory exists before fetching a file.

###V00-00-09:
 - @smuzaffar 2016-07-11:
   - Code cleanup: Import only what is needed
   - Use subprocess.Popen if commands.getstatusoutput  is not available (e.g. in python 3.0)

###V00-00-10:
 - @smuzaffar 2016-07-12: Bug fix, avoid override of exit function call

###V00-00-11:
 - @smuzaffar 2016-07-12: Bug fix, avoid override of exit function call

###V00-00-12:
 - @smuzaffar 2016-07-12: updates to make the cmspkg client work with python3.x

###V00-00-13:
 - @smuzaffar 2016-07-13: Fixes to make it work with python 2.4 and above

###V00-00-14:
 - @smuzaffar 2016-07-13: Typo

###V00-00-15:
 - @smuzaffar 2016-07-20: Fixes for OSX
   - Use md5 -q
   - Use shasum -a 256

###V00-00-16:
 - @smuzaffar 2016-07-22: Make sure that cmspkg.py exit with non-zero code if failed to install RPMs.

###V00-00-17:
 - @smuzaffar 2016-08-08: New command 'depends' to show the dependencies of a package.

###V00-00-18:
 - @smuzaffar 2016-08-15: Check output of 'rpm' command as it does not always exit with non-zero code on errors.

###V00-00-19:
 - @smuzaffar 2016-08-19: new command rpmenv to run any command under rpm env e.g. cmspkg -a arch rpmenv -- rpmdb --rebuild

###V00-00-20:
 - @smuzaffar 2016-10-24: New option --use-store for clone command
   - To create a common store for all cloned repositories
   - Avoid downloading same RPM is available in multiple repos.

###V00-00-21:
 - @smuzaffar 2016-11-28: Send timestamp with caches/cache requests to always get the latest results.

###V00-00-22:
 - @smuzaffar 2017-02-16: Fix rpm version sort login.
   - New command "env" same as "rpmenv"

###V00-00-23:
 - @smuzaffar 2017-04-12: Make search command also show revision if --show-revision is set.

