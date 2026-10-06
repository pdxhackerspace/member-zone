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

    def with_directories(*dirs)
      original = Rails.configuration.x.credential_script_directories
      Rails.configuration.x.credential_script_directories = dirs
      yield
    ensure
      Rails.configuration.x.credential_script_directories = original
    end

    test 'the default directory, CREDENTIAL_SCRIPTS_DIR and configured directories are all searched' do
      original = ENV.fetch('CREDENTIAL_SCRIPTS_DIR', nil)
      ENV['CREDENTIAL_SCRIPTS_DIR'] = @scratch
      directories = ScriptCatalog.directories.map(&:to_s)

      assert_includes directories, Rails.root.join('scripts/credentials').to_s
      assert_includes directories, @scratch
      assert_includes directories, CREDENTIAL_FIXTURE_DIR.to_s
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
      path = write_script(@scratch, 'mounted.sh')
      with_directories(@scratch) do
        assert ScriptCatalog.allowed?(path)
        assert_includes ScriptCatalog.scripts, File.realpath(path)
      end
    end

    test 'refuses directory traversal out of an allowed directory' do
      assert_not ScriptCatalog.allowed?("#{CREDENTIAL_FIXTURE_DIR}/../../../../../../bin/sh")
      assert_not ScriptCatalog.allowed?("#{CREDENTIAL_FIXTURE_DIR}/../../../../../../#{@scratch}/x.sh")
    end

    test 'refuses a symlink that leaves the allowed directory' do
      outside = Dir.mktmpdir('outside')
      target = write_script(outside, 'target.sh')
      link = File.join(@scratch, 'link.sh')
      File.symlink(target, link)

      with_directories(@scratch) do
        assert_not ScriptCatalog.allowed?(link)
        assert_not_includes ScriptCatalog.scripts, link
        assert_not_includes ScriptCatalog.scripts.map { |path| File.basename(path) }, 'link.sh'
      end
    ensure
      FileUtils.rm_rf(outside)
    end

    test 'allows a symlink that stays inside the allowed directory' do
      target = write_script(@scratch, 'real.sh')
      link = File.join(@scratch, 'alias.sh')
      File.symlink(target, link)

      with_directories(@scratch) { assert ScriptCatalog.allowed?(link) }
    end

    test 'a directory that merely shares a prefix with an allowed one is not allowed' do
      sibling = "#{@scratch}-sibling"
      FileUtils.mkdir_p(sibling)
      path = write_script(sibling, 'x.sh')

      with_directories(@scratch) { assert_not ScriptCatalog.allowed?(path) }
    ensure
      FileUtils.rm_rf(sibling)
    end

    test 'a missing directory contributes nothing' do
      with_directories(File.join(@scratch, 'does-not-exist')) do
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
