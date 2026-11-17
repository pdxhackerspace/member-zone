module Metrics
  # Base for the classes that add one area's metrics to a scrape. Subclasses implement #collect.
  class Collector
    def initialize(registry)
      @registry = registry
    end

    private

    attr_reader :registry

    delegate :gauge, :counter, :histogram, to: :registry

    # Fills in zero for every expected key, so a status nobody is in still has a series
    # (a series that appears only when non-zero cannot be alerted on going back to zero).
    def with_zeros(counts, expected)
      expected.index_with { 0 }.merge(counts)
    end
  end
end
