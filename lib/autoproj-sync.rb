require 'autoproj/cli/main_sync'

class Autoproj::CLI::Main
    desc 'sync', 'synchronize a workspace with remote location(s)'
    subcommand 'sync', Autoproj::CLI::MainSync

    register_post_command_hook(:build) do |ws, args|
        source_packages = args[:source_packages]
        source_packages = source_packages.map do |package_name|
            ws.manifest.find_package_definition(package_name)
        end

        config = Autoproj::Sync::Config.new(ws)
        config.each_enabled_remote.each do |remote|
            remote.start do |sftp|
                remote.update(sftp, ws, source_packages)
            end
        end
    end
    register_post_command_hook(:update) do |ws, args|
        source_packages, osdep_packages = args.
            values_at(:source_packages, :osdep_packages)
        source_packages = source_packages.map do |package_name|
            ws.manifest.find_package_definition(package_name)
        end

        config = Autoproj::Sync::Config.new(ws)
        config.each_enabled_remote.each do |remote|
            remote.start do |sftp|
                unless source_packages.empty?
                    remote.update(sftp, ws, source_packages)
                end
                unless osdep_packages.empty?
                    remote.osdeps(sftp, ws, osdep_packages)
                end
            end
        end
    end
end
