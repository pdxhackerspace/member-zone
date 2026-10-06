require 'test_helper'

module Credentials
  class RedactorTest < ActiveSupport::TestCase
    test 'blanks every occurrence of each value' do
      redactor = Redactor.new(%w[hunter22 s3cr3t-value])
      text = 'key=hunter22 again hunter22 and s3cr3t-value'

      assert_equal 'key=[REDACTED] again [REDACTED] and [REDACTED]', redactor.call(text)
    end

    test 'leaves values shorter than four characters alone' do
      assert_equal 'a 1 yes b', Redactor.new(%w[1 yes]).call('a 1 yes b')
      assert_equal 'port 80 is open', Redactor.new(%w[80]).call('port 80 is open')
    end

    test 'redacts the longer value first so a value containing another is fully hidden' do
      assert_equal '[REDACTED]', Redactor.new(%w[abcd abcdefgh]).call('abcdefgh')
    end

    test 'handles nil text, nil values and non-strings' do
      assert_equal '', Redactor.new([nil, 12_345]).call(nil)
      assert_equal 'x [REDACTED]', Redactor.new([12_345]).call('x 12345')
    end

    test 'values with regexp metacharacters are matched literally' do
      assert_equal 'pw=[REDACTED]', Redactor.new(['a.*+?(b']).call('pw=a.*+?(b')
      assert_equal 'aXXb', Redactor.new(['a.*+?(b']).call('aXXb')
    end

    test 'no values means no change' do
      assert_equal 'unchanged', Redactor.new([]).call('unchanged')
    end
  end
end
