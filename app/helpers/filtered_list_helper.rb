# Chrome shared by the index pages that filter a list into buckets and page through the result:
# the filter chips across the top and the pagination at the bottom.
module FilteredListHelper
  # Pagy 43 moved nav rendering onto the paginator object and dropped the +pagy_bootstrap_nav+ view
  # helper earlier versions provided, so every call site raised NoMethodError as soon as a list grew
  # a second page. Views keep calling this name; it forwards to the current API.
  def pagy_bootstrap_nav(pagy, **)
    pagy.series_nav(:bootstrap, **)
  end

  # Class list for a +.filter-chip+. +variant+ is the semantic colour the chip carries when it is
  # not the selected one; a zero count is muted so an empty bucket does not invite a click that
  # shows nothing. Rendered through +shared/_filter_chip+.
  def filter_chip_class(active:, count:, variant: nil)
    ['filter-chip', 'text-decoration-none', variant, ('active' if active), ('muted' if count.zero?)]
      .compact.join(' ')
  end
end
