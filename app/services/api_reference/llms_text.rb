module ApiReference
  # The llms.txt convention (https://llmstxt.org): a short markdown index at /llms.txt pointing at
  # fuller documents, and /api/v1/llms-full.txt with the guide and every endpoint in one file.
  class LlmsText
    def initialize(base_url:, document: Document.current)
      @document = document
      @base_url = base_url.chomp('/')
    end

    def index
      [
        '# Member Zone API',
        '',
        "> #{@document.spec.dig('info', 'summary')} Authenticate with `Authorization: Bearer <token>`; " \
        'a token can do only what its scopes (privilege keys) and its holder allow.',
        '',
        '## Docs',
        '',
        "- [Full guide and reference](#{@base_url}/api/v1/llms-full.txt): everything below in one markdown file",
        "- [OpenAPI 3.1 document](#{@base_url}/api/v1/openapi.json): the machine-readable reference",
        "- [Rendered reference](#{@base_url}/api/docs): the same, for people",
        '',
        *operation_index
      ].join("\n") << "\n"
    end

    def full
      [@document.guide.strip, '', '# Endpoint reference', '', *endpoint_sections, '# Schemas', '',
       *schema_sections].join("\n") << "\n"
    end

    private

    def operation_index
      @document.operations_by_tag.flat_map do |tag, operations|
        ["## #{tag}", '', *operations.map { |method, path, operation| index_line(method, path, operation) }, '']
      end
    end

    def index_line(method, path, operation)
      scope = operation['x-required-scope']
      "- `#{method} /api/v1#{path}`: #{operation['summary']}#{" (scope: `#{scope}`)" if scope}"
    end

    def endpoint_sections
      @document.operations.flat_map do |method, path, operation|
        EndpointSection.new(@document, method, path, operation).lines
      end
    end

    def schema_sections
      @document.spec.dig('components', 'schemas').flat_map do |name, schema|
        description = schema['description'].to_s.strip
        ["## #{name}", '', *([description, ''] unless description.empty?), *field_lines(schema), '']
      end
    end

    def field_lines(schema)
      required = Array(schema['required'])
      (schema['properties'] || {}).map do |field, property|
        note = property['description'].to_s.strip.tr("\n", ' ')
        "- `#{field}`#{' (required)' if required.include?(field)}: #{@document.describe_type(property)}" \
          "#{" — #{note}" unless note.empty?}"
      end
    end
  end
end
