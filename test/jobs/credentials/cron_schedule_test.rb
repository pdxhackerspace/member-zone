require 'test_helper'

class CredentialCronTest < ActiveSupport::TestCase
  test 'the three recurring jobs are scheduled as active jobs without an explicit queue' do
    source = Rails.root.join('config/initializers/sidekiq.rb').read
    blocks = source.scan(/Sidekiq::Cron::Job\.create\((.*?)\n  \)/m).flatten

    {
      'Credentials::HealthCheckJob' => '*/10 * * * *',
      'Credentials::ExpireJob' => '20 4 * * *',
      'Credentials::ReconcileJob' => '30 4 * * *'
    }.each do |job, cron|
      block = blocks.find { |candidate| candidate.include?("class: '#{job}'") }
      assert block, "#{job} must be scheduled"
      assert_includes block, "cron: '#{cron}'"
      assert_includes block, 'active_job: true'
      assert_not_includes block, 'queue:'
    end
  end
end
