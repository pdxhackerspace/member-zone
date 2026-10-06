module Credentials
  # The programs a credential provider may run. A provider's script_path must resolve to an
  # executable file inside one of these directories:
  #
  #   - scripts/credentials in the app (in the image, /rails/scripts/credentials)
  #   - CREDENTIAL_SCRIPTS_DIR, for programs an operator mounts in
  #   - config.x.credential_script_directories, which tests use for their fixtures
  #
  # Paths are compared after resolving symlinks, so a link inside the directory pointing
  # outside it does not count.
  module ScriptCatalog
    DEFAULT_DIRECTORY = Rails.root.join('scripts/credentials')

    module_function

    def directories
      configured = Array(Rails.configuration.x.credential_script_directories)
      [DEFAULT_DIRECTORY, ENV['CREDENTIAL_SCRIPTS_DIR'].presence, *configured]
        .compact.map { |dir| Pathname(dir.to_s) }.uniq
    end

    # Every executable in the directories, by full path, for the provider form's picker.
    def scripts
      directories.flat_map { |dir| scripts_in(dir) }.uniq.sort
    end

    def allowed?(path)
      real = realpath(path)
      return false unless real && File.file?(real) && executable?(real)

      resolved_directories.any? { |dir| real.start_with?("#{dir}/") }
    end

    # An execute bit must be set. File.executable? alone is not enough: it says yes to root
    # for any file on some filesystems, and a file nobody can execute is not a program.
    def executable?(real)
      File.executable?(real) && File.stat(real).mode.anybits?(0o111)
    end

    def scripts_in(dir)
      return [] unless dir.directory?

      dir.children.select { |child| allowed?(child.to_s) }.map(&:to_s)
    end

    def resolved_directories
      directories.filter_map { |dir| realpath(dir.to_s) }
    end

    def realpath(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
  end
end
