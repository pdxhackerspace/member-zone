require 'test_helper'

module Credentials
  class FieldHintsTest < ActiveSupport::TestCase
    SCHEMA = [
      { 'key' => 'client_id', 'secret' => false },
      { 'key' => 'client_secret', 'secret' => true }
    ].freeze

    test 'a secret keeps exactly its first and last four characters' do
      hints = FieldHints.call({ 'client_id' => 'cid', 'client_secret' => 'abcd-the-middle-is-gone-wxyz' }, SCHEMA)

      assert_equal({ 'prefix' => 'abcd', 'suffix' => 'wxyz' }, hints['client_secret'])
      assert_not_includes hints.to_s, 'middle'
    end

    test 'a non-secret field is kept whole' do
      hints = FieldHints.call({ 'client_id' => 'client-123456', 'client_secret' => 'abcd-secret-value-wxyz' }, SCHEMA)
      assert_equal({ 'value' => 'client-123456' }, hints['client_id'])
    end

    test 'a secret shorter than twelve characters keeps nothing' do
      %w[a abcd abcdefgh abcdefghijk].each do |short|
        assert_equal({}, FieldHints.call({ 'client_id' => 'c', 'client_secret' => short }, SCHEMA)['client_secret'],
                     short)
      end
    end

    test 'twelve characters is the first length that is hinted' do
      hint = FieldHints.call({ 'client_id' => 'c', 'client_secret' => 'abcdefghijkl' }, SCHEMA)['client_secret']
      assert_equal({ 'prefix' => 'abcd', 'suffix' => 'ijkl' }, hint)
    end

    test 'multibyte characters are counted as characters' do
      hint = FieldHints.call({ 'client_id' => 'c', 'client_secret' => 'ééééxxxxxxxxzzzz' }, SCHEMA)['client_secret']
      assert_equal 'éééé', hint['prefix']
    end

    test 'a field missing from the output is an error rather than a silent gap' do
      assert_raises(KeyError) { FieldHints.call({ 'client_id' => 'c' }, SCHEMA) }
    end

    test 'display' do
      assert_equal 'abcd…wxyz', FieldHints.display({ 'prefix' => 'abcd', 'suffix' => 'wxyz' })
      assert_equal 'whole', FieldHints.display({ 'value' => 'whole' })
      assert_equal FieldHints::MASK, FieldHints.display({})
      assert_equal FieldHints::MASK, FieldHints.display(nil)
    end
  end
end
