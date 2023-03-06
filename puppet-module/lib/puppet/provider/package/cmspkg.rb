require "pathname"
require "puppet/provider/package"
require "puppet/util/execution"

Puppet::Type.type(:package).provide :cmspkg, :parent => Puppet::Provider::Package do
  include Puppet::Util::Execution

  desc "CMS packages via cmspkg."

  has_feature :unversionable
  has_feature :package_settings
  has_feature :install_options

  def self.home
    if boxen_home = Facter.value(:boxen_home)
      "#{boxen_home}/homebrew"
    else
      "/opt/cms"
    end
  end

  def self.default_architecture
    "slc6_amd64_gcc530"
  end

  def self.default_cms_user
    "cmsbuild"
  end

  def self.default_repository
    return "cms"
  end

  def self.default_server
    return "cmsrep.cern.ch"
  end

  def self.default_dist_clean
    return "false"
  end

  def self.default_package_clean
    return "false"
  end

  def self.default_bootstrap_opts
    return []
  end

  def self.default_reseed
    return ""
  end

  def get_install_options
    opts = {}
    if @resource[:install_options].is_a?(Array)
      opts = @resource[:install_options][0]
    elsif @resource[:install_options].is_a?(Hash)
      opts=@resource[:install_options]
    else
      Puppet.debug "install_options not specified. Using default."
    end
    opts["prefix"]         = (opts["prefix"]       or self.class.home)
    opts["user"]           = (opts["user"]         or self.class.default_cms_user)
    opts["repository"]     = (opts["repository"]   or self.class.default_repository)
    opts["server"]         = (opts["server"]       or self.class.default_server)
    opts["architecture"]   = (opts["architecture"] or self.class.default_architecture)
    opts["bootstrap_opts"] = (opts["bootstrap_opts"] or self.class.default_bootstrap_opts)
    opts["reseed"]         = (opts["reseed"]         or self.class.default_reseed)
    opts["name"], overwrite_architecture = @resource[:name].split "/"
    opts["architecture"] = (overwrite_architecture and overwrite_architecture or opts["architecture"])
    return opts
  end

  def self.cmspkg_setup?(prefix)
    Puppet.debug "Checking if cmspkg setup is already available in #{prefix}."
    return File.exists? File.join([prefix, "common", "cmspkg"])
  end

  def self.bootstrapped?(architecture, prefix)
    Puppet.debug "Checking if #{architecture} bootstrapped in #{prefix}."
    return File.exists? File.join([prefix, architecture, "cms", "cms-common", "1.0", "etc", "profile.d", "init.sh"])
  end

  # Helper function to boostrap a CMS environment.
  def setup_cmspkg(architecture, prefix, user, repository, server)
    Puppet.debug("Running cmspkg setup in #{prefix} for #{architecture} architecture and assigning it to #{user}")
    Puppet.debug("Fetching cmspkg client #{repository}")
    execute ["sudo", "-u", user,
             "wget", "--no-check-certificate", "-O",
             File.join([prefix, "cmspkg.py"]),
             "#{server}/cmssw/repos/cmspkg.py"]
    Puppet.debug("Installing cmspkg client.")
    execute ["sudo", "-u", user,
             "python", File.join([prefix, "cmspkg.py"]),
             "-y", "--path", prefix,
             "--architecture", architecture,
             "--server", server,
             "--repository", repository,
             "setup"]
    Puppet.debug("cmspkg setup completed")
  end

  def reseed(architecture, prefix, user, repository, server, bootstrap_opts, reseed_value)
    begin
      reseed_file = File.join([prefix, "bootstrap-reseed-#{reseed_value}"])
      Puppet.debug("Checking reseed #{reseed_file}.")
      if File.exists? reseed_file
        return
      end
      Puppet.debug("Fetching bootstrap from #{repository}")
      execute ["sudo", "-u", user,
               "wget", "--no-check-certificate", "-O",
               File.join([prefix, "bootstrap-#{architecture}.sh"]),
               "#{server}/cmssw/repos/bootstrap.sh"]
      Puppet.debug("Reseeding bootstrap area..")
      execute ["sudo", "-u", user,
               "sh", "-x", File.join([prefix, "bootstrap-#{architecture}.sh"]),
               "reseed",
               "-path", prefix,
               "-arch", architecture,
               "-server", server,
               "-repository", repository,
               "-assume-yes",
               bootstrap_opts]
      execute ["sudo", "-u", user, "touch", "#{reseed_file}"]
      Puppet.debug("Reseed completed")
    rescue Exception => e
      Puppet.warning "Unable to create / find installation area. Please check your install_options."
      raise e
    end
  end

  def bootstrap(architecture, prefix, user, repository, server, bootstrap_opts)
    begin
      if self.class.bootstrapped?(architecture, prefix)
        execute ["chown","-R", user, File.join([prefix, architecture , "var/lib/rpm"])]
        Puppet.debug("Bootstrap already done.")
        if self.class.cmspkg_setup?(prefix)
          Puppet.debug("cmspkg setup already done.")
          return
        else
          setup_cmspkg(architecture, prefix, user, repository, server)
          return
        end
      end
      Puppet.debug("Creating #{prefix} and assigning it to #{user}")
      execute ["mkdir", "-p", prefix]
      execute ["chown", user, prefix]
      Puppet.debug("Fetching bootstrap from #{repository}")
      execute ["sudo", "-u", user,
               "wget", "--no-check-certificate", "-O",
               File.join([prefix, "bootstrap-#{architecture}.sh"]),
               "#{server}/cmssw/repos/bootstrap.sh"]
      Puppet.debug("Installing CMS bootstrap.")
      execute ["sudo", "-u", user,
               "sh", "-x", File.join([prefix, "bootstrap-#{architecture}.sh"]),
               "setup",
               "-path", prefix,
               "-arch", architecture,
               "-server", server,
               "-repository", repository,
               "-assume-yes",
               bootstrap_opts]
      Puppet.debug("Bootstrap completed")
    rescue Exception => e
      Puppet.warning "Unable to create / find installation area. Please check your install_options."
      raise e
    end
  end

  def install
    opts = self.get_install_options
    bootstrap(opts["architecture"], opts["prefix"], opts["user"], opts["repository"], opts["server"], opts["bootstrap_opts"])
    if opts["reseed"] != ""
      reseed(opts["architecture"], opts["prefix"], opts["user"], opts["repository"], opts["server"], opts["bootstrap_opts"], opts["reseed"])
    end
    cmspkg_cmd = opts["prefix"]+"/common/cmspkg -a "+opts["architecture"]
    cmd = "sudo -u "+opts["user"]+" bash -c '#{cmspkg_cmd} -y --upgrade-packages upgrade && #{cmspkg_cmd} update && #{cmspkg_cmd} -y install "+opts["name"]+" 2>&1'"
    Puppet.debug("Installing "+opts["name"]+" for "+opts["architecture"])
    output = `#{cmd}`
    Puppet.debug output
    if $?.to_i != 0
      raise Puppet::Error, "Could not install package. #{output}"
    end
    $?.to_i
  end

  def uninstall
    opts = self.get_install_options
    bootstrap(opts["architecture"], opts["prefix"], opts["user"], opts["repository"], opts["server"], opts["bootstrap_opts"])
    dist_clean = ""
    pack_clean = ""
    if opts.key?("dist_clean")
      dist_clean = "--dist-clean"
    end
    if opts.key?("package_clean")
      pack_clean = "--delete-dir"
    end
    cmspkg_cmd = opts["prefix"]+"/common/cmspkg -a "+opts["architecture"]
    cmd = "sudo -u "+opts["user"]+" bash -c '#{cmspkg_cmd} -y #{dist_clean} #{pack_clean} remove "+opts["name"]+" 2>&1'"
    Puppet.debug("Removing "+opts["name"]+" for "+opts["architecture"])
    Puppet.debug("#{cmd}")
    output = `#{cmd}`
    Puppet.debug output
    if $?.to_i != 0
      raise Puppet::Error, "Could not remove package. #{output}"
    end
    $?.to_i
  end

  def query
    opts = self.get_install_options
    Puppet.debug "Query invoked with "+opts["prefix"]+" "+opts["architecture"]+" "+opts["user"]+" "+opts["name"]
    group, package, version = opts["name"].split "+"
    bootstrap(opts["architecture"], opts["prefix"], opts["user"], opts["repository"], opts["server"], opts["bootstrap_opts"])
    existance = File.exists? File.join([opts["prefix"], opts["architecture"], group, package,
                    version, "etc", "profile.d", "init.sh"])
    if not existance
      return nil
    end
    pkg_dir  = File.join([ opts["prefix"], opts["architecture"], "var", "cmspkg", "pkgs" ])
    pkg_file = File.join([ pkg_dir, opts["name"] ])
    if not File.exists? pkg_file
      execute ["sudo", "-u", opts["user"], "mkdir", "-p", pkg_dir]
      execute ["sudo", "-u", opts["user"], "touch", pkg_file]
    end
    return { :ensure => "1.0", :name => @resource[:name] }
  end

  def self.instances
    return []
  end

  # Override default `execute` to run super method in a clean
  # environment without Bundler, if Bundler is present
  def execute(*args)
    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super
      end
    else
      super
    end
  end

  # Override default `execute` to run super method in a clean
  # environment without Bundler, if Bundler is present
  def self.execute(*args)
    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super
      end
    else
      super
    end
  end
end
