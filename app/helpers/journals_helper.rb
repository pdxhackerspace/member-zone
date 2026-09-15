module JournalsHelper
  include Journals::ParkingNoticeRendering

  def render_change_rows(changes_hash)
    return content_tag(:span, 'No field changes recorded', class: 'text-muted') if changes_hash.blank?

    # Handle special training-related entries
    return render_training_change(changes_hash['training']) if changes_hash['training'].is_a?(Hash)
    return render_key_fob_change(changes_hash['key_fob']) if changes_hash['key_fob'].is_a?(Hash)
    return render_parking_notice_change(changes_hash['parking_notice']) if changes_hash['parking_notice'].is_a?(Hash)

    if changes_hash['trainer_capability'].is_a?(Hash)
      return render_trainer_capability_change(changes_hash['trainer_capability'])
    end

    render_change_table(changes_hash)
  end

  def render_change_table(changes_hash)
    content_tag(:div, class: 'table-responsive') do
      content_tag(:table, class: 'table table-sm mb-0 align-middle') do
        change_table_head + change_table_body(changes_hash)
      end
    end
  end

  def change_table_head
    content_tag(:thead, class: 'bg-body-tertiary') do
      content_tag(:tr) do
        content_tag(:th, 'Field') +
          content_tag(:th, 'From') +
          content_tag(:th, 'To')
      end
    end
  end

  def change_table_body(changes_hash)
    content_tag(:tbody) do
      safe_join(
        changes_hash.map do |attr, vals|
          content_tag(:tr) do
            content_tag(:td, attr.humanize) +
              content_tag(:td, display_change_value(vals['from'])) +
              content_tag(:td, display_change_value(vals['to']))
          end
        end
      )
    end
  end

  def render_training_change(training_data)
    topic = training_data['topic']
    content_tag(:div, class: 'small') do
      content_tag(:span, topic, class: 'badge text-bg-primary me-2') +
        if training_data['trainer'].present?
          content_tag(:span, "trained by #{training_data['trainer']}", class: 'text-muted')
        elsif training_data['removed_by'].present?
          content_tag(:span, "removed by #{training_data['removed_by']}", class: 'text-muted')
        else
          ''.html_safe
        end
    end
  end

  def render_trainer_capability_change(capability_data)
    topic = capability_data['topic']
    content_tag(:div, class: 'small') do
      content_tag(:span, topic, class: 'badge text-bg-info me-2') +
        if capability_data['granted_by'].present?
          content_tag(:span, "can now train others (granted by #{capability_data['granted_by']})", class: 'text-muted')
        elsif capability_data['revoked_by'].present?
          content_tag(:span, "trainer capability revoked by #{capability_data['revoked_by']}", class: 'text-muted')
        else
          ''.html_safe
        end
    end
  end

  def render_key_fob_change(key_fob_data)
    content_tag(:div, class: 'small') do
      content_tag(:code, key_fob_data['rfid'], class: 'bg-body-secondary px-2 py-1 rounded me-2') +
        if key_fob_data['notes'].present?
          content_tag(:span, key_fob_data['notes'], class: 'text-muted')
        else
          ''.html_safe
        end
    end
  end

  def display_change_value(value)
    case value
    when nil
      content_tag(:span, 'nil', class: 'text-muted fst-italic')
    when ''
      content_tag(:span, 'empty', class: 'text-muted fst-italic')
    else
      if value.is_a?(TrueClass) || value.is_a?(FalseClass)
        value ? 'true' : 'false'
      else
        value.to_s
      end
    end
  end
end
