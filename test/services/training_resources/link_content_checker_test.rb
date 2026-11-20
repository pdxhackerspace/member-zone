require 'test_helper'

module TrainingResources
  class LinkContentCheckerTest < ActiveSupport::TestCase
    setup do
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by!(key: 'training_resource_updates').update!(enabled: true, interval_days: 7)
      @link = training_topic_links(:laser_safety_guide)
    end

    test 'the daily check does nothing while the reminder is disabled' do
      ReminderSetting.find_by!(key: 'training_resource_updates').update!(enabled: false)
      http = Object.new
      def http.get(*)
        raise 'should not fetch'
      end

      assert_nothing_raised { TrainingResources::LinkContentChecker.call(http: http, resolver: public_resolver) }
    end

    test 'the first read is a baseline and the same text twice confirms one change' do
      check(page('Keep the lid closed'), 'etag-1', 10.days.ago.httpdate)
      assert_empty TrainingResourceChange.all
      assert_equal 'baseline', @link.content_snapshot.status

      check(page('Keep the lid closed'), 'etag-2')
      assert_empty TrainingResourceChange.all
      assert_equal 'etag-2', @link.content_snapshot.reload.etag

      check(page('Keep the lid closed', 'Acrylic needs two passes'), 'etag-3', 3.days.ago.httpdate)
      assert_empty TrainingResourceChange.all

      http = check(page('Keep the lid closed', 'Acrylic needs two passes'), 'etag-3', 3.days.ago.httpdate)
      change = TrainingResourceChange.find_by!(kind: 'link_content_changed', resource_id: @link.id)
      assert_equal 1, change.details['added_line_count']
      assert_includes change.details['excerpts'], 'Acrylic needs two passes'
      assert_in_delta 3.days.ago.to_i, Time.zone.parse(change.details['changed_on']).to_i, 2
      assert_in_delta Time.current.to_i, change.occurred_at.to_i, 5
      assert_equal 'etag-2', http.headers.last['If-None-Match']
    end

    test 'a not-modified response and a flapping page record no change' do
      check(page('Stable'), 'etag-1')
      check_response(response(304, '', { 'etag' => 'etag-1' }))
      assert_empty TrainingResourceChange.all

      5.times { |index| check(page("Version #{index}")) }
      assert_empty TrainingResourceChange.all
      assert_equal 'untrackable', @link.content_snapshot.reload.status
    end

    test 'a one-day interval still compares a page checked yesterday' do
      ReminderSetting.find_by!(key: 'training_resource_updates').update!(interval_days: 1)
      check(page('Original'))
      @link.content_snapshot.update!(checked_at: 25.hours.ago)

      check(page('Rewritten overnight'))

      snapshot = @link.content_snapshot.reload
      assert_equal 'watching', snapshot.status
      assert snapshot.candidate_digest.present?
      assert_empty TrainingResourceChange.all
    end

    test 'a page that has not been checked within the interval is baselined again' do
      check(page('Original'))
      @link.content_snapshot.update!(checked_at: 8.days.ago)

      check(page('Rewritten while we were away'))

      assert_empty TrainingResourceChange.all
      assert_equal 'baseline', @link.content_snapshot.reload.status
    end

    test 'a redirect onto a private address is an error and not a change' do
      check_response(response(302, '', { 'location' => 'http://127.0.0.1/secret' }))

      snapshot = @link.content_snapshot
      assert_equal 'error', snapshot.status
      assert_equal 'private address', snapshot.error
      assert_empty TrainingResourceChange.all
    end

    private

    def check(body, etag = nil, last_modified = nil)
      headers = {}
      headers['etag'] = etag if etag
      headers['last-modified'] = last_modified if last_modified
      headers['content-type'] = 'text/html'
      check_response(response(200, body, headers))
    end

    def check_response(result)
      http = SequenceHttp.new([result])
      TrainingResources::LinkContentChecker.new(
        @link, now: Time.current, http: http, resolver: public_resolver
      ).call
      http
    end

    def page(*paragraphs)
      items = paragraphs.map { |text| "<p>#{text}</p>" }.join
      "<html><body>#{items}</body></html>"
    end

    def response(status, body, headers = {})
      Struct.new(:status, :body, :headers, keyword_init: true).new(status: status, body: body, headers: headers)
    end

    def public_resolver
      Struct.new(:address) do
        def getaddresses(_host)
          ['93.184.216.34']
        end
      end.new('93.184.216.34')
    end

    class SequenceHttp
      attr_reader :headers

      def initialize(responses)
        @responses = responses
        @headers = []
      end

      def get(_url, request_headers = {})
        @headers << request_headers
        @responses.shift
      end
    end
  end
end
