module ApiReference
  # The API's documentation in the forms people and programs read it, all built from the two
  # sources of truth: docs/api/openapi.yaml (the reference) and docs/api.md (the guide). Nothing
  # here is written by hand, so the llms.txt files cannot drift from the spec.
  class Document
    SPEC_PATH = Rails.root.join('docs/api/openapi.yaml')
    GUIDE_PATH = Rails.root.join('docs/api.md')
    HTTP_METHODS = %w[get put post patch delete].freeze

    def self.current
      @current = nil if Rails.env.development?
      @current ||= new
    end

    attr_reader :spec, :guide

    def initialize(spec: YAML.safe_load_file(SPEC_PATH, permitted_classes: [Date, Time]),
                   guide: File.read(GUIDE_PATH))
      @spec = spec.freeze
      @guide = guide
    end

    # Every operation, in spec order: [method, path, operation].
    def operations
      spec['paths'].flat_map do |path, item|
        item.slice(*HTTP_METHODS).map { |method, operation| [method.upcase, path, operation] }
      end
    end

    def tags
      spec['tags'].pluck('name')
    end

    def operations_by_tag
      operations.group_by { |_method, _path, operation| Array(operation['tags']).first }
    end

    # Follows a $ref (to components) until it reaches the object itself.
    def resolve(node)
      node = spec.dig(*node['$ref'].delete_prefix('#/').split('/')) while node.is_a?(Hash) && node['$ref']
      node
    end

    def ref_name(node)
      node.is_a?(Hash) && node['$ref'] ? node['$ref'].split('/').last : nil
    end

    # A short human description of a schema's type: "string", "integer or null", "array of
    # ParkingNotice", "one of: link, blank".
    def describe_type(schema)
      return 'any' if schema.nil?
      return ref_name(schema) if ref_name(schema)
      return "one of: #{schema['enum'].join(', ')}" if schema['enum']
      return schema['oneOf'].map { |option| describe_type(option) }.join(' or ') if schema['oneOf']

      type = Array(schema['type']).join(' or ')
      type = "array of #{describe_type(schema['items'])}" if schema['type'] == 'array'
      type = "#{type} (#{schema['format']})" if schema['format']
      type
    end
  end
end
