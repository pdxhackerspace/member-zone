module TrainingResources
  # Re-reads every topic link. The first successful read is a baseline and says
  # nothing. A later read counts as a change only when the next check sees the
  # same new text, so a page that is different on every fetch never sends mail.
  class LinkContentChecker
    FLAP_LIMIT = 5
    TEXT_LIMIT = 20_000

    def self.call(now: Time.current, http: nil, resolver: nil)
      return unless ReminderSetting.enabled?(REMINDER_KEY)

      TrainingTopicLink.find_each do |link|
        new(link, now: now, http: http, resolver: resolver).call
      rescue StandardError => e
        Rails.logger.error("[LinkContentChecker] link_id=#{link.id} #{e.class}: #{e.message}")
      end
    end

    def initialize(link, now:, http:, resolver:)
      @link = link
      @now = now
      @http = http
      @resolver = resolver
    end

    def call
      result = LinkContentFetcher.call(@link.url, headers: conditional_headers, http: @http, resolver: @resolver)
      return note_error(result.error) if result.status == :error
      return note_too_large if result.status == :too_large
      return note_unchanged(result) if result.status == :not_modified

      apply_body(result)
    end

    private

    def apply_body(result)
      digest, text = fingerprint(result)
      return baseline!(digest, text, result) if snapshot.digest.blank? || stale?

      if digest == snapshot.digest
        confirm_same!(result)
      elsif digest == snapshot.candidate_digest
        confirm_change!(digest, text, result)
      else
        hold_candidate!(digest, text, result)
      end
    end

    def fingerprint(result)
      text = PageText.extract(result.body, result.content_type)
      source = text || result.body.to_s.b
      [Digest::SHA256.hexdigest(source), text&.[](0, TEXT_LIMIT)]
    end

    def baseline!(digest, text, result)
      snap = snapshot
      snap.assign_attributes(baseline_attributes(digest, text, result))
      snap.save!
    end

    def baseline_attributes(digest, text, result)
      { digest: digest, text: text, etag: result.etag, last_modified: result.last_modified,
        candidate_digest: nil, candidate_text: nil, candidate_etag: nil, candidate_last_modified: nil,
        flap_count: 0, checked_at: @now, changed_at: nil, status: 'baseline', error: nil }
    end

    def confirm_same!(result)
      snapshot.update!(
        flap_count: 0, candidate_digest: nil, candidate_text: nil, candidate_etag: nil,
        candidate_last_modified: nil, etag: result.etag.presence || snapshot.etag,
        last_modified: result.last_modified.presence || snapshot.last_modified,
        checked_at: @now, status: 'watching', error: nil
      )
    end

    def confirm_change!(digest, text, result)
      record_change!(text, result)
      snapshot.update!(
        digest: digest, text: text, etag: result.etag, last_modified: result.last_modified,
        candidate_digest: nil, candidate_text: nil, candidate_etag: nil, candidate_last_modified: nil,
        flap_count: 0, checked_at: @now, changed_at: @now, status: 'watching', error: nil
      )
    end

    def hold_candidate!(digest, text, result)
      flaps = snapshot.flap_count + 1
      snapshot.update!(
        candidate_digest: digest, candidate_text: text, candidate_etag: result.etag,
        candidate_last_modified: result.last_modified, flap_count: flaps, checked_at: @now, error: nil,
        status: flaps >= FLAP_LIMIT ? 'untrackable' : 'watching'
      )
    end

    def record_change!(text, result)
      count, excerpts = PageExcerpt.added(snapshot.text, text)
      changed_on = plausible_modified(result.last_modified) || @now
      ChangeLog.link_content_changed(
        @link,
        occurred_at: @now,
        details: {
          'url' => @link.url, 'added_line_count' => count, 'excerpts' => excerpts,
          'changed_on' => changed_on.iso8601
        }
      )
    end

    def note_unchanged(result)
      return note_error(nil) if snapshot.digest.blank?

      confirm_same!(result)
    end

    def note_error(message)
      snapshot.update!(checked_at: @now, status: 'error', error: message.presence || 'Could not read')
    end

    def note_too_large
      snapshot.update!(checked_at: @now, status: 'too_large', error: nil)
    end

    def stale?
      snapshot.checked_at.present? && snapshot.checked_at < @now - interval_days.days
    end

    def interval_days
      ReminderSetting.for_key(REMINDER_KEY).interval_days
    end

    def conditional_headers
      return {} if snapshot.digest.blank? || stale?

      { 'If-None-Match' => snapshot.etag, 'If-Modified-Since' => snapshot.last_modified }.compact
    end

    def plausible_modified(header)
      return nil if header.blank?

      time = Time.httpdate(header)
      return nil if time > @now + 1.minute || (@now - time).abs < 2.minutes

      time
    rescue ArgumentError
      nil
    end

    def snapshot
      @snapshot ||= @link.content_snapshot || @link.build_content_snapshot
    end
  end
end
