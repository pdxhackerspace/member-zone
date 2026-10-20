module AuditLogs
  module ScriptCatalog
    ROLE = 'audit'.freeze

    module_function

    def directories
      OperatorScripts::Catalog.directories_for(ROLE)
    end

    def scripts
      OperatorScripts::Catalog.scripts_for(ROLE)
    end

    def allowed?(path)
      OperatorScripts::Catalog.allowed?(path, ROLE)
    end
  end
end
