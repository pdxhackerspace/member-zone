# The API's documentation for readers who do not hold a token yet: the llms.txt index and the
# rendered reference. Public, like the OpenAPI document — it describes the API and grants nothing.
class ApiDocsController < ApplicationController
  def llms_index
    render plain: ApiReference::LlmsText.new(base_url: request.base_url).index, content_type: 'text/markdown'
  end

  def llms_full
    render plain: ApiReference::LlmsText.new(base_url: request.base_url).full, content_type: 'text/markdown'
  end

  def reference
    render layout: false
  end
end
