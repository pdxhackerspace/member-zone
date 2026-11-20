# Nothing joins a reminder to its templates in the database — QueuedMail resolves a template
# from the mailer action at send time — so the catalog names the keys a reminder can send.
module ReminderSettingTemplates
  extend ActiveSupport::Concern

  class_methods do
    # Every reminder's templates in one query, for pages that list the whole catalog.
    def email_templates_by_reminder_key
      found = EmailTemplate.where(key: catalog_email_template_keys).index_by(&:key)
      ReminderSetting::CATALOG.transform_values do |attrs|
        attrs.fetch(:email_template_keys, []).filter_map { |key| found[key] }
      end
    end

    def catalog_email_template_keys
      ReminderSetting::CATALOG.values.flat_map { |attrs| attrs.fetch(:email_template_keys, []) }
    end

    # Catalog order is the order the reminder sends them in, which the database cannot express.
    def templates_for_keys(keys)
      return [] if keys.empty?

      found = EmailTemplate.where(key: keys).index_by(&:key)
      keys.filter_map { |key| found[key] }
    end
  end

  def email_template_keys
    ReminderSetting::CATALOG.dig(key, :email_template_keys) || []
  end

  def email_templates
    self.class.templates_for_keys(email_template_keys)
  end
end
