# Access control devices allowed to call the device webhooks. Each gets its own token, shown once
# when the device is created or the token is regenerated.
class WebhookDevicesController < AuthenticatedController
  before_action -> { require_privilege!(:'access.manage_controllers') }
  before_action :set_webhook_device, only: %i[show edit update destroy toggle regenerate_token]

  def index
    @webhook_devices = WebhookDevice.ordered
  end

  def show
    @parking_notice_count = @webhook_device.parking_notices.count
  end

  def new
    @webhook_device = WebhookDevice.new
  end

  def edit; end

  def create
    @webhook_device = WebhookDevice.new(webhook_device_params)

    if @webhook_device.save
      reveal_token(@webhook_device.token)
      redirect_to webhook_device_path(@webhook_device), notice: "Device '#{@webhook_device.name}' created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @webhook_device.update(webhook_device_params)
      redirect_to webhook_device_path(@webhook_device), notice: "Device '#{@webhook_device.name}' updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @webhook_device.name
    @webhook_device.destroy!
    redirect_to webhook_devices_path, notice: "Device '#{name}' deleted."
  end

  def toggle
    @webhook_device.update!(enabled: !@webhook_device.enabled)
    status = @webhook_device.enabled? ? 'enabled' : 'disabled'
    redirect_to webhook_devices_path, notice: "Device '#{@webhook_device.name}' #{status}."
  end

  def regenerate_token
    reveal_token(@webhook_device.regenerate_token!)
    redirect_to webhook_device_path(@webhook_device),
                notice: 'New token issued. The old token stopped working immediately.'
  end

  private

  def set_webhook_device
    @webhook_device = WebhookDevice.find(params[:id])
  end

  # The plaintext token survives exactly one redirect, so it is on screen once and never again.
  def reveal_token(token)
    flash[:webhook_device_token] = token
  end

  def webhook_device_params
    params.expect(webhook_device: %i[name description enabled])
  end
end
