class TextFragmentsController < AuthenticatedController
  before_action -> { require_privilege!(:'text_fragments.manage') },
                only: %i[index show edit update sync_from_url]
  # Bulk operations stay with administrators: seed resets every fragment to its built-in
  # default, and sync_all_from_urls fetches and overwrites all of them from remote URLs.
  # Neither has a catalog key of its own to grant.
  before_action :require_admin!, only: %i[seed sync_all_from_urls]
  before_action :set_text_fragment, only: %i[show edit update sync_from_url]

  def index
    @text_fragments = TextFragment.ordered
    @source_url_sync_count = TextFragment.with_source_url.count
  end

  def show; end

  def edit; end

  def update
    if @text_fragment.update(text_fragment_params)
      redirect_to text_fragments_path, notice: 'Text fragment updated successfully.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  # Seed the default text fragments
  def seed
    seed_fragments
    redirect_to text_fragments_path, notice: 'Text fragments seeded successfully.'
  end

  def sync_from_url
    TextFragments::SyncFromUrl.call(@text_fragment)
    redirect_back_or_fragment notice: 'Content synced from URL.'
  rescue TextFragments::SyncFromUrl::Error => e
    redirect_back_or_fragment alert: e.message
  end

  def sync_all_from_urls
    fragments = TextFragment.with_source_url.order(:id)
    if fragments.empty?
      redirect_to text_fragments_path, notice: 'No text fragments have a source URL configured.'
      return
    end

    errors = []
    fragments.each do |fragment|
      TextFragments::SyncFromUrl.call(fragment)
    rescue TextFragments::SyncFromUrl::Error => e
      errors << "#{fragment.title}: #{e.message}"
    end

    if errors.empty?
      redirect_to text_fragments_path, notice: "Synced #{fragments.size} text fragment(s) from their URLs."
    else
      redirect_to text_fragments_path,
                  alert: "Some syncs failed — #{errors.join(' · ')}"
    end
  end

  private

  def redirect_back_or_fragment(**flash_hash)
    redirect_back_or_to(edit_text_fragment_path(@text_fragment), **flash_hash)
  end

  def set_text_fragment
    @text_fragment = TextFragment.find(params[:id])
  end

  def text_fragment_params
    params.expect(text_fragment: %i[title content source_url])
  end

  def seed_fragments
    TextFragment.ensure_exists!(
      key: 'member_help',
      title: 'Member Help',
      content: <<~HTML
        <h4>Welcome to Your Member Profile!</h4>
        <p>This is your member dashboard where you can view and manage your membership information.</p>

        <h5>What you'll find here:</h5>
        <ul>
          <li><strong>Profile Information</strong> - Your contact details and account settings</li>
          <li><strong>Membership Status</strong> - Your current membership status and payment history</li>
          <li><strong>Training</strong> - View your training certifications and available courses</li>
          <li><strong>Access</strong> - Your RFID key fobs and access history</li>
        </ul>

        <h5>Need help?</h5>
        <p>If you have questions about your membership or need assistance, please contact us.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'motd',
      title: 'Message of the Day',
      content: '' # Empty by default - will only display when content is added
    )

    TextFragment.ensure_exists!(
      key: 'login_screen_message',
      title: 'Login Screen Message',
      content: ''
    )

    TextFragment.ensure_exists!(
      key: 'navbar_help',
      title: 'Navbar Help',
      content: <<~HTML
        <h4>Member Zone Help</h4>
        <p>Welcome to Member Zone. This page provides an overview of the system and how to use it.</p>

        <h5>Members</h5>
        <p>View and manage all members, their profiles, membership status, and payment history. Use the search bar to find members quickly.</p>

        <h5>Payments</h5>
        <p>PayPal, Recharge, and Ko-Fi payments are synced automatically. You can also manually import payments and link them to members.</p>

        <h5>Access</h5>
        <p>Manage access controllers, RFID readers, and view access logs. Access controllers sync RFID keys to door controllers via SSH scripts.</p>

        <h5>Training</h5>
        <p>Track which members are trained on equipment and who can train others. Training topics are configured in Settings.</p>

        <h5>Settings</h5>
        <p>Configure membership plans, email templates, text fragments, applications, webhooks, and integrations with Authentik, Slack, and Google Sheets.</p>

        <hr>
        <p class="text-muted">This help text can be edited in <strong>Settings &gt; Text Fragments &gt; Navbar Help</strong>.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'help_general',
      title: 'Help (General)',
      content: <<~HTML
        <h4>Member Zone Help</h4>
        <p>Welcome to Member Zone. This page provides an overview of the system and how to use it.</p>

        <h5>Members</h5>
        <p>View and manage all members, their profiles, membership status, and payment history. Use the search bar to find members quickly.</p>

        <h5>Payments</h5>
        <p>PayPal, Recharge, and Ko-Fi payments are synced automatically. You can also manually import payments and link them to members.</p>

        <h5>Access</h5>
        <p>Manage access controllers, RFID readers, and view access logs. Access controllers sync RFID keys to door controllers via SSH scripts.</p>

        <h5>Training</h5>
        <p>Track which members are trained on equipment and who can train others. Training topics are configured in Settings.</p>

        <h5>Settings</h5>
        <p>Configure membership plans, email templates, text fragments, applications, webhooks, and integrations with Authentik, Slack, and Google Sheets.</p>

        <hr>
        <p class="text-muted">Admins can edit this page under <strong>Settings &gt; Text Fragments &gt; Help (General)</strong>, or set a <strong>Source URL</strong> to pull content from the web (GitHub file links are converted to raw file content automatically).</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'help_faq',
      title: 'Help (FAQ)',
      content: <<~HTML
        <h4>Frequently asked questions</h4>
        <p>Add questions and answers here, or point the <strong>Source URL</strong> at a document (for example a Markdown or HTML file on GitHub) and use <strong>Sync from URL</strong> to import it.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'help_admin_faq',
      title: 'Help (Admin FAQ)',
      content: <<~HTML
        <h4>Admin FAQ</h4>
        <p>This page is only linked in the Help menu for administrators. Use it for internal how-tos, runbooks, or policy reminders.</p>
        <p class="text-muted">Edit the <code>help_admin_faq</code> text fragment or sync from a <strong>Source URL</strong>.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'apply_for_membership',
      title: 'Apply For Membership',
      content: <<~HTML
        <h1 class="h3 mb-4">Hello!</h1>

        <p>
          We hope you enjoyed your recent visit to PDX Hackerspace! It was a pleasure having you,#{' '}
          and we're excited about the possibility of you joining our community.
        </p>

        <p>
          As we mentioned during your visit, becoming a member of PDX Hackerspace gives you access#{' '}
          to our tools, equipment, and resources, as well as the opportunity to learn from and#{' '}
          collaborate with other talented individuals in the community. We believe in building a#{' '}
          strong and trusting community, which is why we require an in-person visit and tour for#{' '}
          potential members before sharing our membership application link.
        </p>

        <p>
          To apply for membership, please complete the PDX Hackerspace Membership Application using the following link:
        </p>

        <div class="text-center my-4">
          <a href="https://forms.gle/mHEQMGVzTNzCbyq26" class="btn btn-primary btn-lg" target="_blank" rel="noopener">
            https://forms.gle/mHEQMGVzTNzCbyq26
          </a>
        </div>

        <div class="alert alert-warning">
          <i class="bi bi-exclamation-triangle me-2"></i>
          <strong>Please note:</strong> This application link is exclusively for those who have visited us in person,#{' '}
          so please do not share it with others. We appreciate your understanding and cooperation in helping us#{' '}
          maintain the integrity of our community.
        </div>

        <p>
          Once you've submitted your application, our team will review it and get back to you shortly.
        </p>

        <p>
          If you have any questions or need further assistance, please don't hesitate to reach out to us at#{' '}
          <a href="mailto:info@pdxhs.org">info@pdxhs.org</a> or call us at <strong>503-560-3551</strong>.
        </p>

        <p class="mb-0">
          Thank you again for your interest in PDX Hackerspace, and we look forward to the possibility of having#{' '}
          you as a member of our vibrant community.
        </p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'application_form_intro',
      title: 'Application Form Introduction',
      content: <<~HTML
        <h2 class="h4 mb-3">PDX Hackerspace Membership Application</h2>
        <p>
          PDX Hackerspace is a 501(c)(3) non-profit organization promoting and encouraging
          technical, scientific, and artistic skills through individual projects, social
          collaboration, and education. We are located at 7608 N Interstate Avenue in Portland,
          Oregon, and serve as a local community hub as well as a thriving online community
          with roots extending around the world.
        </p>
        <p>Please provide your email address to begin or resume your application.</p>
      HTML
    )

    TextFragments::ApplicationFlowSeeds.seed!

    TextFragment.ensure_exists!(
      key: 'invite_already_accepted',
      title: 'Invitation: Already Accepted',
      content: <<~HTML
        <p>This invitation has already been used to create an account.</p>
        <p>If you need help accessing your account, please contact an administrator.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'invite_expired',
      title: 'Invitation: Expired',
      content: <<~HTML
        <p>This invitation has expired and can no longer be used.</p>
        <p>Please contact an administrator to request a new invitation.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'invite_invalid',
      title: 'Invitation: Invalid or Cancelled',
      content: <<~HTML
        <p>This invitation link is not valid or has been cancelled.</p>
        <p>If you believe you received this link in error, please contact an administrator.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'manage_your_membership',
      title: 'Manage Your Membership',
      content: <<~HTML
        <h5>Managing Your Membership</h5>
        <p>Here you can find information about managing your membership, updating your payment method, or changing your membership plan.</p>
        <p>If you need assistance, please contact an administrator.</p>
      HTML
    )

    TextFragment.ensure_exists!(
      key: 'code_of_conduct_url',
      title: 'Code of Conduct URL',
      content: ''
    )

    TextFragment.ensure_exists!(
      key: 'outgoing_email_banner',
      title: 'Outgoing email banner',
      content: ''
    )
  end
end
