class DefaultSetting < ApplicationRecord
  DEFAULT_RFID_FACILITY_CODE = 127
  has_one_attached :login_branding_image
  has_one_attached :login_background_image

  validates :site_prefix, presence: true
  validates :app_prefix, presence: true
  validates :members_prefix, presence: true
  validates :active_members_group, presence: true
  validates :admins_group, presence: true
  validates :unbanned_members_group, presence: true
  validates :all_members_group, presence: true
  validates :trained_on_prefix, presence: true
  validates :can_train_prefix, presence: true
  validates :sync_inactive_members, inclusion: { in: [true, false] }
  validates :authentik_sync_inactive_as_active, inclusion: { in: [true, false] }
  validates :rfid_facility_code, presence: true,
                                 numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :map_center_latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }
  validates :map_center_longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :map_default_city, presence: true
  validates :map_default_state, presence: true
  validates :map_radius_miles, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :api_token_max_lifetime_days, numericality: { only_integer: true, greater_than: 0,
                                                          less_than_or_equal_to: 3650 }

  def rfid_facility_prefix
    "#{rfid_facility_code},"
  end

  # Singleton pattern - only one record should exist
  def self.instance
    first_or_create! do |setting|
      setting.site_prefix = 'ctrlh'
      setting.app_prefix = 'ctrlh:app'
      setting.members_prefix = 'ctrlh:org:members'
      setting.active_members_group = 'ctrlh:org:members:active'
      setting.admins_group = 'ctrlh:org:members:admins'
      setting.unbanned_members_group = 'ctrlh:org:members:unbanned'
      setting.all_members_group = 'ctrlh:org:members:all'
      setting.trained_on_prefix = 'ctrlh:org:members:trained-on'
      setting.can_train_prefix = 'ctrlh:org:members:can-train'
      setting.rfid_facility_code = DEFAULT_RFID_FACILITY_CODE
      setting.map_center_latitude = 45.581678
      setting.map_center_longitude = -122.682156
      setting.map_default_city = 'Portland'
      setting.map_default_state = 'Oregon'
      setting.map_radius_miles = 4.0
    end
  end

  before_save :update_derived_fields

  private

  def update_derived_fields
    self.app_prefix = "#{site_prefix}:app" if site_prefix_changed? || app_prefix.blank?
    self.members_prefix = "#{site_prefix}:org:members" if site_prefix_changed? || members_prefix.blank?
    self.active_members_group = "#{members_prefix}:active" if members_prefix_changed? || active_members_group.blank?
    self.admins_group = "#{members_prefix}:admins" if members_prefix_changed? || admins_group.blank?
    if members_prefix_changed? || unbanned_members_group.blank?
      self.unbanned_members_group = "#{members_prefix}:unbanned"
    end
    self.all_members_group = "#{members_prefix}:all" if members_prefix_changed? || all_members_group.blank?
    self.trained_on_prefix = "#{members_prefix}:trained-on" if members_prefix_changed? || trained_on_prefix.blank?
    return unless members_prefix_changed? || can_train_prefix.blank?

    self.can_train_prefix = "#{members_prefix}:can-train"
  end
end
