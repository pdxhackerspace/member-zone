require 'test_helper'

class ListPresentationHelperTest < ActionView::TestCase
  include ListPresentationHelper

  test 'list_money_tag shows dollars without a code for USD' do
    html = list_money_tag(BigDecimal('1234.5'), 'USD')

    assert_includes html, '$'
    assert_includes html, '1,234'
    assert_includes html, '.50'
    assert_not_includes html, 'USD'
  end

  test 'list_money_tag treats a missing currency as USD' do
    html = list_money_tag(15)

    assert_includes html, '$'
    assert_not_includes html, 'USD'
  end

  test 'list_money_tag uses the currency symbol and code for other currencies' do
    html = list_money_tag(15, 'gbp')

    assert_includes html, '£'
    assert_includes html, 'GBP'
    assert_not_includes html, '$'
  end

  test 'list_money_tag drops the symbol for a currency it has none for' do
    html = list_money_tag(15, 'JPY')

    assert_not_includes html, '$'
    assert_includes html, 'JPY'
  end
end
