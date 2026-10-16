# SPDX-FileCopyrightText: 2026 John Romkey
#
# SPDX-License-Identifier: CC0-1.0

class AuthentikUsersController < AuthenticatedController
  before_action -> { require_privilege!(:'sources.authentik.view') }, only: %i[index show]
  before_action -> { require_privilege!(:'sources.authentik.sync') }, only: :sync
  before_action -> { require_privilege!(:'members.unlink_sources') }, only: %i[link_user unlink_user]
  # Both of these write to the identity provider rather than reading from it, and a bad
  # push is not undone by pulling again.
  before_action :require_admin!, only: %i[accept_changes push_to_authentik]

  before_action :set_authentik_user, only: %i[show link_user unlink_user accept_changes push_to_authentik]

  def index
    @authentik_users = AuthentikUser.includes(:user).order(updated_at: :desc)

    # Counts for all records
    @total_count = AuthentikUser.count
    @linked_count = AuthentikUser.linked.count
    @unlinked_count = AuthentikUser.unlinked.count
    @active_count = AuthentikUser.active.count
    @inactive_count = AuthentikUser.inactive.count
    # Resolved once: the count and the filter below are the same set, and working it out
    # involves decrypting whichever pairs SQL could not settle.
    discrepancy_ids = AuthentikUser.discrepancy_ids
    @discrepancy_count = discrepancy_ids.size

    @link_filter, @status_filter = resolved_filters
    @authentik_users = filtered_by_link(@authentik_users, discrepancy_ids)
    @authentik_users = @authentik_users.public_send(@status_filter) if @status_filter

    @filter_active = @link_filter.present? || @status_filter.present?
    @shown_count = @authentik_users.count
  end

  def show
    # Tie-broken on id rather than email, which is encrypted and so orders arbitrarily.
    @all_users = User.order(:full_name, :id) if @authentik_user.user.nil?

    # Navigation
    ids = AuthentikUser.order(updated_at: :desc).pluck(:id)
    current_index = ids.index(@authentik_user.id)
    @previous_authentik_user = current_index&.positive? ? AuthentikUser.find(ids[current_index - 1]) : nil
    @next_authentik_user = if current_index && current_index < ids.length - 1
                             AuthentikUser.find(ids[current_index + 1])
                           end
  end

  def sync
    unless MemberSource.enabled?('authentik')
      redirect_to authentik_users_path, alert: 'Authentik source is disabled.'
      return
    end

    Authentik::GroupSyncJob.perform_later
    redirect_to authentik_users_path, notice: 'Authentik sync started.'
  end

  def link_user
    user = User.find(params[:user_id])
    @authentik_user.update!(user: user)

    # Also update the user's authentik_id if not set
    user.update!(authentik_id: @authentik_user.authentik_id) if user.authentik_id.blank?

    # Update MemberSource statistics
    MemberSource.for('authentik').refresh_statistics!

    redirect_to authentik_user_path(@authentik_user), notice: "Linked to #{user.display_name}."
  end

  def unlink_user
    unless @authentik_user.user
      redirect_to @authentik_user, alert: 'Authentik user is not linked to a member.'
      return
    end

    user = @authentik_user.user

    AuthentikUser.transaction do
      @authentik_user.update!(user_id: nil)
      if user.authentik_id == @authentik_user.authentik_id
        user.update_columns(authentik_id: nil, authentik_dirty: false, updated_at: Time.current)
      end
    end

    MemberSource.for('authentik').refresh_statistics!
    redirect_to @authentik_user, notice: "Disassociated from #{user.display_name}."
  end

  def accept_changes
    unless @authentik_user.user
      redirect_to @authentik_user, alert: 'No linked member to update.'
      return
    end

    updates = {}
    @authentik_user.discrepancies.each do |discrepancy|
      field = discrepancy[:field]
      updates[field] = @authentik_user.send(field)
    end

    if updates.any?
      @authentik_user.user.update!(updates)

      Journal.create!(
        user: @authentik_user.user,
        actor_user: current_user,
        action: 'authentik_sync',
        changes_json: {
          'authentik_sync' => {
            'fields' => updates.keys,
            'updates' => updates,
            'authentik_user_id' => @authentik_user.id
          }
        },
        changed_at: Time.current
      )

      redirect_to @authentik_user, notice: "Updated user with Authentik values: #{updates.keys.join(', ')}."
    else
      redirect_to @authentik_user, notice: 'No discrepancies to resolve.'
    end
  end

  def push_to_authentik
    unless @authentik_user.user
      redirect_to @authentik_user, alert: 'No linked member to push.'
      return
    end

    # TODO: Implement Authentik API update
    # This would use the Authentik::Client to update the user in Authentik
    # Authentik::Client.new.update_user(@authentik_user.authentik_id, {
    #   email: @authentik_user.user.email,
    #   name: @authentik_user.user.full_name,
    #   username: @authentik_user.user.username
    # })

    redirect_to @authentik_user,
                alert: 'Push to Authentik is not yet implemented. This requires Authentik API write access.'
  end

  private

  # Whether an account is active used to share the one `filter` param with whether it is
  # linked, so you could not ask for an unlinked account that is also inactive. The two are
  # separate axes now; a link written against the old single param still lands sensibly.
  def resolved_filters
    link = params[:filter].presence
    status = params[:status].presence
    if %w[active inactive].include?(link)
      status ||= link
      link = nil
    end
    [link, (status if %w[active inactive].include?(status))]
  end

  def filtered_by_link(scope, discrepancy_ids)
    case @link_filter
    when 'linked' then scope.linked
    when 'unlinked' then scope.unlinked
    when 'discrepancies' then scope.where(id: discrepancy_ids)
    else scope
    end
  end

  def set_authentik_user
    @authentik_user = AuthentikUser.find(params[:id])
  end
end
