## CMSPKG puppet provider.

A `cmspkg` provider for the package resource which allows you to install CMSSW
and related packages using cmspkg.

The `cmspkg` provider extends the standard puppet `package` resource.

## Installing CMSSW, puppet way:

A simple example is:

    package {"cms+cmssw+CMSSW_8_0_10":
      ensure => present,
      provider => cmspkg,
    }

this will setup a CMSSW installation area in `/opt/cms` using the default
architecture `slc6_amd64_gcc530`, owned by `cmsbuild` and install
`cms+cmssw+CMSSW_8_0_10` there. Packages will be downloaded from the standard CMS
repository, `https://cmsrep.cern.ch/cmssw/cms`.

### Customising installation

Notice that the installation prefix, the architecture and the installation user
can be configured using the the `install_options` property of the package
resource. The above is equivalent to:

    package {"cms+cmssw+CMSSW_8_0_10":
      ensure          => present,
      provider        => cmspkg,
      install_options => [{
        "prefix"        => "/opt/cms",
        "user"          => "cmsbuild",
        "architecture"  => "slc6_amd64_gcc530",
        "server"        => "cmsrep.cern.ch",
        "repository"    => "cms",
        "bootstrap_opts"=> ["-additional-provides", "libGL"],
        "reseed"        => "",
      }]
    }

Available options for `install_options` property are:
 - **prefix**: Install path where CMSSW releases should be installed. Default is `/opt/cms`
 - **user**:   Linux user which should be the owner of the installation. Default is `cmsbuild`
 - **architecture**: Architecture for which the package should be installed. Note that it will be overridden if package name contains `/architecture` in it. Default is `slc6_amd64_gcc530`
 - **server**: `cmspkg` server name. If package are available in `server.domain:DOCUMENT_ROOT/some/path/cmssw` then set this value to `server.domain/some/path`. Note that last `cmssw` is not part of it. Default value is `cmsrep.cern.ch`
 - **repository**: `cmspkg` repository from which RPMs are downloaded. Default is `cms`.
 - **dist_clean**: If set (any value) then `cmspkg` will also cleanup/remove any unused package. Default is to not remove the packages not used by any other package.
 - **package_clean**: If set (any value) then `cmspkg` will force delete the package directory i.e. `prefix/architecture/group/name/version` after the package removal. Defaultis to not remove package directory.
 - **bootstrap_opts**: If set (any value) then these will be passed to bootstrap script.
 - **reseed**: Run bootstrap reseeding once. Set it to some unique value e.g timestamp to trigger the reseeding. Reseeing is run once per value so change its value in order to re-run reseeding.

### Installing multiple packages

Multiple packages can be installed as usual either by repeating the resource
declaration or passing a list as name. E.g.:

    package {["cms+cmssw+CMSSW_8_0_8", "cms+cmssw+CMSSW_8_0_10"]:
      ensure => present,
      provider => cmspkg,
    }

will happily install both `cms+cmssw+CMSSW_8_0_8` and `cms+cmssw+CMSSW_8_0_10`.

### Installing multiple architectures

In case you want to install a given package for more than one architecture, you
can append the architecture to the package name like the following:

    package {["cms+cmssw+CMSSW_8_0_10/slc6_amd64_gcc493",
              "cms+cmssw+CMSSW_8_0_10/slc6_amd64_gcc530"]:
      ensure => present,
      provider => cmspkg,
    }

notice that in this case the architecture specified in `options` will
simply be ignored.

## Prerequisites for non-CMS machines.

The above assume that you have a machine which already has all the system
dependencies to install CMSSW. This is not the case if you are running off a
vanilla SLC6 installation, since it's lacking a few packages and directories.

A complete example of a puppet manifest which works is:

    # An example puppet file which installs CMSSW into
    # /opt/cms.

    package {["HEP_OSlibs_SL6", "e2fsprogs"]:
      ensure => present,
    }->
    file {"/etc/sudoers.d/999-cmsbuild-requiretty":
       content => "Defaults:root !requiretty\n",
    }->
    user {"someuser":
      ensure => present,
    }->
    file {"/opt":
      ensure => directory,
    }->
    file {"/opt/cms":
      ensure => directory,
      owner => "someuser",
    }->
    package {"cms+cmssw+CMSSW_8_0_10":
      ensure             => present,
      provider           => cmspkg,
      install_options    => [{
        "prefix"         => "/opt/cms",
        "user"           => "someuser",
        "architecture"   => "slc6_amd64_gcc530",
        "server"         => "cmsrep.cern.ch",
        "bootstrap_opts" => ["-additional-provides", "libGL,libaio"],
      }]
    }
