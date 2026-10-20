require 'test_helper'

module OperatorScripts
  class CatalogTest < ActiveSupport::TestCase
    setup { @scratch = Dir.mktmpdir('operator-catalog') }
    teardown { FileUtils.rm_rf(@scratch) }

    def write_script(dir, name, mode: 0o755)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\necho hi\n")
      File.chmod(mode, path)
      path
    end

    def with_roots(*roots)
      original = Rails.configuration.x.operator_script_roots
      Rails.configuration.x.operator_script_roots = roots
      yield
    ensure
      Rails.configuration.x.operator_script_roots = original
    end

    test 'audit directories include the legacy audit-log subdirectory' do
      with_roots(@scratch) do
        directories = Catalog.directories_for('audit').map(&:to_s)

        assert_includes directories, File.join(@scratch, 'audit')
        assert_includes directories, File.join(@scratch, 'audit-log')
      end
    end

    test 'allows and resolves audit programs stored under the legacy audit-log path' do
      with_roots(@scratch) do
        current_dir = File.join(@scratch, 'audit')
        legacy_path = File.join(@scratch, 'audit-log', 'doors.sh')
        write_script(current_dir, 'doors.sh')

        assert Catalog.allowed?(legacy_path, 'audit')
        assert_equal File.realpath(File.join(current_dir, 'doors.sh')),
                     File.realpath(Catalog.resolve_script_path(legacy_path, 'audit'))
      end
    end

    test 'lists executables from a legacy audit-log directory when present' do
      with_roots(@scratch) do
        legacy_dir = File.join(@scratch, 'audit-log')
        path = write_script(legacy_dir, 'legacy.sh')

        assert_includes Catalog.scripts_for('audit'), File.realpath(path)
      end
    end
  end
end
