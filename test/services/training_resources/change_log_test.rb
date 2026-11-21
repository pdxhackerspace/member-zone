require 'test_helper'

module TrainingResources
  class ChangeLogTest < ActiveSupport::TestCase
    setup do
      ReminderSetting.seed_defaults!
      @topic = training_topics(:laser_cutting)
      @other = training_topics(:woodworking)
      enable_digest!
    end

    test 'a disabled reminder records nothing' do
      ReminderSetting.find_by!(key: 'training_resource_updates').update!(enabled: false)

      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')

      assert_empty TrainingResourceChange.all
    end

    test 'link create, edit, and removal are recorded, and a URL edit drops the stored page' do
      Current.user = users(:one)
      link = TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      link.create_content_snapshot!(digest: 'abc', checked_at: Time.current, status: 'baseline')

      link.update!(title: 'Safety guide', url: 'https://example.com/safety')
      assert_nil link.reload.content_snapshot
      link.destroy!

      kinds = TrainingResourceChange.order(:id).pluck(:kind)
      assert_equal %w[link_added link_updated link_removed], kinds
      assert_equal users(:one), TrainingResourceChange.order(:id).first.actor
      updated = TrainingResourceChange.find_by!(kind: 'link_updated')
      assert_equal ['Guide', 'Safety guide'], updated.details['title']
      assert_equal ['https://example.com/guide', 'https://example.com/safety'], updated.details['url']
      assert_nil TrainingTopicLinkSnapshot.find_by(digest: 'abc')
    ensure
      Current.reset
    end

    test 'saving a link without a real change records nothing' do
      link = TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')

      link.update!(title: 'Guide')

      assert_equal 1, TrainingResourceChange.count
    end

    test 'assigning topics on an unsaved document records nothing until it is saved' do
      document = Document.new(title: '')
      document.training_topic_ids = [@topic.id]

      assert_empty TrainingResourceChange.all

      document.title = 'Safety'
      document.file.attach(io: StringIO.new('hello'), filename: 'safety.pdf', content_type: 'application/pdf')
      document.save!

      added = TrainingResourceChange.where(kind: 'document_added')
      assert_equal [document.id], added.pluck(:resource_id)
      added = added.first
      assert_equal document.id, added.resource_id
      assert_equal 'safety.pdf', added.details['filename']
    end

    test 'deleting a freshly loaded document still records that it was removed' do
      document = build_document(@topic)

      Document.find(document.id).destroy!

      removed = TrainingResourceChange.find_by!(kind: 'document_removed', resource_id: document.id)
      assert_equal @topic.id, removed.training_topic_id
      assert_equal 'safety.pdf', removed.details['filename']
    end

    test 'adding a document to topics, replacing its file, and removing a topic are recorded once each' do
      document = build_document(@topic, @other)
      document.update!(title: 'Safety checklist')
      document.file.attach(io: StringIO.new('newer'), filename: 'safety-v2.pdf', content_type: 'application/pdf')
      document.training_topic_ids = [@topic.id]
      document.destroy!

      added = TrainingResourceChange.where(kind: 'document_added')
      assert_equal [@topic.id, @other.id].sort, added.pluck(:training_topic_id).sort
      updated = TrainingResourceChange.where(kind: 'document_updated')
      assert_equal 2, updated.where("details ? 'title'").count
      file_update = updated.where("details ? 'file'").first
      assert_equal 'safety.pdf', file_update.details.dig('file', 'from', 'filename')
      assert_equal 'safety-v2.pdf', file_update.details.dig('file', 'to', 'filename')
      removed = TrainingResourceChange.where(kind: 'document_removed').order(:id)
      assert_equal [@other.id, @topic.id], removed.pluck(:training_topic_id)
    end

    private

    def enable_digest!
      ReminderSetting.find_by!(key: 'training_resource_updates').update!(enabled: true)
    end

    def build_document(*topics)
      document = Document.new(title: 'Safety', training_topic_ids: topics.map(&:id))
      document.file.attach(io: StringIO.new('hello'), filename: 'safety.pdf', content_type: 'application/pdf')
      document.save!
      document
    end
  end
end
