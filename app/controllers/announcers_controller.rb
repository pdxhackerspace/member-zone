# Configures arrival announcers: which program to run, with what secrets, how often it may
# announce the same member, which access log locations count as outside doors, and whether
# members without active access are announced. Environment
# variables hold secrets, so this stays behind announcers.manage.
class AnnouncersController < AuthenticatedController
  RUNS_SHOWN = 25

  before_action -> { require_privilege!(:'announcers.manage') }
  before_action :set_announcer, only: %i[show edit update destroy toggle test]

  def index
    @announcers = Announcer.ordered
    @subscriber_counts = AnnouncerSubscription.joins(:user).where(users: { announce_arrivals: true })
                                              .group(:announcer_id).count
    @arrival_locations = DefaultSetting.instance.arrival_locations
    @known_locations = (AccessLog.known_locations + @arrival_locations).uniq.sort_by(&:downcase)
  end

  def show
    @runs = @announcer.announcer_runs.recent.includes(:user, :access_log).limit(RUNS_SHOWN)
    @subscriber_count = @announcer.subscribers.where(announce_arrivals: true).count
  end

  def new
    @announcer = Announcer.new
    load_form_options
  end

  def edit
    load_form_options
  end

  def create
    @announcer = Announcer.new(announcer_params)

    if @announcer.save
      redirect_to announcer_path(@announcer), notice: "Announcer '#{@announcer.name}' created."
    else
      load_form_options
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @announcer.update(announcer_params)
      redirect_to announcer_path(@announcer), notice: "Announcer '#{@announcer.name}' updated."
    else
      load_form_options
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @announcer.name
    @announcer.destroy!
    redirect_to announcers_path, notice: "Announcer '#{name}' deleted."
  end

  def toggle
    @announcer.update!(enabled: !@announcer.enabled)
    redirect_back_or_to announcers_path,
                        notice: "Announcer '#{@announcer.name}' #{@announcer.enabled? ? 'enabled' : 'disabled'}."
  end

  # Announces the signed-in admin (never an impersonated member), marked as a test in the payload.
  def test
    run = @announcer.announcer_runs.create!(user: true_user, test_run: true)
    Announcers::RunJob.perform_later(run.id)
    redirect_to announcer_path(@announcer), notice: 'Test announcement queued. Its result will appear below.'
  end

  def update_arrival_locations
    locations = Array(params[:arrival_locations]).grep(String) + [params[:new_location].to_s]
    DefaultSetting.instance.update!(arrival_locations: locations)
    redirect_to announcers_path, notice: 'Outside doors updated.'
  end

  def update_inactive_members
    DefaultSetting.instance.update!(announce_inactive_members: params[:announce_inactive_members] == '1')
    redirect_to announcers_path, notice: 'Inactive member setting updated.'
  end

  private

  def set_announcer
    @announcer = Announcer.find(params[:id])
  end

  def load_form_options
    @script_options = script_options
  end

  def script_options
    options = Announcers::ScriptCatalog.scripts.map { |path| [File.basename(path), path] }
    current = @announcer.script_path
    options << [current, current] if current.present? && options.none? { |_name, path| path == current }
    options
  end

  def announcer_params
    params.expect(announcer: %i[name description script_path script_arguments environment_variables
                                repeat_after_minutes display_order enabled])
  end
end
