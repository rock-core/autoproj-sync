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

                    source_packages, osdep_packages, _resolved_selection =
                        ws.load_packages(ws.manifest.default_packages(false),
                            recursive: true,
                            non_imported_packages: :ignore,
                            auto_exclude: false)
                    ws.finalize_setup
                    source_packages = source_packages.map do |name|
                        ws.manifest.find_package_definition(name)
                    end
                    [source_packages, osdep_packages]
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
                packages, = Autoproj.silent { ws_load }
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
                packages, = Autoproj.silent { ws_load }

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
                packages, = Autoproj.silent { ws_load }

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

            desc 'install-osdeps MANAGER_TYPE <PACKAGES...>',
                'install osdeps coming from the local machine',
                hide: true
            def install_osdeps(manager_type, *packages)
                Autobuild.silent { ws_load }
                installer = ws.os_package_installer

                installer.setup_package_managers
                manager = installer.package_managers.fetch(manager_type)
                installer.install_manager_packages(manager, packages)
            end

            desc 'osdeps [NAME]', 'install the osdeps on the remote'
            def osdeps(*names)
                _, osdep_packages = Autobuild.silent { ws_load }
                installer = ws.os_package_installer

                installer.setup_package_managers
                all = ws.all_os_packages
                partitioned_packages = installer.
                    resolve_and_partition_osdep_packages(osdep_packages, all)

                os_packages = partitioned_packages.delete(installer.os_package_manager)
                if os_packages
                    partitioned_packages = [[installer.os_package_manager, os_packages]].
                        concat(partitioned_packages.to_a)
                end

                partitioned_packages = partitioned_packages.map do |manager, packages|
                    manager_name, _ = installer.package_managers.
                        find { |key, obj| manager == obj }
                    [manager_name, packages]
                end

                remotes = resolve_selected_remotes(*names)
                remotes.each do |remote|
                    remote.start do |sftp|
                        partitioned_packages.each do |manager_name, packages|
                            result = remote.remote_autoproj(sftp, ws.root_dir,
                                "sync", "install-osdeps",
                                manager_name, *packages)
                            if result.exitstatus != 0
                                raise RuntimeError, "remote autoproj command failed\n"\
                                    "autoproj exited with status #{result.exitstatus}\n"\
                                    "#{result}"
                            end
                        end
                    end
                end
            end

            desc 'exec NAME COMMAND', 'execute a command on a remote workspace'
            option :chdir, doc: 'working directory for the command',
                type: :string, default: nil
            def exec(remote_name, *command)
                remote = config.remote_by_name(remote_name)
                result = remote.start do |sftp|
                    remote.remote_autoproj(sftp, "exec", *command,
                        chdir: options[:chdir] || ws.root_dir)
                end
                puts result
                exit result.exitstatus
            end
        end
    end
end
