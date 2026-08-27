# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_26_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "access_controller_logs", force: :cascade do |t|
    t.bigint "access_controller_id", null: false
    t.string "action", null: false
    t.string "command_line"
    t.datetime "created_at", null: false
    t.integer "exit_code"
    t.text "output"
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.index ["access_controller_id"], name: "index_access_controller_logs_on_access_controller_id"
    t.index ["action"], name: "index_access_controller_logs_on_action"
    t.index ["created_at"], name: "index_access_controller_logs_on_created_at"
    t.index ["status"], name: "index_access_controller_logs_on_status"
  end

  create_table "access_controller_type_training_topics", force: :cascade do |t|
    t.bigint "access_controller_type_id", null: false
    t.datetime "created_at", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["access_controller_type_id", "training_topic_id"], name: "idx_act_training_topics_unique", unique: true
    t.index ["access_controller_type_id"], name: "idx_act_training_topics_on_act_id"
    t.index ["training_topic_id"], name: "idx_act_training_topics_on_topic_id"
  end

  create_table "access_controller_types", force: :cascade do |t|
    t.jsonb "actions", default: [], null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "script_path", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_access_controller_types_on_enabled"
    t.index ["name"], name: "index_access_controller_types_on_name", unique: true
  end

  create_table "access_controllers", force: :cascade do |t|
    t.bigint "access_controller_type_id"
    t.string "access_token"
    t.string "backup_status", default: "unknown"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "display_order", default: 0
    t.boolean "enabled", default: true, null: false
    t.text "environment_variables"
    t.string "hostname", null: false
    t.datetime "last_backup_at"
    t.datetime "last_ping_at"
    t.datetime "last_sync_at"
    t.string "name", null: false
    t.string "nickname"
    t.string "ping_status", default: "unknown"
    t.string "script_arguments"
    t.string "sync_status", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.index ["access_controller_type_id"], name: "index_access_controllers_on_access_controller_type_id"
    t.index ["enabled"], name: "index_access_controllers_on_enabled"
    t.index ["hostname"], name: "index_access_controllers_on_hostname"
    t.index ["name"], name: "index_access_controllers_on_name", unique: true
  end

  create_table "access_logs", force: :cascade do |t|
    t.string "action"
    t.datetime "created_at", null: false
    t.string "location"
    t.datetime "logged_at"
    t.string "name"
    t.text "raw_text"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["location"], name: "index_access_logs_on_location"
    t.index ["logged_at"], name: "index_access_logs_on_logged_at"
    t.index ["name"], name: "index_access_logs_on_name"
    t.index ["user_id"], name: "index_access_logs_on_user_id"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_ollama_profiles", force: :cascade do |t|
    t.bigint "ai_provider_id"
    t.string "api_key"
    t.text "base_url"
    t.datetime "created_at", null: false
    t.integer "display_order", default: 0, null: false
    t.boolean "enabled", default: true, null: false
    t.string "health_status", default: "unknown", null: false
    t.string "key", null: false
    t.datetime "last_health_check_at"
    t.text "last_health_error"
    t.string "model"
    t.string "name", null: false
    t.text "prompt"
    t.string "provider_api_key_override"
    t.string "provider_name_override"
    t.string "provider_url_override"
    t.datetime "updated_at", null: false
    t.index ["ai_provider_id"], name: "index_ai_ollama_profiles_on_ai_provider_id"
    t.index ["key"], name: "index_ai_ollama_profiles_on_key", unique: true
  end

  create_table "ai_providers", force: :cascade do |t|
    t.string "api_key"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["name"], name: "index_ai_providers_on_name", unique: true
  end

  create_table "application_answers", force: :cascade do |t|
    t.bigint "application_form_question_id", null: false
    t.datetime "created_at", null: false
    t.bigint "membership_application_id", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["application_form_question_id"], name: "index_application_answers_on_application_form_question_id"
    t.index ["membership_application_id", "application_form_question_id"], name: "idx_answers_application_question", unique: true
    t.index ["membership_application_id"], name: "index_application_answers_on_membership_application_id"
  end

  create_table "application_form_pages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "position", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["position"], name: "index_application_form_pages_on_position"
  end

  create_table "application_form_questions", force: :cascade do |t|
    t.bigint "application_form_page_id", null: false
    t.datetime "created_at", null: false
    t.string "field_type", default: "text", null: false
    t.text "help_text"
    t.text "label", null: false
    t.text "options_json"
    t.integer "position", default: 0, null: false
    t.boolean "required", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["application_form_page_id", "position"], name: "idx_form_questions_page_position"
    t.index ["application_form_page_id"], name: "index_application_form_questions_on_application_form_page_id"
  end

  create_table "application_groups", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.string "authentik_group_id"
    t.string "authentik_name"
    t.string "authentik_policy_id"
    t.datetime "created_at", null: false
    t.string "member_source", default: "manual", null: false
    t.string "name"
    t.text "note"
    t.bigint "sync_with_group_id"
    t.bigint "training_topic_id"
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_application_groups_on_application_id"
    t.index ["authentik_group_id"], name: "index_application_groups_on_authentik_group_id"
    t.index ["authentik_policy_id"], name: "index_application_groups_on_authentik_policy_id"
    t.index ["member_source"], name: "index_application_groups_on_member_source"
    t.index ["sync_with_group_id"], name: "index_application_groups_on_sync_with_group_id"
    t.index ["training_topic_id"], name: "index_application_groups_on_training_topic_id"
  end

  create_table "application_groups_users", id: false, force: :cascade do |t|
    t.bigint "application_group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["application_group_id", "user_id"], name: "index_app_groups_users_on_group_and_user", unique: true
    t.index ["application_group_id"], name: "index_application_groups_users_on_application_group_id"
    t.index ["user_id"], name: "index_application_groups_users_on_user_id"
  end

  create_table "application_verifications", force: :cascade do |t|
    t.integer "application_link_reminder_count", default: 0, null: false
    t.datetime "application_link_reminder_sent_at"
    t.boolean "confirmed_code_of_conduct", default: false, null: false
    t.boolean "confirmed_open_house", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_lookup_digest"
    t.boolean "email_verified", default: false, null: false
    t.datetime "expires_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["email"], name: "index_application_verifications_on_email"
    t.index ["email_lookup_digest"], name: "index_application_verifications_on_email_lookup_digest"
    t.index ["token"], name: "index_application_verifications_on_token", unique: true
  end

  create_table "applications", force: :cascade do |t|
    t.string "authentik_prefix"
    t.datetime "created_at", null: false
    t.string "external_url"
    t.string "internal_url"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "authentik_users", force: :cascade do |t|
    t.string "authentik_id", null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "email_lookup_digest"
    t.string "full_name"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_superuser", default: false, null: false
    t.datetime "last_synced_at"
    t.jsonb "raw_attributes", default: {}, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "username"
    t.index ["authentik_id"], name: "index_authentik_users_on_authentik_id", unique: true
    t.index ["email"], name: "index_authentik_users_on_email"
    t.index ["email_lookup_digest"], name: "index_authentik_users_on_email_lookup_digest"
    t.index ["raw_attributes"], name: "index_authentik_users_on_raw_attributes", using: :gin
    t.index ["user_id"], name: "index_authentik_users_on_user_id"
  end

  create_table "cash_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.bigint "membership_plan_id", null: false
    t.text "notes"
    t.date "paid_on", null: false
    t.bigint "recorded_by_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["membership_plan_id"], name: "index_cash_payments_on_membership_plan_id"
    t.index ["paid_on"], name: "index_cash_payments_on_paid_on", order: :desc
    t.index ["recorded_by_id"], name: "index_cash_payments_on_recorded_by_id"
    t.index ["user_id"], name: "index_cash_payments_on_user_id"
  end

  create_table "default_settings", force: :cascade do |t|
    t.string "active_members_group", null: false
    t.string "admins_group", null: false
    t.string "all_members_group", null: false
    t.string "app_prefix", null: false
    t.boolean "authentik_sync_inactive_as_active", default: true, null: false
    t.string "can_train_prefix", null: false
    t.datetime "created_at", null: false
    t.boolean "login_keyfob_sign_in_enabled", default: true, null: false
    t.decimal "map_center_latitude", precision: 10, scale: 6, default: "45.581678", null: false
    t.decimal "map_center_longitude", precision: 10, scale: 6, default: "-122.682156", null: false
    t.string "map_default_city", default: "Portland", null: false
    t.string "map_default_state", default: "Oregon", null: false
    t.decimal "map_radius_miles", precision: 5, scale: 2, default: "4.0", null: false
    t.string "members_prefix", null: false
    t.integer "rfid_facility_code", default: 127, null: false
    t.string "site_prefix", default: "ctrlh", null: false
    t.boolean "sync_inactive_members", default: false, null: false
    t.string "trained_on_prefix", null: false
    t.string "unbanned_members_group", null: false
    t.datetime "updated_at", null: false
  end

  create_table "document_training_topics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "document_id", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id"], name: "index_document_training_topics_on_document_id"
    t.index ["training_topic_id"], name: "index_document_training_topics_on_training_topic_id"
  end

  create_table "documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "show_on_all_profiles", default: false, null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "email_notification_opt_outs", force: :cascade do |t|
    t.string "category", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_lookup_digest"
    t.string "source", default: "email_link", null: false
    t.datetime "updated_at", null: false
    t.index ["category", "channel"], name: "index_email_notification_opt_outs_on_category_and_channel"
    t.index ["email_lookup_digest", "category", "channel"], name: "index_email_opt_outs_on_digest_category_channel", unique: true
  end

  create_table "email_templates", force: :cascade do |t|
    t.boolean "block_send_immediately", default: false, null: false
    t.text "body_html", null: false
    t.text "body_text", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.boolean "enabled", default: true, null: false
    t.string "key", null: false
    t.string "name", null: false
    t.boolean "needs_review", default: true, null: false
    t.boolean "send_immediately", default: false, null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_email_templates_on_key", unique: true
    t.index ["needs_review"], name: "index_email_templates_on_needs_review"
  end

  create_table "incident_report_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "incident_report_id", null: false
    t.integer "position", default: 0
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["incident_report_id", "position"], name: "index_incident_report_links_on_incident_report_id_and_position"
    t.index ["incident_report_id"], name: "index_incident_report_links_on_incident_report_id"
  end

  create_table "incident_report_members", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "incident_report_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["incident_report_id", "user_id"], name: "idx_incident_report_members_unique", unique: true
    t.index ["incident_report_id"], name: "index_incident_report_members_on_incident_report_id"
    t.index ["user_id"], name: "index_incident_report_members_on_user_id"
  end

  create_table "incident_reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "incident_date", null: false
    t.string "incident_type", null: false
    t.string "other_type_explanation"
    t.bigint "reporter_id", null: false
    t.text "resolution"
    t.string "status", default: "draft", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["incident_date"], name: "index_incident_reports_on_incident_date"
    t.index ["incident_type"], name: "index_incident_reports_on_incident_type"
    t.index ["reporter_id"], name: "index_incident_reports_on_reporter_id"
    t.index ["status"], name: "index_incident_reports_on_status"
  end

  create_table "incoming_webhooks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.string "webhook_type", null: false
    t.index ["slug"], name: "index_incoming_webhooks_on_slug", unique: true
    t.index ["webhook_type"], name: "index_incoming_webhooks_on_webhook_type", unique: true
  end

  create_table "interests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.boolean "needs_review", default: false, null: false
    t.boolean "seeded", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_interests_on_name", unique: true
    t.index ["needs_review"], name: "index_interests_on_needs_review"
    t.index ["seeded"], name: "index_interests_on_seeded"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_lookup_digest"
    t.datetime "expires_at", null: false
    t.bigint "invited_by_id", null: false
    t.string "membership_type", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["email"], name: "index_invitations_on_email"
    t.index ["email_lookup_digest"], name: "index_invitations_on_email_lookup_digest"
    t.index ["expires_at"], name: "index_invitations_on_expires_at"
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["membership_type"], name: "index_invitations_on_membership_type"
    t.index ["token"], name: "index_invitations_on_token", unique: true
    t.index ["user_id"], name: "index_invitations_on_user_id"
  end

  create_table "journals", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id"
    t.datetime "changed_at", null: false
    t.jsonb "changes_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "highlight", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["actor_user_id"], name: "index_journals_on_actor_user_id"
    t.index ["changed_at"], name: "index_journals_on_changed_at"
    t.index ["highlight"], name: "index_journals_on_highlight"
    t.index ["user_id"], name: "index_journals_on_user_id"
  end

  create_table "kofi_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "email"
    t.string "email_lookup_digest"
    t.string "from_name"
    t.boolean "is_first_subscription_payment", default: false
    t.boolean "is_public", default: false
    t.boolean "is_subscription_payment", default: false
    t.string "kofi_transaction_id", null: false
    t.datetime "last_synced_at"
    t.text "message"
    t.string "message_id"
    t.string "payment_type"
    t.jsonb "raw_attributes", default: {}, null: false
    t.bigint "sheet_entry_id"
    t.jsonb "shop_items", default: []
    t.string "status"
    t.string "tier_name"
    t.datetime "timestamp"
    t.datetime "updated_at", null: false
    t.string "url"
    t.bigint "user_id"
    t.index ["email"], name: "index_kofi_payments_on_email"
    t.index ["email_lookup_digest"], name: "index_kofi_payments_on_email_lookup_digest"
    t.index ["kofi_transaction_id"], name: "index_kofi_payments_on_kofi_transaction_id", unique: true
    t.index ["message_id"], name: "index_kofi_payments_on_message_id"
    t.index ["sheet_entry_id"], name: "index_kofi_payments_on_sheet_entry_id"
    t.index ["user_id"], name: "index_kofi_payments_on_user_id"
  end

  create_table "local_accounts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_lookup_digest"
    t.string "full_name"
    t.datetime "last_signed_in_at"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_lookup_digest"], name: "index_local_accounts_on_email_lookup_digest", unique: true, where: "(email_lookup_digest IS NOT NULL)"
  end

  create_table "mail_log_entries", force: :cascade do |t|
    t.bigint "actor_id"
    t.datetime "created_at", null: false
    t.string "delivery_action"
    t.text "delivery_body_html"
    t.text "delivery_body_text"
    t.string "delivery_mailer"
    t.string "delivery_subject"
    t.string "delivery_to"
    t.string "details"
    t.string "event", null: false
    t.bigint "queued_mail_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_mail_log_entries_on_actor_id"
    t.index ["created_at"], name: "index_mail_log_entries_on_created_at"
    t.index ["event"], name: "index_mail_log_entries_on_event"
    t.index ["queued_mail_id"], name: "index_mail_log_entries_on_queued_mail_id"
  end

  create_table "member_sources", force: :cascade do |t|
    t.boolean "api_configured", default: false
    t.integer "consecutive_error_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "display_order", default: 0
    t.boolean "enabled", default: true, null: false
    t.integer "entry_count", default: 0
    t.string "key", null: false
    t.text "last_error_message"
    t.datetime "last_successful_sync_at"
    t.datetime "last_sync_at"
    t.integer "linked_count", default: 0
    t.string "name", null: false
    t.text "notes"
    t.string "sync_status", default: "unknown", null: false
    t.integer "unlinked_count", default: 0
    t.datetime "updated_at", null: false
    t.index ["display_order"], name: "index_member_sources_on_display_order"
    t.index ["enabled"], name: "index_member_sources_on_enabled"
    t.index ["key"], name: "index_member_sources_on_key", unique: true
  end

  create_table "membership_application_acceptance_votes", force: :cascade do |t|
    t.text "comment"
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.bigint "membership_application_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["membership_application_id", "user_id"], name: "idx_ma_acceptance_votes_app_user", unique: true
    t.index ["user_id"], name: "index_membership_application_acceptance_votes_on_user_id"
  end

  create_table "membership_application_ai_feedback_votes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "membership_application_id", null: false
    t.text "reason"
    t.string "stance", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["membership_application_id", "user_id"], name: "idx_ma_ai_fb_votes_app_user", unique: true
  end

  create_table "membership_application_tour_feedbacks", force: :cascade do |t|
    t.text "attitude"
    t.datetime "created_at", null: false
    t.text "engagement"
    t.text "fit_feeling"
    t.text "impressions"
    t.bigint "membership_application_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["membership_application_id", "user_id"], name: "idx_ma_tour_feedbacks_app_user", unique: true
    t.index ["user_id"], name: "index_membership_application_tour_feedbacks_on_user_id"
  end

  create_table "membership_applications", force: :cascade do |t|
    t.text "admin_notes"
    t.boolean "ai_feedback_garbage", default: false, null: false
    t.text "ai_feedback_garbage_reason"
    t.text "ai_feedback_last_error"
    t.datetime "ai_feedback_processed_at"
    t.jsonb "ai_feedback_questions", default: [], null: false
    t.string "ai_feedback_recommendation"
    t.integer "ai_feedback_score"
    t.text "ai_feedback_score_rationale"
    t.datetime "application_reminder_sent_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "email_lookup_digest"
    t.text "outcome_email_body_html"
    t.string "outcome_email_subject"
    t.bigint "outcome_queued_mail_id"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["ai_feedback_processed_at"], name: "index_membership_applications_on_ai_feedback_processed_at"
    t.index ["application_reminder_sent_at"], name: "index_membership_applications_on_application_reminder_sent_at"
    t.index ["email"], name: "index_membership_applications_on_email"
    t.index ["email_lookup_digest"], name: "index_membership_applications_on_email_lookup_digest"
    t.index ["outcome_queued_mail_id"], name: "index_membership_applications_on_outcome_queued_mail_id"
    t.index ["reviewed_by_id"], name: "index_membership_applications_on_reviewed_by_id"
    t.index ["status"], name: "index_membership_applications_on_status"
    t.index ["token"], name: "index_membership_applications_on_token", unique: true
    t.index ["user_id"], name: "index_membership_applications_on_user_id"
  end

  create_table "membership_plans", force: :cascade do |t|
    t.string "billing_frequency", null: false
    t.integer "billing_period_days"
    t.decimal "cost", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "display_order", default: 1, null: false
    t.boolean "manual", default: false, null: false
    t.string "name", null: false
    t.string "payment_link"
    t.string "paypal_transaction_subject"
    t.string "plan_type", default: "primary", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.boolean "visible", default: true, null: false
    t.index ["display_order"], name: "index_membership_plans_on_display_order"
    t.index ["manual"], name: "index_membership_plans_on_manual"
    t.index ["name"], name: "index_membership_plans_on_name_shared", unique: true, where: "(user_id IS NULL)"
    t.index ["plan_type"], name: "index_membership_plans_on_plan_type"
    t.index ["user_id"], name: "index_membership_plans_on_user_id"
    t.index ["visible"], name: "index_membership_plans_on_visible"
  end

  create_table "membership_settings", force: :cascade do |t|
    t.integer "admin_login_link_expiry_minutes", default: 15, null: false
    t.integer "application_link_reminder_delay_days", default: 3, null: false
    t.integer "application_link_reminder_max_count", default: 3, null: false
    t.integer "application_review_time_cap_days", default: 15, null: false
    t.integer "application_verification_expiry_hours", default: 24, null: false
    t.bigint "building_access_training_topic_id"
    t.datetime "created_at", null: false
    t.integer "invitation_expiry_hours", default: 72, null: false
    t.integer "login_link_expiry_hours", default: 180, null: false
    t.integer "manual_payment_due_soon_days", default: 7, null: false
    t.integer "new_member_expiry_days", default: 90, null: false
    t.integer "new_member_grace_period_days", default: 14, null: false
    t.integer "orientation_reminder_repeat_days", default: 14, null: false
    t.integer "overdue_grace_period_days", default: 30, null: false
    t.integer "parking_notice_expired_reminder_repeat_days", default: 7, null: false
    t.integer "parking_notice_final_reminder_days_after_expiration", default: 14, null: false
    t.integer "parking_notice_reminder_days_before_expiration", default: 3, null: false
    t.integer "payment_currency_buffer_days", default: 2, null: false
    t.integer "payment_grace_period_days", default: 14, null: false
    t.integer "payment_overdue_reminder_repeat_days", default: 7, null: false
    t.integer "planless_payment_window_days", default: 32, null: false
    t.integer "reactivation_grace_period_months", default: 12, null: false
    t.integer "slack_signup_reminder_initial_delay_days", default: 7, null: false
    t.integer "slack_signup_reminder_max_account_age_months", default: 6, null: false
    t.integer "slack_signup_reminder_repeat_delay_days", default: 14, null: false
    t.datetime "updated_at", null: false
    t.boolean "use_builtin_membership_application", default: true, null: false
    t.index ["building_access_training_topic_id"], name: "index_membership_settings_on_building_access_training_topic_id"
  end

  create_table "messages", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_by_recipient_at"
    t.datetime "deleted_by_sender_at"
    t.datetime "read_at"
    t.bigint "recipient_id", null: false
    t.bigint "sender_id", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["recipient_id", "created_at"], name: "index_messages_on_recipient_id_and_created_at"
    t.index ["recipient_id", "deleted_by_recipient_at"], name: "index_messages_on_recipient_id_and_deleted_by_recipient_at"
    t.index ["recipient_id"], name: "index_messages_on_recipient_id"
    t.index ["sender_id", "created_at"], name: "index_messages_on_sender_id_and_created_at"
    t.index ["sender_id", "deleted_by_sender_at"], name: "index_messages_on_sender_id_and_deleted_by_sender_at"
    t.index ["sender_id"], name: "index_messages_on_sender_id"
  end

  create_table "notification_opt_outs", force: :cascade do |t|
    t.string "category", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "source", default: "self_service", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["category", "channel"], name: "index_notification_opt_outs_on_category_and_channel"
    t.index ["user_id", "category", "channel"], name: "index_notification_opt_outs_on_user_category_channel", unique: true
    t.index ["user_id"], name: "index_notification_opt_outs_on_user_id"
  end

  create_table "parking_notice_events", force: :cascade do |t|
    t.bigint "actor_id"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.text "note"
    t.bigint "parking_notice_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_parking_notice_events_on_actor_id"
    t.index ["event_type"], name: "index_parking_notice_events_on_event_type"
    t.index ["parking_notice_id", "created_at"], name: "idx_on_parking_notice_id_created_at_1c4803fe34"
    t.index ["parking_notice_id"], name: "index_parking_notice_events_on_parking_notice_id"
  end

  create_table "parking_notices", force: :cascade do |t|
    t.datetime "clearance_requested_at"
    t.bigint "clearance_requested_by_id"
    t.datetime "cleared_at"
    t.bigint "cleared_by_id"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "expiration_notice_sent_at"
    t.datetime "expires_at", null: false
    t.datetime "final_reminder_sent_at"
    t.bigint "issued_by_id", null: false
    t.string "location"
    t.string "location_detail"
    t.text "notes"
    t.string "notice_type", null: false
    t.datetime "overdue_reminder_sent_at"
    t.datetime "pre_expiration_reminder_sent_at"
    t.boolean "requires_admin_clearance", default: false, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["clearance_requested_at"], name: "index_parking_notices_on_clearance_requested_at"
    t.index ["clearance_requested_by_id"], name: "index_parking_notices_on_clearance_requested_by_id"
    t.index ["cleared_by_id"], name: "index_parking_notices_on_cleared_by_id"
    t.index ["expiration_notice_sent_at"], name: "index_parking_notices_on_expiration_notice_sent_at"
    t.index ["expires_at"], name: "index_parking_notices_on_expires_at"
    t.index ["issued_by_id"], name: "index_parking_notices_on_issued_by_id"
    t.index ["notice_type", "status"], name: "index_parking_notices_on_notice_type_and_status"
    t.index ["pre_expiration_reminder_sent_at"], name: "index_parking_notices_on_pre_expiration_reminder_sent_at"
    t.index ["requires_admin_clearance"], name: "index_parking_notices_on_requires_admin_clearance"
    t.index ["status"], name: "index_parking_notices_on_status"
    t.index ["user_id"], name: "index_parking_notices_on_user_id"
  end

  create_table "payment_events", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2
    t.bigint "cash_payment_id"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.text "details"
    t.string "event_type", null: false
    t.string "external_id"
    t.bigint "kofi_payment_id"
    t.datetime "occurred_at", null: false
    t.bigint "paypal_payment_id"
    t.bigint "recharge_payment_id"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["cash_payment_id"], name: "index_payment_events_on_cash_payment_id"
    t.index ["event_type"], name: "index_payment_events_on_event_type"
    t.index ["external_id"], name: "index_payment_events_on_external_id"
    t.index ["kofi_payment_id"], name: "index_payment_events_on_kofi_payment_id"
    t.index ["occurred_at"], name: "index_payment_events_on_occurred_at"
    t.index ["paypal_payment_id"], name: "index_payment_events_on_paypal_payment_id"
    t.index ["recharge_payment_id"], name: "index_payment_events_on_recharge_payment_id"
    t.index ["source"], name: "index_payment_events_on_source"
    t.index ["user_id"], name: "index_payment_events_on_user_id"
  end

  create_table "payment_processors", force: :cascade do |t|
    t.decimal "amount_last_30_days", precision: 12, scale: 2, default: "0.0"
    t.boolean "api_configured", default: false
    t.decimal "average_payment_amount", precision: 12, scale: 2, default: "0.0"
    t.integer "consecutive_error_count", default: 0
    t.datetime "created_at", null: false
    t.integer "csv_import_count", default: 0
    t.integer "display_order", default: 0
    t.boolean "enabled", default: true, null: false
    t.string "key", null: false
    t.datetime "last_csv_import_at"
    t.string "last_error_message"
    t.datetime "last_successful_sync_at"
    t.datetime "last_sync_at"
    t.integer "matched_payments_count", default: 0
    t.string "name", null: false
    t.text "notes"
    t.string "payment_link"
    t.string "sync_status", default: "unknown"
    t.decimal "total_amount", precision: 12, scale: 2, default: "0.0"
    t.integer "total_payments_count", default: 0
    t.integer "unmatched_payments_count", default: 0
    t.datetime "updated_at", null: false
    t.boolean "webhook_configured", default: false
    t.datetime "webhook_last_received_at"
    t.string "webhook_url"
    t.index ["display_order"], name: "index_payment_processors_on_display_order"
    t.index ["enabled"], name: "index_payment_processors_on_enabled"
    t.index ["key"], name: "index_payment_processors_on_key", unique: true
  end

  create_table "paypal_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.string "currency"
    t.boolean "dont_link", default: false, null: false
    t.datetime "last_synced_at"
    t.boolean "matches_plan", default: true, null: false
    t.string "payer_email"
    t.string "payer_email_lookup_digest"
    t.string "payer_id"
    t.string "payer_name"
    t.string "paypal_id", null: false
    t.jsonb "raw_attributes", default: {}, null: false
    t.string "status"
    t.datetime "transaction_time"
    t.string "transaction_type"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["matches_plan"], name: "index_paypal_payments_on_matches_plan"
    t.index ["payer_email"], name: "index_paypal_payments_on_payer_email"
    t.index ["payer_email_lookup_digest"], name: "index_paypal_payments_on_payer_email_lookup_digest"
    t.index ["paypal_id"], name: "index_paypal_payments_on_paypal_id", unique: true
    t.index ["user_id"], name: "index_paypal_payments_on_user_id"
  end

  create_table "printers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cups_printer_name", null: false
    t.string "cups_printer_server", default: "", null: false
    t.boolean "default_printer", default: false, null: false
    t.string "description"
    t.string "health_status", default: "unknown", null: false
    t.datetime "last_health_check_at"
    t.string "last_health_error"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "thermal_roll_width_mm"
    t.datetime "updated_at", null: false
    t.index ["cups_printer_server", "cups_printer_name"], name: "index_printers_on_cups_printer_server_and_cups_printer_name", unique: true
    t.index ["health_status"], name: "index_printers_on_health_status"
    t.index ["name"], name: "index_printers_on_name", unique: true
  end

  create_table "privileges", force: :cascade do |t|
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.string "label", null: false
    t.string "privilege_scope", default: "global", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_privileges_on_key", unique: true
    t.index ["privilege_scope"], name: "index_privileges_on_privilege_scope"
  end

  create_table "queued_mails", force: :cascade do |t|
    t.text "body_html", null: false
    t.text "body_text"
    t.datetime "created_at", null: false
    t.bigint "email_template_id"
    t.text "last_error"
    t.datetime "last_error_at"
    t.string "mailer_action", null: false
    t.jsonb "mailer_args", default: {}
    t.string "reason", null: false
    t.bigint "recipient_id"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.integer "send_attempts", default: 0, null: false
    t.datetime "sent_at"
    t.string "status", default: "pending", null: false
    t.string "subject", null: false
    t.string "to", null: false
    t.datetime "updated_at", null: false
    t.index ["email_template_id"], name: "index_queued_mails_on_email_template_id"
    t.index ["recipient_id"], name: "index_queued_mails_on_recipient_id"
    t.index ["reviewed_by_id"], name: "index_queued_mails_on_reviewed_by_id"
    t.index ["status"], name: "index_queued_mails_on_status"
  end

  create_table "recharge_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.string "charge_type"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "customer_email"
    t.string "customer_email_lookup_digest"
    t.string "customer_id"
    t.string "customer_name"
    t.boolean "dont_link", default: false, null: false
    t.datetime "last_synced_at"
    t.datetime "processed_at"
    t.jsonb "raw_attributes", default: {}, null: false
    t.string "recharge_id", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["customer_email"], name: "index_recharge_payments_on_customer_email"
    t.index ["customer_email_lookup_digest"], name: "index_recharge_payments_on_customer_email_lookup_digest"
    t.index ["customer_id"], name: "index_recharge_payments_on_customer_id"
    t.index ["processed_at"], name: "index_recharge_payments_on_processed_at", order: :desc
    t.index ["recharge_id"], name: "index_recharge_payments_on_recharge_id", unique: true
    t.index ["user_id"], name: "index_recharge_payments_on_user_id"
  end

  create_table "reminder_settings", force: :cascade do |t|
    t.boolean "allow_opt_out", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: false, null: false
    t.string "key", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_reminder_settings_on_enabled"
    t.index ["key"], name: "index_reminder_settings_on_key", unique: true
  end

  create_table "rfid_readers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", limit: 32, null: false
    t.text "key_ciphertext"
    t.string "key_lookup_digest"
    t.string "name", null: false
    t.text "note"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_rfid_readers_on_key", unique: true
    t.index ["key_lookup_digest"], name: "index_rfid_readers_on_key_lookup_digest", unique: true, where: "(key_lookup_digest IS NOT NULL)"
  end

  create_table "rfids", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "notes"
    t.string "rfid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["rfid"], name: "index_rfids_on_rfid"
    t.index ["user_id"], name: "index_rfids_on_user_id"
  end

  create_table "role_privileges", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "privilege_id", null: false
    t.bigint "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["privilege_id"], name: "index_role_privileges_on_privilege_id"
    t.index ["role_id", "privilege_id"], name: "index_role_privileges_on_role_id_and_privilege_id", unique: true
    t.index ["role_id"], name: "index_role_privileges_on_role_id"
  end

  create_table "roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_roles_on_name", unique: true
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_rooms_on_name", unique: true
    t.index ["position"], name: "index_rooms_on_position"
  end

  create_table "sheet_entries", force: :cascade do |t|
    t.string "alias_name"
    t.datetime "created_at", null: false
    t.datetime "date_added"
    t.string "dirty"
    t.string "dremel"
    t.string "email"
    t.string "email_lookup_digest"
    t.string "embroidery_machine"
    t.string "ender"
    t.string "event_host"
    t.string "general_shop"
    t.string "laminator"
    t.string "laser"
    t.datetime "last_synced_at"
    t.string "longmill"
    t.string "mpcnc_marlin"
    t.string "name", null: false
    t.text "notes"
    t.string "payment"
    t.string "paypal_name"
    t.string "prusa"
    t.jsonb "raw_attributes", default: {}, null: false
    t.string "rfid"
    t.string "serger"
    t.string "sewing_machine"
    t.string "shaper"
    t.string "status"
    t.string "twitter"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "vinyl_cutter"
    t.index ["email"], name: "index_sheet_entries_on_email"
    t.index ["email_lookup_digest"], name: "index_sheet_entries_on_email_lookup_digest"
    t.index ["name"], name: "index_sheet_entries_on_name"
    t.index ["user_id"], name: "index_sheet_entries_on_user_id"
  end

  create_table "slack_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "deleted", default: false, null: false
    t.string "display_name"
    t.boolean "dont_link", default: false, null: false
    t.string "email"
    t.string "email_lookup_digest"
    t.boolean "is_admin", default: false, null: false
    t.boolean "is_bot", default: false, null: false
    t.boolean "is_owner", default: false, null: false
    t.datetime "last_active_at"
    t.datetime "last_synced_at"
    t.string "phone"
    t.string "pronouns"
    t.jsonb "raw_attributes", default: {}, null: false
    t.string "real_name"
    t.string "slack_id", null: false
    t.boolean "slack_status", default: false, null: false
    t.string "team_id"
    t.string "title"
    t.string "tz"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "username"
    t.index ["email_lookup_digest"], name: "index_slack_users_on_email_lookup_digest", unique: true, where: "(email_lookup_digest IS NOT NULL)"
    t.index ["raw_attributes"], name: "index_slack_users_on_raw_attributes", using: :gin
    t.index ["slack_id"], name: "index_slack_users_on_slack_id", unique: true
    t.index ["user_id"], name: "index_slack_users_on_user_id"
  end

  create_table "text_fragments", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.string "key"
    t.string "source_url"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_text_fragments_on_key", unique: true
  end

  create_table "trainer_capabilities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["training_topic_id"], name: "index_trainer_capabilities_on_training_topic_id"
    t.index ["user_id", "training_topic_id"], name: "index_trainer_capabilities_on_user_id_and_training_topic_id", unique: true
    t.index ["user_id"], name: "index_trainer_capabilities_on_user_id"
  end

  create_table "training_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "dismissed_at"
    t.datetime "responded_at"
    t.bigint "responded_by_id"
    t.boolean "share_contact_info", default: false, null: false
    t.string "status", default: "pending", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["dismissed_at"], name: "index_training_requests_on_dismissed_at"
    t.index ["responded_by_id"], name: "index_training_requests_on_responded_by_id"
    t.index ["status"], name: "index_training_requests_on_status"
    t.index ["training_topic_id"], name: "index_training_requests_on_training_topic_id"
    t.index ["user_id", "training_topic_id", "status"], name: "idx_training_requests_user_topic_status"
    t.index ["user_id"], name: "index_training_requests_on_user_id"
  end

  create_table "training_topic_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "title", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["training_topic_id"], name: "index_training_topic_links_on_training_topic_id"
  end

  create_table "training_topic_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "member_source", null: false
    t.bigint "role_id", null: false
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id"], name: "index_training_topic_roles_on_role_id"
    t.index ["training_topic_id", "role_id", "member_source"], name: "index_training_topic_roles_on_topic_role_source", unique: true
    t.index ["training_topic_id"], name: "index_training_topic_roles_on_training_topic_id"
  end

  create_table "training_topics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.boolean "offered_to_members", default: true, null: false
    t.bigint "parent_id"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_training_topics_on_name", unique: true
    t.index ["offered_to_members"], name: "index_training_topics_on_offered_to_members"
    t.index ["parent_id"], name: "index_training_topics_on_parent_id"
  end

  create_table "trainings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "notes"
    t.datetime "trained_at", null: false
    t.bigint "trainee_id", null: false
    t.bigint "trainer_id"
    t.bigint "training_topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["trained_at"], name: "index_trainings_on_trained_at"
    t.index ["trainee_id"], name: "index_trainings_on_trainee_id"
    t.index ["trainer_id"], name: "index_trainings_on_trainer_id"
    t.index ["training_topic_id"], name: "index_trainings_on_training_topic_id"
  end

  create_table "user_interests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "interest_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["interest_id"], name: "index_user_interests_on_interest_id"
    t.index ["user_id", "interest_id"], name: "index_user_interests_on_user_id_and_interest_id", unique: true
    t.index ["user_id"], name: "index_user_interests_on_user_id"
  end

  create_table "user_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "position", default: 0
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "position"], name: "index_user_links_on_user_id_and_position"
    t.index ["user_id"], name: "index_user_links_on_user_id"
  end

  create_table "user_supplementary_plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "membership_plan_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["membership_plan_id"], name: "index_user_supplementary_plans_on_membership_plan_id"
    t.index ["user_id", "membership_plan_id"], name: "index_user_supplementary_plans_unique", unique: true
    t.index ["user_id"], name: "index_user_supplementary_plans_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.string "aliases", default: [], null: false, array: true
    t.jsonb "authentik_attributes", default: {}, null: false
    t.boolean "authentik_dirty", default: false, null: false
    t.string "authentik_id"
    t.string "avatar"
    t.text "bio"
    t.datetime "created_at", null: false
    t.boolean "do_not_greet", default: false, null: false
    t.datetime "dues_due_at"
    t.string "dues_status", default: "unknown"
    t.string "email"
    t.string "email_lookup_digest"
    t.boolean "emergency_active_override", default: false, null: false
    t.string "extra_email_lookup_digests", default: [], null: false, array: true
    t.string "extra_emails", default: [], array: true
    t.string "full_name"
    t.string "greeting_name"
    t.boolean "is_admin", default: false, null: false
    t.boolean "is_sponsored", default: false, null: false
    t.boolean "key_access_paused", default: false, null: false
    t.datetime "key_access_paused_at"
    t.datetime "last_login_at"
    t.date "last_payment_date"
    t.datetime "last_synced_at"
    t.boolean "legacy", default: false, null: false
    t.string "login_token"
    t.datetime "login_token_expires_at"
    t.text "mailing_address"
    t.datetime "mailing_geocoded_at"
    t.decimal "mailing_latitude", precision: 10, scale: 6
    t.decimal "mailing_longitude", precision: 10, scale: 6
    t.datetime "membership_cancelled_at"
    t.datetime "membership_cancelled_email_sent_at"
    t.date "membership_ended_date"
    t.bigint "membership_plan_id"
    t.date "membership_start_date"
    t.string "membership_state", default: "unknown", null: false
    t.datetime "membership_state_entered_at"
    t.string "membership_status", default: "unknown"
    t.text "notes"
    t.datetime "orientation_reminder_sent_at"
    t.datetime "payment_overdue_reminder_sent_at"
    t.string "payment_type", default: "unknown"
    t.string "paypal_account_id"
    t.string "phone_number"
    t.string "profile_visibility", default: "members", null: false
    t.string "pronouns"
    t.string "recharge_customer_id"
    t.datetime "recharge_most_recent_payment_date"
    t.boolean "seen_member_help", default: false, null: false
    t.boolean "service_account", default: false, null: false
    t.string "sign_name"
    t.string "slack_handle"
    t.string "slack_id"
    t.datetime "slack_signup_reminder_sent_at"
    t.datetime "updated_at", null: false
    t.boolean "use_full_name_for_greeting", default: true, null: false
    t.boolean "use_username_for_greeting", default: false, null: false
    t.string "username"
    t.index ["authentik_attributes"], name: "index_users_on_authentik_attributes", using: :gin
    t.index ["authentik_dirty"], name: "index_users_on_authentik_dirty"
    t.index ["authentik_id"], name: "index_users_on_authentik_id", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["email_lookup_digest"], name: "index_users_on_email_lookup_digest", unique: true, where: "(email_lookup_digest IS NOT NULL)"
    t.index ["extra_email_lookup_digests"], name: "index_users_on_extra_email_lookup_digests", using: :gin
    t.index ["is_sponsored"], name: "index_users_on_is_sponsored"
    t.index ["key_access_paused"], name: "index_users_on_key_access_paused"
    t.index ["legacy"], name: "index_users_on_legacy"
    t.index ["login_token"], name: "index_users_on_login_token", unique: true
    t.index ["membership_cancelled_at"], name: "index_users_on_membership_cancelled_at"
    t.index ["membership_plan_id"], name: "index_users_on_membership_plan_id"
    t.index ["membership_state", "membership_state_entered_at"], name: "idx_on_membership_state_membership_state_entered_at_31ea7f1f2e"
    t.index ["membership_state"], name: "index_users_on_membership_state"
    t.index ["orientation_reminder_sent_at"], name: "index_users_on_orientation_reminder_sent_at"
    t.index ["paypal_account_id"], name: "index_users_on_paypal_account_id"
    t.index ["recharge_customer_id"], name: "index_users_on_recharge_customer_id"
    t.index ["slack_signup_reminder_sent_at"], name: "index_users_on_slack_signup_reminder_sent_at"
    t.index ["username"], name: "index_users_on_username", unique: true, where: "(username IS NOT NULL)"
  end

  add_foreign_key "access_controller_logs", "access_controllers"
  add_foreign_key "access_controller_type_training_topics", "access_controller_types"
  add_foreign_key "access_controller_type_training_topics", "training_topics"
  add_foreign_key "access_controllers", "access_controller_types"
  add_foreign_key "access_logs", "users"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_ollama_profiles", "ai_providers", on_delete: :nullify
  add_foreign_key "application_answers", "application_form_questions"
  add_foreign_key "application_answers", "membership_applications"
  add_foreign_key "application_form_questions", "application_form_pages"
  add_foreign_key "application_groups", "application_groups", column: "sync_with_group_id"
  add_foreign_key "application_groups", "applications"
  add_foreign_key "application_groups", "training_topics"
  add_foreign_key "application_groups_users", "application_groups"
  add_foreign_key "application_groups_users", "users"
  add_foreign_key "authentik_users", "users"
  add_foreign_key "cash_payments", "membership_plans"
  add_foreign_key "cash_payments", "users"
  add_foreign_key "cash_payments", "users", column: "recorded_by_id"
  add_foreign_key "document_training_topics", "documents"
  add_foreign_key "document_training_topics", "training_topics"
  add_foreign_key "incident_report_links", "incident_reports"
  add_foreign_key "incident_report_members", "incident_reports"
  add_foreign_key "incident_report_members", "users"
  add_foreign_key "incident_reports", "users", column: "reporter_id"
  add_foreign_key "invitations", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "journals", "users"
  add_foreign_key "journals", "users", column: "actor_user_id"
  add_foreign_key "kofi_payments", "sheet_entries"
  add_foreign_key "kofi_payments", "users"
  add_foreign_key "mail_log_entries", "queued_mails"
  add_foreign_key "mail_log_entries", "users", column: "actor_id"
  add_foreign_key "membership_application_acceptance_votes", "membership_applications"
  add_foreign_key "membership_application_acceptance_votes", "users"
  add_foreign_key "membership_application_ai_feedback_votes", "membership_applications"
  add_foreign_key "membership_application_ai_feedback_votes", "users"
  add_foreign_key "membership_application_tour_feedbacks", "membership_applications"
  add_foreign_key "membership_application_tour_feedbacks", "users"
  add_foreign_key "membership_applications", "queued_mails", column: "outcome_queued_mail_id"
  add_foreign_key "membership_applications", "users"
  add_foreign_key "membership_applications", "users", column: "reviewed_by_id"
  add_foreign_key "membership_plans", "users"
  add_foreign_key "membership_settings", "training_topics", column: "building_access_training_topic_id"
  add_foreign_key "messages", "users", column: "recipient_id"
  add_foreign_key "messages", "users", column: "sender_id"
  add_foreign_key "notification_opt_outs", "users"
  add_foreign_key "parking_notice_events", "parking_notices"
  add_foreign_key "parking_notice_events", "users", column: "actor_id"
  add_foreign_key "parking_notices", "users"
  add_foreign_key "parking_notices", "users", column: "clearance_requested_by_id"
  add_foreign_key "parking_notices", "users", column: "cleared_by_id"
  add_foreign_key "parking_notices", "users", column: "issued_by_id"
  add_foreign_key "payment_events", "cash_payments"
  add_foreign_key "payment_events", "kofi_payments"
  add_foreign_key "payment_events", "paypal_payments"
  add_foreign_key "payment_events", "recharge_payments"
  add_foreign_key "payment_events", "users"
  add_foreign_key "paypal_payments", "users"
  add_foreign_key "queued_mails", "email_templates"
  add_foreign_key "queued_mails", "users", column: "recipient_id"
  add_foreign_key "queued_mails", "users", column: "reviewed_by_id"
  add_foreign_key "recharge_payments", "users"
  add_foreign_key "rfids", "users"
  add_foreign_key "role_privileges", "privileges"
  add_foreign_key "role_privileges", "roles"
  add_foreign_key "sheet_entries", "users"
  add_foreign_key "slack_users", "users"
  add_foreign_key "trainer_capabilities", "training_topics"
  add_foreign_key "trainer_capabilities", "users"
  add_foreign_key "training_requests", "training_topics"
  add_foreign_key "training_requests", "users"
  add_foreign_key "training_requests", "users", column: "responded_by_id"
  add_foreign_key "training_topic_links", "training_topics"
  add_foreign_key "training_topic_roles", "roles"
  add_foreign_key "training_topic_roles", "training_topics"
  add_foreign_key "training_topics", "training_topics", column: "parent_id"
  add_foreign_key "trainings", "training_topics"
  add_foreign_key "trainings", "users", column: "trainee_id"
  add_foreign_key "trainings", "users", column: "trainer_id"
  add_foreign_key "user_interests", "interests"
  add_foreign_key "user_interests", "users"
  add_foreign_key "user_links", "users"
  add_foreign_key "user_supplementary_plans", "membership_plans"
  add_foreign_key "user_supplementary_plans", "users"
  add_foreign_key "users", "membership_plans"
end
