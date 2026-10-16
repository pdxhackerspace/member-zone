module DocumentsHelper
  # Documents are managed from the admin topic page, the member-facing topic page, or the
  # documents index. return_to_topic names the topic; return_to=topic_page picks the
  # member-facing page over the admin one.
  def document_return_path
    topic_id = params[:return_to_topic].presence
    return documents_path unless topic_id
    return training_catalog_topic_path(topic_id, anchor: 'topic-resources') if params[:return_to] == 'topic_page'

    edit_training_topic_path(topic_id)
  end
end
