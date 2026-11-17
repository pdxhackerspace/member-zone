module Metrics
  # The metric families gathered during one scrape, and their rendering in the Prometheus text
  # exposition format (version 0.0.4).
  class Registry
    # One named metric: its type, help text and samples.
    class Family
      attr_reader :name, :type, :help, :samples

      def initialize(name, type, help)
        @name = name
        @type = type
        @help = help
        @samples = []
      end

      # Nil values are skipped rather than exported as zero: "never happened" is not "at the epoch".
      def set(value, labels = {}, suffix = nil)
        return self if value.nil?

        @samples << ["#{name}#{suffix}", labels, value]
        self
      end

      # One sample per entry of a `group(...).count` style hash. Keys may be arrays when the
      # count was grouped by several columns; label_names line up with them.
      def set_grouped(counts, *label_names)
        counts.each { |key, value| set(value, label_names.zip(Array(key)).to_h) }
        self
      end

      # A histogram series from per-bucket (not cumulative) counts keyed by upper bound.
      def set_distribution(labels, buckets, bucket_counts, sum)
        running = 0
        buckets.each do |bound|
          running += bucket_counts.fetch(bound.to_s, 0)
          set(running, labels.merge(le: bound.to_s), '_bucket')
        end
        running += bucket_counts.fetch('+Inf', 0)
        set(running, labels.merge(le: '+Inf'), '_bucket')
        set(sum, labels, '_sum')
        set(running, labels, '_count')
      end
    end

    def initialize
      @families = {}
    end

    def gauge(name, help, value = nil, labels = {})
      family(name, :gauge, help).set(value, labels)
    end

    def counter(name, help, value = nil, labels = {})
      family(name, :counter, help).set(value, labels)
    end

    def histogram(name, help)
      family(name, :histogram, help)
    end

    def families
      @families.values
    end

    def merge!(other)
      other.families.each { |incoming| @families[incoming.name] ||= incoming }
      self
    end

    def to_text
      families.map { |family| render_family(family) }.join
    end

    private

    def family(name, type, help)
      @families[name] ||= Family.new(name, type, help)
    end

    def render_family(family)
      lines = ["# HELP #{family.name} #{escape_help(family.help)}", "# TYPE #{family.name} #{family.type}"]
      family.samples.each { |name, labels, value| lines << "#{name}#{render_labels(labels)} #{render_value(value)}" }
      "#{lines.join("\n")}\n"
    end

    def render_labels(labels)
      return '' if labels.empty?

      "{#{labels.map { |key, value| %(#{key}="#{escape_label(value)}") }.join(',')}}"
    end

    # Times become epoch seconds, which is what to_f gives them.
    def render_value(value)
      case value
      when true then '1'
      when false then '0'
      when Integer then value.to_s
      else value.to_f.to_s
      end
    end

    def escape_help(text)
      text.to_s.gsub('\\', '\\\\\\\\').gsub("\n", '\\n')
    end

    def escape_label(value)
      value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
    end
  end
end
