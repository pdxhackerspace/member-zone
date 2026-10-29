class AccessControllerTypesController < AuthenticatedController
  before_action -> { require_privilege!(:'access.manage_controller_types') }, except: :export_users
  before_action -> { require_privilege!(:'access.export_users') }, only: :export_users
  before_action :set_access_controller_type, only: %i[edit update destroy toggle probe]

  def index
    @access_controller_types = AccessControllerType.ordered.includes(:required_training_topics)
  end

  def new
    @access_controller_type = AccessControllerType.new
    load_form_options
  end

  def edit
    load_form_options
  end

  def create
    @access_controller_type = AccessControllerType.new(access_controller_type_params)

    if @access_controller_type.save
      redirect_to access_controller_types_path,
                  notice: "Access controller type '#{@access_controller_type.name}' created."
    else
      load_form_options
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @access_controller_type.update(access_controller_type_params)
      redirect_to access_controller_types_path,
                  notice: "Access controller type '#{@access_controller_type.name}' updated."
    else
      load_form_options
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @access_controller_type.name
    if @access_controller_type.destroy
      redirect_to access_controller_types_path, notice: "Access controller type '#{name}' deleted."
    else
      redirect_to access_controller_types_path, alert: @access_controller_type.errors.full_messages.to_sentence
    end
  end

  def toggle
    @access_controller_type.update!(enabled: !@access_controller_type.enabled)
    status = @access_controller_type.enabled? ? 'enabled' : 'disabled'
    redirect_to access_controller_types_path,
                notice: "Access controller type '#{@access_controller_type.name}' #{status}."
  end

  def export_users
    send_data(
      AccessControllerPayloadBuilder.call,
      filename: 'users.json',
      type: 'application/json',
      disposition: 'attachment'
    )
  end

  def probe
    AccessControllerProbeJob.perform_later(@access_controller_type.id)
    redirect_to access_controller_types_path, notice: "Probe started for '#{@access_controller_type.name}'."
  end

  private

  def set_access_controller_type
    @access_controller_type = AccessControllerType.find(params[:id])
  end

  def access_controller_type_params
    params.expect(access_controller_type: [:name, :script_path, :enabled, { required_training_topic_ids: [] }])
  end

  def load_form_options
    @script_options = script_options
    @training_topics = TrainingTopic.order(:name)
  end

  def script_options
    options = AccessControllers::ScriptCatalog.scripts.map { |path| [File.basename(path), path] }
    current = @access_controller_type.script_path
    options << [current, current] if current.present? && options.none? { |_name, path| path == current }
    options
  end
end
