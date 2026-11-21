class EmailTemplate
  # Sample digest for the training-resource email preview. Kept beside PreviewVariables so that
  # module stays inside its length limit.
  module TrainingResourcePreviewVariables
    module_function

    def all
      {
        update_count: 'are 3 updates',
        updated_topics: 'Laser Cutter and Woodworking',
        resource_updates_html: '<p><strong>Laser Cutter</strong></p><ul><li>New document: Laser safety checklist ' \
                               '(checklist.pdf, 240 KB), added Nov 18</li></ul>',
        resource_updates_text: "Laser Cutter\n- New document: Laser safety checklist (checklist.pdf, 240 KB), " \
                               'added Nov 18'
      }
    end
  end
end
