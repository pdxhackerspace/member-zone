class AddPlanlessPaymentWindowSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :membership_settings, :planless_payment_window_days, :integer, null: false, default: 32
    add_column :membership_settings, :payment_currency_buffer_days, :integer, null: false, default: 2
  end
end
