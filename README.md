# CMSPKG

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

# Usage
## Bootstrap
```
  ARCH=slc6_amd64_gcc530
  INSTALL_DIR=/path/to/install
  wget http://cmsrep.cern.ch/cmssw/repos/bootstrap.sh
  sh -ex ./bootstrap.sh -r cms -a $ARCH -p $INSTALL_DIR setup
```  
## Search Packages
```
  $INSTALL_DIR/common/cmspkg -a $ARCH search cmssw
```
## Install Package
```
  $INSTALL_DIR/common/cmspkg -a $ARCH -y install cms+cmssw+CMSSW_9_2_0
```
## Releases Notes

### V00-00-00:
 - @smuzaffar 2016-05-24: Initial version with basic commands working

### V00-00-01:
 - @smuzaffar 2016-06-22: Added **setup**, **clone** and **upgrade** commands
   - **setup**: It create wrapper script and RPM environment scripts.
   - **clone**: To clone an existsing repository on to a different server.
   - **upgrade**: Download and install new cmspkg client is available.

### V00-00-02:
 - @smuzaffar 2016-06-24: Correctly find the server cgi-bin path and repository directory from the server URL.

### V00-00-03:
 - @smuzaffar 2016-06-24:
   - Correctly inform user is he/she does not have write permission to install
   - For dist-clean options, force delete the package install directory install-prefix/arch/pkg-group/pkg-name/pkg-version
   - Avoid sending duplicate paramters to server.

### V00-00-04:
 - @smuzaffar 2016-06-24: Bug fix, Fixed re-try logic for downloading packages.

### V00-00-05:
 - @smuzaffar 2016-06-28: New -D|--delete-dir option to force deletion of package directory

### V00-00-06:
 - @smuzaffar 2016-06-30: Always download and verify new cmsos amd drivers file for clone. 

### V00-00-07:
 - @smuzaffar 2016-07-01: Added showpkg command to show all revisions of a package.

### V00-00-08:
 - @smuzaffar 2016-07-01: Bug fix, make sure that download directory exists before fetching a file.

### V00-00-09:
 - @smuzaffar 2016-07-11:
   - Code cleanup: Import only what is needed
   - Use subprocess.Popen if commands.getstatusoutput  is not available (e.g. in python 3.0)

### V00-00-10:
 - @smuzaffar 2016-07-12: Bug fix, avoid override of exit function call

### V00-00-11:
 - @smuzaffar 2016-07-12: Bug fix, avoid override of exit function call

### V00-00-12:
 - @smuzaffar 2016-07-12: updates to make the cmspkg client work with python3.x

### V00-00-13:
 - @smuzaffar 2016-07-13: Fixes to make it work with python 2.4 and above

### V00-00-14:
 - @smuzaffar 2016-07-13: Typo

### V00-00-15:
 - @smuzaffar 2016-07-20: Fixes for OSX
   - Use md5 -q
   - Use shasum -a 256

### V00-00-16:
 - @smuzaffar 2016-07-22: Make sure that cmspkg.py exit with non-zero code if failed to install RPMs.

### V00-00-17:
 - @smuzaffar 2016-08-08: New command 'depends' to show the dependencies of a package.

### V00-00-18:
 - @smuzaffar 2016-08-15: Check output of 'rpm' command as it does not always exit with non-zero code on errors.

### V00-00-19:
 - @smuzaffar 2016-08-19: new command rpmenv to run any command under rpm env e.g. cmspkg -a arch rpmenv -- rpmdb --rebuild

### V00-00-20:
 - @smuzaffar 2016-10-24: New option --use-store for clone command
   - To create a common store for all cloned repositories
   - Avoid downloading same RPM is available in multiple repos.

### V00-00-21:
 - @smuzaffar 2016-11-28: Send timestamp with caches/cache requests to always get the latest results.

### V00-00-22:
 - @smuzaffar 2017-02-16: Fix rpm version sort login.
   - New command "env" same as "rpmenv"

### V00-00-23:
 - @smuzaffar 2017-04-12: Make search command also show revision if --show-revision is set.

### V00-00-24:
 - @smuzaffar 2017-10-04: Added -o|--download-options 'download options' to be passed to curl|wget.

### V00-00-25:
 - @smuzaffar 2017-11-03: Added repository command to get the repository/server details.

### V00-00-26:
 - @smuzaffar 2018-03-19: Do not remove cms+cmsswdata+ packages as they are shared between architectures.

### V00-00-27:
 - @smuzaffar 2018-05-17: New option added to Ignore known RPM errors.

### V00-00-28:
 - @smuzaffar 2018-11-26: New options added to be passed to underlying RPM commands.

### V00-00-29:
 - @mrodozov 2019-01-25: Use RPM query info package to get size of the package. Using --queryformat %SIZE fails for size over 4GB

### V00-00-30:
 - @smuzaffar 2019-03-18: Do not create lock for download command.

### V00-00-31:
 - @smuzaffar 2019-08-23: Update clone to copy common driver files

### V00-00-32:
 - @smuzaffar 2019-08-23: Do not fail if optional files not found.

### V00-00-33:
 - @smuzaffar 2019-08-23: Make use of new optional parameter to check for optional files.

### V00-00-34:
 - @smuzaffar 2019-10-05: Python3 fix, use cmspkg_print

### V00-00-35:
 - @smuzaffar 2019-11-22: Ignore size checks for installing releases.

### V00-00-36:
 - @smuzaffar 2020-01-21: New --install-only option to install package without its dependencies

### V00-00-37:
 - @smuzaffar 2020-01-23: Fixed some typos

### V00-00-38:
 - @smuzaffar 2020-06-12: Fix regexp for matching the rpm size. It was failing for slc5 cms-sw/cms-docker#65

### V00-00-39
 - @smuzaffar 2020-10-20: Added --reference option to use a local install directory and create symlinks for already installed packages.

### V00-00-40
 - @smuzaffar 2020-10-21: Install multiple packages in one go. This avoid reading RPM DB multiple times.

### V00-00-41
 - @smuzaffar 2020-10-30: Cleanup obsolete APT code

### V00-00-42
 - @smuzaffar 2020-11-24: Support to show multiple packages.

### V00-00-43
 - @smuzaffar 2020-12-10: Drop cmsos as it is now taken from original cms-common repository.

### V00-00-44
 - @smuzaffar 2021-02-17: Clone system files e.g. cmsos, bootstrap.sh and README.md

### V00-00-45
 - @smuzaffar 2021-03-24: Bug fix, cmspkg failed to install if multiple packages are provided and last one is already installed.

### V00-00-46
 - @smuzaffar 2021-03-25: Revert last change

### V00-00-47
 - @smuzaffar 2021-09-10: Use python3 as default otherwise fallback to python.

### V00-00-48
 - @smuzaffar 2021-11-29: Fixes for running under QEMU

### V00-00-49
 - @smuzaffar 2022-02-28: For cmspkg remove command, covert RPM name to cmspkg name

### V00-01-00
 - @smuzaffar 2022-03-12: Run OS specific commands under CMSPKG_OS_COMMAND if set. This allow to run most of the cmspkg command on host.

### V00-01-01
 - @smuzaffar 2022-03-13: Big fix for large RPM sizes

### V00-01-02
 - @smuzaffar 2022-03-13: Fixes for qemu printouts

### V00-01-03
 - @smuzaffar 2022-03-13: Fix typo

### V00-01-04
 - @smuzaffar 2022-03-13: Use system rpm for getting rpm file expand size and requirements

### V00-01-05
 - @smuzaffar 2022-03-13: New --upgrade-packages options for upgrade command added. Thsi should update default packages like cms-common

### V00-01-06
 - @smuzaffar 2022-03-13: Fixes for package clean

### V00-01-07
 - @smuzaffar 2022-03-13: Fix dist-clean and reference install bug

### V00-01-09
 - @smuzaffar 2022-03-15: Print upgrade packages details

### V00-01-10
 - @smuzaffar 2022-03-18: Set various LANG and LC_ env to about perl warnings.

### V00-01-11
 - @smuzaffar 2022-11-16: Added --no-reference option to skip creating symlinks for selected packages.

### V00-01-12
 - @smuzaffar 2022-11-16: Fix no-reference packages

### V00-01-13
 - @smuzaffar 2022-11-21: Remove qemu: Unsupported syscall: messages from cmd output

### V00-01-14
 - @smuzaffar 2022-11-27: --build-order option added to show searched packages in build order (latest first)

### V00-01-15
 - @smuzaffar 2023-02-02: Bug fix: Make sure to convert package revision number to int before comparison

### V00-01-16
 - @sumuzaffar 2023-11-27 Apply ROOT WebGUI patch for root packages 6.26-6.31

### V00-01-17
 - @sumuzaffar 2023-11-28 Bug fix for python2
