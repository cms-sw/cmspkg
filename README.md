#What is cmspkg

cmspkg is collection of helper script used by http://github.com/cms-sw/pkgtools for building and distributing http://github.com/cms-sw/cmssw RPMs. It is to replace the apt-get usage.
cmspkg puppet package provider documentation is available [here](https://github.com/cms-sw/cmspkg/blob/master/cmspkg-puppet-provider.md)

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
 - @smuzaffar 2016-06-24: Bug fix, Fixed re-try logic for downloading pakages.

###V00-00-05:
 - @smuzaffar 2016-06-28: New -D|--delete-dir option to force deletion of package directory

###V00-00-06:
 - @smuzaffar 2016-06-30: Always download and verify new cmsos amd drivers file for clone. 

###V00-00-07:
 - @smuzaffar 2016-07-01: Added showpkg command to show all revisions of a package.

###V00-00-08:
 - @smuzaffar 2016-07-01: Bug fix, make sure that download directory exists before fetching a file.



