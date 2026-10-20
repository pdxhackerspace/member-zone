module OperatorScripts
  # Executable programs mounted for access controllers, audit log sources and credential
  # providers share one layout: each root directory contains subdirectories named +access+,
  # +audit+ and +credential+.
  #
  # Roots are, in order:
  #   - scripts/ in the app (in the image, /rails/scripts/)
  #   - ACCESS_SCRIPTS_DIR, for programs an operator mounts in
  #   - config.x.operator_script_roots, which tests use for their fixtures
  #
  # Paths are compared after resolving symlinks, so a link inside a directory pointing
  # outside it does not count.
  module Catalog
    ROLES = %w[access audit credential].freeze

    module_function

    def directories_for(role)
      raise ArgumentError, "unknown role #{role.inspect}" unless ROLES.include?(role.to_s)

      role_dirs = roots.map { |root| root.join(role.to_s) }
      role_dirs.concat(legacy_credential_directories) if role.to_s == 'credential'
      role_dirs.uniq
    end

    def roots
      [
        Rails.root.join('scripts'),
        ENV['ACCESS_SCRIPTS_DIR'].presence,
        *Array(Rails.configuration.x.operator_script_roots)
      ].compact.map { |dir| Pathname(dir.to_s) }.uniq
    end

    # CREDENTIAL_SCRIPTS_DIR pointed at a credential directory before the shared layout;
    # still honored as an extra credential search path.
    def legacy_credential_directories
      [ENV['CREDENTIAL_SCRIPTS_DIR'].presence].compact.map { |dir| Pathname(dir.to_s) }
    end

    def scripts_for(role)
      directories_for(role).flat_map { |dir| scripts_in(role, dir) }.uniq.sort
    end

    def allowed?(path, role)
      real = realpath(path)
      return false unless real && File.file?(real) && executable?(real)

      resolved_directories_for(role).any? { |dir| real.start_with?("#{dir}/") }
    end

    def executable?(real)
      File.executable?(real) && File.stat(real).mode.anybits?(0o111)
    end

    def scripts_in(role, dir)
      return [] unless dir.directory?

      dir.children.select { |child| allowed?(child.to_s, role) }.map(&:to_s)
    end

    def resolved_directories_for(role)
      directories_for(role).filter_map { |dir| realpath(dir.to_s) }
    end

    def realpath(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
  end
end
