require 'test_helper'

module Credentials
  class ScriptCatalogTest < ActiveSupport::TestCase
    setup { @scratch = Dir.mktmpdir('catalog') }
    teardown { FileUtils.rm_rf(@scratch) }

    def write_script(dir, name, mode: 0o755)
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

    test 'the default directory, ACCESS_SCRIPTS_DIR and configured roots are all searched' do
      original_access = ENV.fetch('ACCESS_SCRIPTS_DIR', nil)
      original_legacy = ENV.fetch('CREDENTIAL_SCRIPTS_DIR', nil)
      ENV['ACCESS_SCRIPTS_DIR'] = @scratch
      ENV.delete('CREDENTIAL_SCRIPTS_DIR')
      directories = ScriptCatalog.directories.map(&:to_s)

      assert_includes directories, Rails.root.join('scripts/credential').to_s
      assert_includes directories, File.join(@scratch, 'credential')
      assert_includes directories, CREDENTIAL_FIXTURE_DIR.to_s
    ensure
      original_access ? ENV['ACCESS_SCRIPTS_DIR'] = original_access : ENV.delete('ACCESS_SCRIPTS_DIR')
      original_legacy ? ENV['CREDENTIAL_SCRIPTS_DIR'] = original_legacy : ENV.delete('CREDENTIAL_SCRIPTS_DIR')
    end

    test 'CREDENTIAL_SCRIPTS_DIR is still honored as a legacy credential directory' do
      original = ENV.fetch('CREDENTIAL_SCRIPTS_DIR', nil)
      ENV['CREDENTIAL_SCRIPTS_DIR'] = @scratch
      path = write_script(@scratch, 'legacy.sh')

      assert_includes ScriptCatalog.directories.map(&:to_s), @scratch
      assert ScriptCatalog.allowed?(path)
    ensure
      original ? ENV['CREDENTIAL_SCRIPTS_DIR'] = original : ENV.delete('CREDENTIAL_SCRIPTS_DIR')
    end

    test 'lists executables from the fixture directory and skips what is not executable' do
      scripts = ScriptCatalog.scripts

      assert_includes scripts, credential_script('oauth.sh')
      assert_includes scripts, credential_script('single_key.rb')
      assert_not_includes scripts, credential_script('not_executable.sh')
      assert_not_includes scripts, credential_script('_common.sh')
    end

    test 'allows an executable inside an allowed directory' do
      assert ScriptCatalog.allowed?(credential_script('oauth.sh'))
    end

    test 'refuses a file that is not executable' do
      assert_not ScriptCatalog.allowed?(credential_script('not_executable.sh'))
    end

    test 'refuses a file that does not exist, a blank path and a directory' do
      assert_not ScriptCatalog.allowed?(credential_script('nope.sh'))
      assert_not ScriptCatalog.allowed?('')
      assert_not ScriptCatalog.allowed?(nil)
      assert_not ScriptCatalog.allowed?(CREDENTIAL_FIXTURE_DIR.to_s)
    end

    test 'refuses a program outside every allowed directory' do
      assert_not ScriptCatalog.allowed?('/bin/sh')
      assert_not ScriptCatalog.allowed?(write_script(@scratch, 'elsewhere.sh'))
    end

    test 'allows a program once its directory is added' do
      with_roots(@scratch) do
        FileUtils.mkdir_p(File.join(@scratch, 'credential'))
        mounted = write_script(File.join(@scratch, 'credential'), 'mounted.sh')
        assert ScriptCatalog.allowed?(mounted)
        assert_includes ScriptCatalog.scripts, File.realpath(mounted)
      end
    end

    test 'refuses directory traversal out of an allowed directory' do
      assert_not ScriptCatalog.allowed?("#{CREDENTIAL_FIXTURE_DIR}/../../../../../../bin/sh")
      assert_not ScriptCatalog.allowed?("#{CREDENTIAL_FIXTURE_DIR}/../../../../../../#{@scratch}/x.sh")
    end

    test 'refuses a symlink that leaves the allowed directory' do
      outside = Dir.mktmpdir('outside')
      target = write_script(outside, 'target.sh')
      credential_dir = File.join(@scratch, 'credential')
      FileUtils.mkdir_p(credential_dir)
      link = File.join(credential_dir, 'link.sh')
      File.symlink(target, link)

      with_roots(@scratch) do
        assert_not ScriptCatalog.allowed?(link)
        assert_not_includes ScriptCatalog.scripts, link
        assert_not_includes ScriptCatalog.scripts.map { |path| File.basename(path) }, 'link.sh'
      end
    ensure
      FileUtils.rm_rf(outside)
    end

    test 'allows a symlink that stays inside the allowed directory' do
      credential_dir = File.join(@scratch, 'credential')
      FileUtils.mkdir_p(credential_dir)
      target = write_script(credential_dir, 'real.sh')
      link = File.join(credential_dir, 'alias.sh')
      File.symlink(target, link)

      with_roots(@scratch) { assert ScriptCatalog.allowed?(link) }
    end

    test 'a directory that merely shares a prefix with an allowed one is not allowed' do
      sibling = "#{@scratch}-sibling"
      FileUtils.mkdir_p(sibling)
      path = write_script(sibling, 'x.sh')

      with_roots(@scratch) { assert_not ScriptCatalog.allowed?(path) }
    ensure
      FileUtils.rm_rf(sibling)
    end

    test 'a missing directory contributes nothing' do
      with_roots(File.join(@scratch, 'does-not-exist')) do
        assert_nothing_raised { ScriptCatalog.scripts }
      end
    end

    test 'scripts are listed once and sorted' do
      scripts = ScriptCatalog.scripts
      assert_equal scripts.uniq, scripts
      assert_equal scripts.sort, scripts
    end
  end
end
