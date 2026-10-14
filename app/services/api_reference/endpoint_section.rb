module ApiReference
  # One operation written out as markdown: what it does, what it needs, what it takes, and what
  # it answers. Parameters and request fields are resolved and listed in full; named schemas in
  # responses point at the schema section at the end of the document.
  class EndpointSection
    def initialize(document, method, path, operation)
      @document = document
      @method = method
      @path = path
      @operation = operation
    end

    def lines
      [
        "## #{@method} /api/v1#{@path}",
        '',
        "**#{@operation['summary']}**",
        '',
        *description,
        "- Scope: #{scope}",
        *parameters,
        *request_body,
        "- Responses: #{responses}",
        ''
      ]
    end

    private

    def description
      text = @operation['description'].to_s.strip
      text.empty? ? [] : [text, '']
    end

    def scope
      return 'none (no token needed)' if @operation['security'] == []

      value = @operation['x-required-scope']
      value ? "`#{value}`" : 'none (any valid token)'
    end

    def parameters
      params = (Array(@document.spec.dig('paths', @path, 'parameters')) + Array(@operation['parameters']))
               .map { |param| @document.resolve(param) }
      return [] if params.empty?

      ['- Parameters:', *params.map { |param| "  - `#{param['name']}` (#{param['in']}, #{type_of(param['schema'])})" }]
    end

    def request_body
      content = @operation.dig('requestBody', 'content')
      return [] unless content

      content.flat_map do |media_type, body|
        schema = @document.resolve(body['schema'] || {})
        required = Array(schema['required'])
        fields = (schema['properties'] || {}).map do |name, property|
          note = property['description'].to_s.strip.tr("\n", ' ')
          "  - `#{name}`#{' (required)' if required.include?(name)}: #{type_of(property)}" \
            "#{" — #{note}" unless note.empty?}"
        end
        ["- Body (#{media_type}):", *fields]
      end
    end

    def responses
      @operation['responses'].map do |status, response|
        name = @document.ref_name(response)
        "#{status} #{name || response['description'].to_s.strip.delete_suffix('.')}"
      end.join(', ')
    end

    def type_of(schema)
      @document.describe_type(schema)
    end
  end
end
