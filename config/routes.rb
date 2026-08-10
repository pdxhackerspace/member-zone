Rails.application.routes.draw do
  get 'default_settings/index'
  get 'default_settings/edit'
  get 'default_settings/update'
  get "up" => "rails/health#show", as: :rails_health_check

  root "dashboard#index"

  get  "/invite/:token",         to: "invite#show",     as: :invite
  post "/invite/:token/accept",  to: "invite#accept",   as: :accept_invite
  get  "/invite/:token/accepted", to: "invite#accepted", as: :invite_accepted

  get "/login", to: "sessions#new"
  get "/apply", to: "pages#apply", as: :apply
  get "/help", to: "pages#help", as: :help
  get "/help/faq", to: "pages#help_faq", as: :help_faq
  get "/help/admin_faq", to: "pages#help_admin_faq", as: :help_admin_faq

  # Application verification gate (must complete before starting application)
  get  "/apply/new",                    to: "application_verifications#gate", as: :apply_new
  post "/apply/new",                    to: "application_verifications#send_verification"
  get  "/apply/new/verify/:token",      to: "application_verifications#verify_email", as: :apply_verify_email
  get  "/apply/new/status/:token",      to: "application_verifications#status", as: :apply_application_status
  get  "/apply/new/check_email",        to: "application_verifications#check_email", as: :apply_check_email
  get  "/apply/new/code_of_conduct.pdf", to: "application_verifications#code_of_conduct_pdf", as: :apply_code_of_conduct_pdf

  # New membership application wizard (requires verified email)
  get  "/apply/new/start",             to: "membership_applications#start", as: :apply_start
  post "/apply/new/start",             to: "membership_applications#save_page"
  get  "/apply/new/page/:page_number", to: "membership_applications#page", as: :apply_page
  post "/apply/new/submit",            to: "membership_applications#submit_application", as: :apply_submit
  get  "/apply/new/confirmation",      to: "membership_applications#confirmation", as: :apply_confirmation
  post "/local_login", to: "sessions#create_local"
  post "/rfid_login", to: "sessions#create_rfid"
  get "/rfid_login/wait", to: "sessions#rfid_wait", as: :rfid_wait
  get "/rfid_login/verify", to: "sessions#rfid_verify", as: :rfid_verify
  get "/rfid_login/check_webhook", to: "sessions#rfid_check_webhook", as: :rfid_check_webhook
  post "/rfid_login/submit_pin", to: "sessions#rfid_submit_pin", as: :rfid_submit_pin
  delete "/logout", to: "sessions#destroy"
  match "/auth/:provider/callback", to: "sessions#create", via: %i[get post]
  get "/auth/failure", to: "sessions#failure"

  # Link workspace Slack account to member profile (OIDC; not Member Zone login — Authentik only for login)
  get "/slack/link", to: "slack_account_links#new", as: :slack_link_start
  get "/slack/link/callback", to: "slack_account_links#callback", as: :slack_link_callback

  # Login links
  post "/login_link/request", to: "login_links#request_link", as: :request_login_link
  get  "/login_link/:token", to: "login_links#authenticate", as: :login_link_authenticate
  get  "/profile/login_link", to: "login_links#show", as: :login_link
  post "/profile/login_link/regenerate", to: "login_links#regenerate", as: :login_link_regenerate

  post "/webhooks/:slug", to: "webhooks#receive", as: :webhook_receive

  # Impersonation
  post "/impersonate/:user_id", to: "impersonations#create", as: :impersonate_user, constraints: { user_id: /[^\/]+/ }
  delete "/impersonate", to: "impersonations#destroy", as: :stop_impersonation

  resources :messages, only: %i[index show create destroy] do
    member do
      patch :mark_unread
      post :restore
    end
  end
  resources :training_requests, only: %i[new create edit update] do
    member do
      post :mark_trained
      post :dismiss
    end
  end

  # Member-facing catalog of training topics
  get '/training',      to: 'training_catalog#index', as: :training_catalog
  get '/training/record', to: 'trainings#record', as: :record_training
  post '/training/record', to: 'trainings#create_bulk'
  get '/training/:id',  to: 'training_catalog#show',  as: :training_catalog_topic, constraints: { id: /\d+/ }
  resources :member_parking_permits, only: %i[new create show edit update] do
    member do
      patch :close
      post :request_clearance
      post :add_note
      post :print_notice
    end
  end

  resources :users, only: [:index, :show, :new, :create, :edit, :update, :destroy], constraints: { id: /[^\/]+/ } do
    member do
      post :activate
      post :deactivate
      post :enable_emergency_active_override
      post :clear_emergency_active_override
      post :ban
      post :unban
      post :mark_deceased
      post :record_cancellation
      post :mark_sponsored
      post :unmark_sponsored
      post :sync_to_authentik
      post :sync_from_authentik
      post :unlink_slack
      post :unlink_authentik
      post :unlink_sheet
      post :mark_help_seen
      post :pause_key_access
      post :resume_key_access
    end
    collection do
      post :sync
      post :sync_all_to_authentik
      post :toggle_authentik_sync_inactive_as_active
    end
    resources :user_links, only: [:create, :update, :destroy]
  end

  resources :rfids, only: [:new, :create, :destroy] do
    member do
      get :sync_prompt
    end
  end
  resources :invitations, only: [:index, :new, :create] do
    post :cancel, on: :member
  end

  # Member profile setup wizard (non-admin)
  get  "/profile/setup",            to: "profile_setup#basic_info",       as: :profile_setup
  post "/profile/setup",            to: "profile_setup#save_basic_info",  as: :profile_setup_save_basic
  get  "/profile/setup/visibility", to: "profile_setup#visibility",       as: :profile_setup_visibility
  post "/profile/setup/visibility", to: "profile_setup#save_visibility",  as: :profile_setup_save_visibility
  get  "/profile/setup/optional",   to: "profile_setup#optional_info",    as: :profile_setup_optional
  post "/profile/setup/optional",   to: "profile_setup#save_optional_info", as: :profile_setup_save_optional
  get    "/profile/setup/links",                    to: "profile_setup#links",           as: :profile_setup_links
  post   "/profile/setup/links",                    to: "profile_setup#add_link",        as: :profile_setup_add_link
  delete "/profile/setup/links/:link_id",           to: "profile_setup#remove_link",     as: :profile_setup_remove_link
  get    "/profile/setup/interests",                to: "profile_setup#interests",          as: :profile_setup_interests
  post   "/profile/setup/interests/suggest",        to: "profile_setup#suggest_interest",   as: :profile_setup_suggest_interest
  post   "/profile/setup/interests/:id/add",        to: "profile_setup#add_interest",       as: :profile_setup_add_interest
  delete "/profile/setup/interests/:id/remove",     to: "profile_setup#remove_interest",    as: :profile_setup_remove_interest

  # Member onboarding wizard
  get  "/onboard",              to: "onboarding#member_info",      as: :onboard
  post "/onboard",              to: "onboarding#create_member",    as: :onboard_create
  get  "/onboard/:id/payment",  to: "onboarding#payment",         as: :onboard_payment, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/payment",  to: "onboarding#save_payment",    as: :onboard_save_payment, constraints: { id: /[^\/]+/ }
  get  "/onboard/:id/access",   to: "onboarding#access",          as: :onboard_access, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/rfid",     to: "onboarding#save_rfid",       as: :onboard_save_rfid, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/training", to: "onboarding#save_training",   as: :onboard_save_training, constraints: { id: /[^\/]+/ }
  get  "/onboard/:id/mail",     to: "onboarding#mail",            as: :onboard_mail, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/mail/:mail_id/approve", to: "onboarding#approve_mail", as: :onboard_approve_mail, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/mail/:mail_id/reject",  to: "onboarding#reject_mail",  as: :onboard_reject_mail, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/mail/approve_all",      to: "onboarding#approve_all_mail", as: :onboard_approve_all_mail, constraints: { id: /[^\/]+/ }
  post "/onboard/:id/mail/reject_all",       to: "onboarding#reject_all_mail",  as: :onboard_reject_all_mail, constraints: { id: /[^\/]+/ }

  resources :slack_users, only: [:index, :show] do
    collection do
      post :sync
      post :import_members
      post :import_analytics
    end
    member do
      post :link_user
      post :unlink_user
      post :toggle_dont_link
      post :create_member
    end
  end

  resources :authentik_users, only: [:index, :show] do
    collection do
      post :sync
    end
    member do
      post :link_user
      post :unlink_user
      post :accept_changes
      post :push_to_authentik
    end
  end

  # Authentik webhook configuration
  get "/settings/authentik_webhooks", to: "authentik_webhooks#index", as: :authentik_webhooks
  post "/settings/authentik_webhooks/setup", to: "authentik_webhooks#setup", as: :setup_authentik_webhooks
  delete "/settings/authentik_webhooks/teardown", to: "authentik_webhooks#teardown", as: :teardown_authentik_webhooks

  resources :sheet_entries, only: [:index, :show] do
    collection do
      post :sync
      post :sync_to_users
      get :test
    end
    member do
      post :sync_to_user
      post :unlink_user
    end
  end

  resources :paypal_payments, only: [:index, :show] do
    collection do
      post :sync
      get :test
      get :export
      post :import
      get :unmatched_subjects
    end
    member do
      post :link_user
      post :unlink
      post :toggle_dont_link
      post :create_member
    end
  end

  resources :recharge_payments, only: [:index, :show] do
    collection do
      post :sync
      get :test
      get :export
      post :import
    end
    member do
      post :link_user
      post :unlink
      post :toggle_dont_link
      post :create_member
    end
  end

  resources :cash_payments, only: [:index, :show, :new, :create, :edit, :update, :destroy]

  resources :payment_events, only: [:index]

  resources :kofi_payments, only: [:index, :show] do
    collection do
      get :export
      post :import
      post :import_csv
    end
    member do
      post :link_user
    end
  end

  resources :journals, only: [:index]

  # Training members
  get '/train', to: redirect('/training/record'), as: :train_member
  post "/train/:user_id/add/:topic_id", to: "trainings#add_training", as: :add_training
  delete "/train/:user_id/remove/:topic_id", to: "trainings#remove_training", as: :remove_training
  post "/train/:user_id/trainer/:topic_id", to: "trainings#add_trainer_capability", as: :add_trainer_capability
  delete "/train/:user_id/trainer/:topic_id", to: "trainings#remove_trainer_capability", as: :remove_trainer_capability

  resources :access_logs, only: [:index] do
    collection do
      post :import
      post :upload
    end
    member do
      post :link_user
      post :create_member
    end
  end

  get "/search", to: "search#index", as: :search
  get "/rag.json", to: "rag#index"
  get "/rag", to: "rag#index", defaults: { format: :json }

  get "/settings", to: "settings#index", as: :settings
  resources :roles, except: [:show] do
    collection do
      get :export
      get :import
      post :import, action: :run_import, as: :run_import
    end
  end
  resources :training_topics, only: [:index, :create, :edit, :update, :destroy] do
    member do
      delete :revoke_training
      delete :revoke_trainer_capability
    end
    resources :links, controller: 'training_topic_links', only: [:create, :update, :destroy]
    resources :topic_roles, controller: 'training_topic_roles', only: [:create, :destroy]
  end
  # No :new — plans are created from the index, and an unimplemented route was the one
  # action neither privilege filter covered.
  resources :membership_plans, except: [:new] do
    collection do
      get :manual_payments
      post :mark_dues_received
    end
  end
  resources :rfid_readers, except: [:show] do
    collection do
      patch :update_facility_code
    end

    member do
      post :regenerate_key
    end
  end
  resources :interests, only: [:index, :new, :create, :edit, :update, :destroy], path: "settings/interests" do
    member do
      get  :members
      get  :merge_form
      post :merge
      post :approve
    end
    collection do
      post :seed
    end
  end

  resource :default_settings, only: [:show, :edit, :update], path: "settings/defaults" do
    get :map, on: :member
    get :edit_map, on: :member
    patch :update_map, on: :member
    get :branding, on: :member
    get :edit_branding, on: :member
    patch :update_branding, on: :member
    post :provision_core_groups, on: :member
  end
  resource :membership_settings, only: [:show, :edit, :update], path: "settings/membership"
  resources :reminder_settings, only: [:index, :show, :update], path: "settings/reminders", param: :key
  resources :ai_providers, except: [:show], path: "settings/ai-providers"
  resources :ai_ollama_profiles, only: [:index, :edit, :update], path: "settings/ai-services" do
    collection do
      post :check_health_now
    end
  end
  resources :incoming_webhooks, only: [:index, :edit, :update], path: "settings/incoming_webhooks" do
    collection do
      get :random_slug
      post :seed
    end
  end
  
  resources :email_templates, only: [:index, :show, :edit, :update] do
    member do
      match :preview, via: %i[get post]
      post :toggle
      post :test_send
      post :rewrite_with_ai
      post :mark_reviewed
      post :mark_needs_review
    end
    collection do
      post :seed
    end
  end

  get "/settings/mail_log", to: "mail_log#index", as: :mail_log
  get "/settings/mail_log/:id", to: "mail_log#show", as: :mail_log_entry

  resources :queued_mails, only: [:index, :show, :edit, :update] do
    member do
      post :approve
      post :reject
      post :regenerate
      post :rewrite_with_ai
      post :retry_delivery, as: :retry
    end
    collection do
      post :approve_all
      post :reject_all
    end
  end

  resources :text_fragments, only: [:index, :show, :edit, :update] do
    member do
      post :sync_from_url
    end
    collection do
      post :seed
      post :sync_all_from_urls
    end
  end

  resources :documents do
    member do
      get :download
    end
  end

  resources :payment_processors, only: [:index, :show, :edit, :update] do
    member do
      post :toggle
      post :refresh_stats
    end
    collection do
      post :refresh_all
      post :seed
    end
  end

  resources :member_sources, only: [:index, :show, :edit, :update] do
    member do
      post :toggle
      post :refresh_stats
    end
    collection do
      post :refresh_all
      post :seed
    end
  end

  resources :access_controllers do
    member do
      post :toggle
      post :sync
      post :run_verb
    end
    collection do
      post :sync_all
      post :toggle_sync_inactive
      get :recent_logs
    end
  end

  resources :access_controller_types, only: [:index, :new, :create, :edit, :update, :destroy] do
    member do
      post :toggle
      post :probe
    end
    collection do
      get :export_users
    end
  end
  
  resources :incident_reports do
    member do
      post :add_link
      delete 'links/:link_id', action: :remove_link, as: :remove_link
      delete 'photos/:photo_id', action: :remove_photo, as: :remove_photo
      get :download_pdf
      get 'photos/:photo_id/download', action: :download_photo, as: :download_photo
    end
  end

  resources :parking_notices do
    member do
      post :clear
      post :add_note
      get :download_pdf
      post :print_notice
      delete 'photos/:photo_id', action: :remove_photo, as: :remove_photo
      get 'photos/:photo_id/download', action: :download_photo, as: :download_photo
    end
  end

  resources :rooms, path: 'settings/rooms'

  resources :application_form_pages, path: 'settings/application_form' do
    collection do
      patch :update_application_flow
    end
    resources :application_form_questions, only: %i[new create edit update destroy]
  end

  resources :membership_applications, only: %i[index show] do
    collection do
      post :import
      post 'initiated/:id/extend/:duration', to: 'membership_applications#extend_initiated_application',
                                             as: :extend_initiated
      post 'initiated/:id/resend', to: 'membership_applications#resend_initiated_application',
                                   as: :resend_initiated
    end
    member do
      post :approve
      post :reject
      post :delay_for_review
      post :mark_needs_review
      post :link_user
      post :unlink_user
      post :vote_ai_feedback
      post :save_tour_feedback
      post :vote_acceptance
    end
  end

  resources :printers, path: 'settings/printers' do
    collection do
      post :check_health_now
    end

    member do
      post :test_print
    end
  end

  get "/reports", to: "reports#index", as: :reports
  post "/reports/update_user", to: "reports#update_user", as: :reports_update_user
  get "/reports/charts", to: "reports#charts", as: :reports_charts
  # Bookmarks and links from before reports became their own pages.
  get "/reports/:key/all", to: redirect { |params, _req| "/reports/#{params[:key]}" }
  get "/reports/:key", to: "reports#show", as: :report
  get "/member-map", to: "member_maps#show", as: :member_map
  get "/api/users/search", to: "api/users#search", as: :api_users_search
  
  require 'sidekiq/web'
  mount Sidekiq::Web => '/goh7zeeNiezoozaingothu4'

  # Staging only: view emails captured instead of being sent (letter_opener_web).
  # Restrict /letter_opener at the reverse proxy or add auth if exposed.
  mount LetterOpenerWeb::Engine, at: '/letter_opener' if Rails.env.staging?
  
  resources :applications do
    resources :application_groups, except: [:index] do
      member do
        post :add_user
        delete :remove_user
        post :sync_to_authentik
      end
    end
  end
end
