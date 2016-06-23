#What is cmspkg:

cmspkg is collection of helper script used by http://github.com/cms-sw/pkgtools for building and distribution http://github.com/cms-sw/cmssw RPMs. It is to replace the apt-get usage.

##Releases
###V00-00-00:
 - @smuzaffar 2016-05-24: Initial version with basic commands working

###V00-00-01:
 - @smuzaffar 2016-06-22: Added **setup**, **clone** and **upgrade** commands
   - **setup**: It create wrapper script and RPM environment scripts.
   - **clone**: To clone an existsing repository on to a different server.
   - **upgrade**: Download and install new cmspkg client is available.
