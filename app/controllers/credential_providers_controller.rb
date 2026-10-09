# Configures credential providers: which program to run, with what environment, and who may
# be issued credentials from it. The environment holds API keys, so this stays behind
# credentials.manage_providers; the form never shows the stored value back.
class CredentialProvidersController < AuthenticatedController
  RUNS_SHOWN = 20

  before_action -> { require_privilege!(:'credentials.manage_providers') }
  before_action :set_provider, only: %i[show edit update destroy toggle check_health refresh_schema revoke_all]

  def index
    @providers = CredentialProvider.ordered.includes(:required_training_topics)
    @live_counts = Credential.live.group(:credential_provider_id).count
  end

  def show
    @runs = @provider.credential_runs.recent.limit(RUNS_SHOWN)
    @live_count = @provider.credentials.live.count
    @credential_count = @provider.credentials.count
  end

  def new
    @provider = CredentialProvider.new
    load_form_options
  end

  def edit
    load_form_options
  end

  def create
    @provider = CredentialProvider.new(provider_params)

    if @provider.save
      refresh_after_save(@provider)
      redirect_to credential_provider_path(@provider), notice: "Credential provider '#{@provider.name}' created."
    else
      load_form_options
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @provider.update(provider_params)
      refresh_after_save(@provider)
      redirect_to credential_provider_path(@provider), notice: "Credential provider '#{@provider.name}' updated."
    else
      load_form_options
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @provider.name
    if @provider.destroy
      redirect_to credential_providers_path, notice: "Credential provider '#{name}' deleted."
    else
      redirect_to credential_provider_path(@provider),
                  alert: "Cannot delete '#{name}': it has issued credentials, which are kept. Disable it instead."
    end
  end

  def toggle
    @provider.update!(enabled: !@provider.enabled)
    Credentials::HealthCheckJob.perform_later(@provider.id) if @provider.enabled?
    redirect_to credential_providers_path,
                notice: "Credential provider '#{@provider.name}' #{@provider.enabled? ? 'enabled' : 'disabled'}."
  end

  def check_health
    status = Credentials::HealthCheck.call(@provider)
    redirect_to credential_provider_path(@provider), notice: "Health check finished: #{status.humanize.downcase}."
  end

  def refresh_schema
    outcome = Credentials::Describe.call(@provider)
    if outcome.ok?
      redirect_to credential_provider_path(@provider), notice: 'Schema refreshed.'
    else
      redirect_to credential_provider_path(@provider), alert: "Could not read the schema: #{outcome.error}"
    end
  end

  def revoke_all
    report = Credentials::RevokeAll.call(@provider.credentials, reason: 'revoked_by_admin', by: true_user)
    redirect_to credential_provider_path(@provider),
                notice: "Revoked #{report.revoked.size} credential(s); " \
                        "#{report.failed.size} failed and will be retried."
  end

  private

  def set_provider
    @provider = CredentialProvider.find(params[:id])
  end

  def load_form_options
    @script_options = script_options
    @training_topics = TrainingTopic.order(:name)
  end

  # The picker: every executable the catalog allows, plus the provider's current program if it
  # has since left the catalog, so editing such a provider shows what it is set to.
  def script_options
    options = Credentials::ScriptCatalog.scripts.map { |path| [File.basename(path), path] }
    current = @provider.script_path
    options << [current, current] if current.present? && options.none? { |_name, path| path == current }
    options
  end

  # Re-reads what the program issues when the program or its environment changed, and checks
  # its health in the background. A different program invalidates the cached schema first, so
  # a failed describe cannot leave the old program's fields behind.
  def refresh_after_save(provider)
    return unless provider.previously_new_record? || program_changed?(provider)

    provider.update_columns(schema: {}) if !provider.previously_new_record? && provider.saved_change_to_script_path?
    Credentials::Describe.call(provider)
    Credentials::HealthCheckJob.perform_later(provider.id)
  end

  def program_changed?(provider)
    provider.saved_change_to_script_path? || provider.saved_change_to_script_arguments? ||
      provider.saved_change_to_environment_variables?
  end

  # A blank environment on edit means "keep what is stored", because the stored value is
  # never rendered; clearing it is an explicit checkbox.
  def provider_params
    attrs = params.expect(credential_provider: [:name, :description, :script_path, :script_arguments,
                                                :environment_variables, :clear_environment_variables,
                                                :self_service, :enabled, :max_per_member,
                                                { required_training_topic_ids: [] }]).to_h
    clear = ActiveModel::Type::Boolean.new.cast(attrs.delete('clear_environment_variables'))
    attrs['environment_variables'] = nil if clear
    attrs.delete('environment_variables') if !clear && attrs['environment_variables'].blank?
    attrs
  end
end
