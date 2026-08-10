class MemberMapsController < AuthenticatedController
  EARTH_RADIUS_MILES = 3958.8
  INITIAL_VIEW_HALF_SPAN_MILES = 2.5

  before_action -> { require_privilege!(:'member_map.view') }

  def show
    prepare_map_data
  end

  private

  def prepare_map_data
    apply_map_settings
    apply_member_marker_data
  end

  def apply_map_settings
    settings = DefaultSetting.instance
    @map_center = {
      latitude: settings.map_center_latitude.to_f,
      longitude: settings.map_center_longitude.to_f
    }
    @map_radius_miles = settings.map_radius_miles.to_f
    @map_initial_bounds = initial_bounds
  end

  def apply_member_marker_data
    @include_inactive_members = include_inactive_members?
    scope = map_member_scope
    @map_missing_coordinates_count = scope.where(mailing_latitude: nil).or(scope.where(mailing_longitude: nil)).count

    @map_markers = build_markers(scope)
    @map_mapped_count = @map_markers.size
  end

  def map_member_scope
    scope = User.non_service_accounts
                .non_legacy
                .where.not(membership_state: User::TERMINAL_STATES)
    scope = scope.where(active: true) unless @include_inactive_members
    scope
  end

  def include_inactive_members?
    params[:include_inactive] == '1'
  end

  def build_markers(scope)
    markers = users_with_coordinates(scope).map do |user|
      marker_for(user, distance_from_map_center(user))
    end
    markers.sort_by { |marker| marker.fetch(:distance_miles) }
  end

  def users_with_coordinates(scope)
    scope.where.not(mailing_latitude: nil)
         .where.not(mailing_longitude: nil)
         .ordered_by_display_name
  end

  def distance_from_map_center(user)
    distance_miles_between(
      @map_center[:latitude],
      @map_center[:longitude],
      user.mailing_latitude.to_f,
      user.mailing_longitude.to_f
    )
  end

  def marker_for(user, distance)
    {
      name: user.display_name,
      latitude: user.mailing_latitude.to_f,
      longitude: user.mailing_longitude.to_f,
      distance_miles: distance.round(2),
      profile_path: user_path(user)
    }
  end

  def initial_bounds
    latitude_delta = INITIAL_VIEW_HALF_SPAN_MILES / miles_per_degree_latitude
    {
      south: @map_center[:latitude] - latitude_delta,
      north: @map_center[:latitude] + latitude_delta,
      west: @map_center[:longitude],
      east: @map_center[:longitude]
    }
  end

  def miles_per_degree_latitude
    (Math::PI / 180) * EARTH_RADIUS_MILES
  end

  def distance_miles_between(from_latitude, from_longitude, to_latitude, to_longitude)
    from_lat = degrees_to_radians(from_latitude)
    to_lat = degrees_to_radians(to_latitude)
    delta_lat = degrees_to_radians(to_latitude - from_latitude)
    delta_lng = degrees_to_radians(to_longitude - from_longitude)

    a = (Math.sin(delta_lat / 2)**2) +
        (Math.cos(from_lat) * Math.cos(to_lat) * (Math.sin(delta_lng / 2)**2))
    2 * EARTH_RADIUS_MILES * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end

  def degrees_to_radians(degrees)
    degrees * Math::PI / 180
  end
end
