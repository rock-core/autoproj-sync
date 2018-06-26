require 'autoproj/sync'

module Autoproj
    module CLI
        # The 'jenkins' subcommand for autoproj
        class MainSync < Thor
            namespace 'sync'

            no_commands do
                def ws
                    unless @ws
                        @ws = Autoproj::Workspace.default
                        @ws.load_config
                    end
                    @ws
                end

                def config
                    unless @config
                        @config = Sync::Config.new(ws)
                    end
                    @config
                end

                def ws_load
                    ws.setup
                    ws.load_package_sets
                    ws.setup_all_package_directories
                    ws.finalize_package_setup

                    source_packages, _osdep_packages, _resolved_selection =
                        ws.load_packages(ws.manifest.default_packages(false),
                            recursive: true,
                            non_imported_packages: :ignore,
                            auto_exclude: false)
                    ws.finalize_setup
                    source_packages.map do |name|
                        ws.manifest.find_package_definition(name)
                    end
                end

                def resolve_selected_remotes(*names)
                    if names.empty?
                        config.each_enabled_remote
                    else
                        names.map { |n| config.remote_by_name(n) }
                    end
                end
            end

            desc 'add NAME URL', "add a new remote target"
            def add(name, uri)
                if remote = config.find_remote_by_name(name)
                    STDERR.puts "There is already a target called #{name} pointing to "\
                        "#{remote.uri}"
                    exit 1
                end

                remote = Sync::Remote.from_uri(URI.parse(uri), name: name)
                config.add_remote(remote)
                packages = Autoproj.silent { ws_load }
                remote.start do |sftp|
                    remote.update(sftp, ws, packages)
                end
            end

            desc 'remove NAME', "remove a remote target"
            def remove(name)
                config.delete_remote(name)
            end

            desc 'list', "lists registered targets"
            def list
                config.each_remote do |remote|
                    enabled = remote.enabled? ? 'enabled' : 'disabled'
                    puts "#{remote.name}: #{remote.uri} (#{enabled})"
                end
            end

            desc 'status [NAME]', "accesses a target (or all enabled targets) and "\
                "display outdated packages"
            def status(*names)
                remotes = resolve_selected_remotes(*names)
                packages = Autoproj.silent { ws_load }

                remotes.each do |r|
                    outdated_packages =
                        r.start do |sftp|
                            r.each_outdated_package(sftp, @ws, packages).to_a
                        end
                    puts "#{outdated_packages.size} outdated packages"
                    outdated_packages.each do |pkg|
                        puts "  #{pkg.name}"
                    end
                end
            end

            desc 'update NAME', "trigger an update for a remote"
            def update(*names)
                remotes = resolve_selected_remotes(*names)
                packages = Autoproj.silent { ws_load }

                remotes.each do |r|
                    r.start do |sftp|
                        r.update(sftp, ws, packages)
                    end
                end
            end

            desc 'enable NAME', "enables a previously disabled target, or all targets"
            def enable(*names)
                names = ws.config.get('sync', Hash.new).keys if names.empty?
                names.each do |name|
                    update_target_config(name) do |config|
                        unless config['enabled']
                            remote = config.find_remote_by_name(config['name'])
                            synchronize(remote)
                            config['enabled'] = true
                        end
                    end
                end
            end

            desc 'disable [NAME]', "disables a previously enabled target, or all targets"
            def disable(*names)
                names = ws.config.get('sync', Hash.new).keys if names.empty?
                names.each do |name|
                    update_target_config(name) do |config|
                        config['enabled'] = false
                    end
                end
            end
        end
    end
end
