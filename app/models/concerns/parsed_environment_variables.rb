# Environment variables kept as one text field, one KEY=VALUE per line, that a script is run
# with. Blank lines and lines starting with # are ignored. Models using it hold the column
# encrypted with +encrypts_sensitive_string+, so readers see plaintext.
module ParsedEnvironmentVariables
  extend ActiveSupport::Concern

  def parsed_environment_variables
    return {} if environment_variables.blank?

    environment_variables.each_line.with_object({}) do |line, hash|
      line = line.strip
      next if line.blank? || line.start_with?('#')

      key, value = line.split('=', 2)
      next if key.blank?

      hash[key.strip] = (value || '').strip
    end
  end
end
