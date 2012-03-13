module Puppet::Module::Tool
  module Applications
    class Upgrader

      include Puppet::Module::Tool::Errors

      def initialize(name, options)
        @action              = :upgrade
        @environment         = Puppet::Node::Environment.new(Puppet.settings[:environment])
        @module_name         = name
        @options             = options
        @force               = options[:force]
        @ignore_dependencies = options[:force] || options[:ignore_dependencies]
        @version             = options[:version]
      end

      def run
        begin
          results = { :module_name => @module_name }

          get_local_constraints

          if @installed[@module_name].length > 1
            raise MultipleInstalledError,
              :module_name       => @module_name,
              :installed_modules => @installed[@module_name].sort_by { |mod| @environment.modulepath.index(mod.modulepath) }
          elsif @installed[@module_name].empty?
            raise NotInstalledError, :module_name => @module_name
          end

          @module = @installed[@module_name].last
          results[:installed_version] = @module.version ? @module.version.sub(/^(?=\d)/, 'v') : nil
          results[:requested_version] = @version || (@conditions[@module_name].empty? ? :latest : :best)
          dir = @module.modulepath

          Puppet.notice "Found '#{@module_name}' (#{results[:installed_version] || '???'}) in #{dir} ..."
          if !@options[:force] && @module.has_metadata? && @module.has_local_changes?
            raise LocalChangesError,
              :module_name       => @module_name,
              :requested_version => @version || (@conditions[@module_name].empty? ? :latest : :best),
              :installed_version => @module.version
          end

          begin
            get_remote_constraints
          rescue => e
            raise UnknownModuleError, results.merge(:repository => Puppet::Forge.repository.uri)
          else
            raise UnknownVersionError, results.merge(:repository => Puppet::Forge.repository.uri) if @remote.empty?
          end

          if !@options[:force] && @versions["#{@module_name}"].last[:vstring].sub(/^(?=\d)/, 'v') == (@module.version || '0.0.0').sub(/^(?=\d)/, 'v')
            raise VersionAlreadyInstalledError,
              :module_name       => @module_name,
              :requested_version => @version || ((@conditions[@module_name].empty? ? 'latest' : 'best') + ": #{@versions["#{@module_name}"].last[:vstring].sub(/^(?=\d)/, 'v')}"),
              :installed_version => @installed[@module_name].last.version,
              :conditions        => @conditions[@module_name] + [{ :module => :you, :version => @version }]
          end

          @graph = resolve_constraints({ @module_name => @version })

          tarballs = download_tarballs(@graph, @graph.last[:path])

          unless @graph.empty?
            Puppet.notice 'Upgrading -- do not interrupt ...'
            tarballs.each do |hash|
              hash.each do |dir, path|
                Unpacker.new(path, @options.merge(:dir => dir)).run
              end
            end
          end

          results[:result] = :success
          results[:base_dir] = @graph.first[:path]
          results[:affected_modules] = @graph
        rescue VersionAlreadyInstalledError => e
          results[:result] = :noop
          results[:error] = {
            :oneline   => e.message,
            :multiline => e.multiline
          }
        rescue => e
          results[:error] = {
            :oneline => e.message,
            :multiline => e.respond_to?(:multiline) ? e.multiline : [e.to_s, e.backtrace].join("\n")
          }
        ensure
          results[:result] ||= :failure
        end

        return results
      end

      private
      include Puppet::Module::Tool::Shared
    end
  end
end
