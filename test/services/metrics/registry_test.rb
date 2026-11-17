require 'test_helper'

module Metrics
  class RegistryTest < ActiveSupport::TestCase
    setup { @registry = Registry.new }

    test 'a gauge renders help, type and value' do
      @registry.gauge('things', 'How many things.', 3)

      assert_equal "# HELP things How many things.\n# TYPE things gauge\nthings 3\n", @registry.to_text
    end

    test 'labels are rendered and escaped' do
      @registry.gauge('things', 'Things.', 1, name: %(a "quoted" back\\slash\nnewline))

      assert_includes @registry.to_text, %(things{name="a \\"quoted\\" back\\\\slash\\nnewline"} 1\n)
    end

    test 'booleans render as 1 and 0 and times as epoch seconds' do
      family = @registry.gauge('things', 'Things.')
      family.set(true, kind: 'yes').set(false, kind: 'no').set(Time.zone.at(1_700_000_000), kind: 'when')

      text = @registry.to_text

      assert_includes text, %(things{kind="yes"} 1\n)
      assert_includes text, %(things{kind="no"} 0\n)
      assert_includes text, %(things{kind="when"} 1700000000.0\n)
    end

    test 'nil values are left out rather than exported as zero' do
      @registry.gauge('things', 'Things.', nil, kind: 'never')

      assert_equal "# HELP things Things.\n# TYPE things gauge\n", @registry.to_text
    end

    test 'grouped counts become one sample per key' do
      @registry.gauge('things', 'Things.').set_grouped({ %w[a x] => 1, %w[b y] => 2 }, :first, :second)

      assert_includes @registry.to_text, %(things{first="a",second="x"} 1\n)
      assert_includes @registry.to_text, %(things{first="b",second="y"} 2\n)
    end

    test 'a histogram renders cumulative buckets, sum and count' do
      @registry.histogram('took_seconds', 'How long.')
               .set_distribution({ job: 'A' }, [0.1, 1], { '0.1' => 2, '1' => 1, '+Inf' => 4 }, 12.5)

      text = @registry.to_text

      assert_includes text, "# TYPE took_seconds histogram\n"
      assert_includes text, %(took_seconds_bucket{job="A",le="0.1"} 2\n)
      assert_includes text, %(took_seconds_bucket{job="A",le="1"} 3\n)
      assert_includes text, %(took_seconds_bucket{job="A",le="+Inf"} 7\n)
      assert_includes text, %(took_seconds_sum{job="A"} 12.5\n)
      assert_includes text, %(took_seconds_count{job="A"} 7\n)
    end

    test 'merging adds families from another registry' do
      other = Registry.new
      other.counter('others_total', 'Others.', 5)
      @registry.gauge('things', 'Things.', 1)

      @registry.merge!(other)

      assert_includes @registry.to_text, "# TYPE others_total counter\nothers_total 5\n"
    end
  end
end
