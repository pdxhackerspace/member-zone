module SensitiveFields
  extend ActiveSupport::Concern

  # rubocop:disable Metrics/BlockLength
  class_methods do
    def encrypts_sensitive_string(*field_names)
      field_names.each do |field_name|
        define_sensitive_string_accessors(field_name)
      end
    end

    def encrypts_sensitive_json(*field_names)
      field_names.each do |field_name|
        define_sensitive_json_accessors(field_name)
      end
    end

    def encrypts_sensitive_string_array(*field_names)
      field_names.each do |field_name|
        define_sensitive_string_array_accessors(field_name)
      end
    end

    def has_email_lookup(field_name, digest_column:)
      digest_writer = proc do
        self[digest_column] = SensitiveData.email_digest(public_send(field_name)) if has_attribute?(digest_column)
      end
      # Validating must not dirty a record that nobody touched, or association autosave
      # would persist (and journal) rows solely to backfill the digest.
      before_validation(if: -> { new_record? || attribute_changed?(field_name) }, &digest_writer)
      before_save(&digest_writer)

      scope :"by_#{field_name}", lambda { |email|
        digest = SensitiveData.email_digest(email)
        normalized = SensitiveData.normalize_email(email)
        if digest.present?
          where(digest_column => digest).or(where("LOWER(#{table_name}.#{field_name}) = ?", normalized))
        else
          none
        end
      }
    end

    private

    # Each encryption draws a fresh nonce, so re-encoding an unchanged value produces
    # different ciphertext and leaves the record dirty. Every writer below therefore treats
    # assigning the value a record already holds as a no-op. Without that, normalising a
    # field during validation is enough to make an untouched record save itself, taking its
    # after_save callbacks — journal entries, Authentik sync flags — along with it.
    #
    # A column still holding plaintext is never left alone: assigning to it encrypts it,
    # which is what lets the values written before the backfill settle over time.
    #
    # Neither is ciphertext the configured key can no longer read. Comparing against it is
    # impossible — decrypting is how you find out — so an unreadable value counts as unsettled
    # and gets overwritten. Without that, assignment raises, and the recovery from a key
    # change is exactly the code that has to assign over the orphaned value.
    def define_sensitive_string_accessors(field_name)
      define_method(field_name) do
        SensitiveData.decode_string(self[field_name])
      end

      define_method("#{field_name}=") do |value|
        normalized = value.presence
        stored = self[field_name]
        current = SensitiveData.decode_string_if_readable(stored)
        settled = normalized.nil? ? stored.nil? : SensitiveData.encrypted_string?(stored) && !current.nil?
        next if settled && normalized == current

        self[field_name] = normalized.nil? ? nil : SensitiveData.encode_string(normalized)
      end
    end

    def define_sensitive_json_accessors(field_name)
      define_method(field_name) do
        SensitiveData.decode_json(self[field_name])
      end

      define_method("#{field_name}=") do |value|
        stored = self[field_name]
        current = SensitiveData.decode_json_if_readable(stored)
        settled = value.nil? ? stored.nil? : SensitiveData.encrypted_json?(stored) && !current.nil?
        # Round-tripped so a payload keyed by symbols compares equal to the stored one,
        # which JSON always gives back keyed by strings.
        incoming = value.nil? ? nil : JSON.parse(JSON.generate(value))
        next if settled && incoming == current

        self[field_name] = value.nil? ? nil : SensitiveData.encode_json(value)
      end
    end

    def define_sensitive_string_array_accessors(field_name)
      define_method(field_name) do
        Array(self[field_name]).map { |value| SensitiveData.decode_string(value) }
      end

      define_method("#{field_name}=") do |values|
        normalized = Array(values).filter_map { |value| value.to_s.strip.presence }
        stored = Array(self[field_name])
        current = stored.map { |value| SensitiveData.decode_string_if_readable(value) }
        settled = stored.all? { |value| SensitiveData.encrypted_string?(value) } && current.none?(&:nil?)
        next if settled && normalized == current

        self[field_name] = normalized.map { |value| SensitiveData.encode_string(value) }
      end
    end
  end
  # rubocop:enable Metrics/BlockLength
end
