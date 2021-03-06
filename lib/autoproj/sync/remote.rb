# frozen_string_literal: true

module Autoproj
    module Sync
        class Remote
            class FailedRemoteCommand < RuntimeError; end

            attr_reader :uri
            attr_reader :name

            def self.from_uri(uri, name: uri, enabled: true)
                if uri.scheme != "ssh"
                    raise ArgumentError, "unsupported protocol #{uri.scheme}"
                end
                Remote.new(uri, name: name, enabled: enabled)
            end

            def initialize(uri, name: uri, enabled: true)
                @uri  = uri
                @enabled = enabled
                @name = name
            end

            def enabled?
                @enabled
            end

            def remote_path
                @uri.path
            end

            def start
                result = nil
                Net::SFTP.start(@uri.host, @uri.user, password: @uri.password) do |sftp|
                    result = yield(sftp)
                end
                result
            end

            # Enumerate the packages that are outdated on the remote
            #
            # @yieldparam [Net::SFTP::Session] sftp the opened SFTP session, that can
            #    be used to do further operations on the remote
            # @yieldparam [Autoproj::PackageDescription] an outdated package
            def each_outdated_package(sftp, ws, packages)
                return enum_for(__method__, sftp, ws, packages) unless block_given?

                stat = packages.map do |package|
                    autobuild    = package.autobuild
                    installstamp = autobuild.installstamp
                    next unless File.exist?(installstamp)

                    local_stat  = File.stat(installstamp)
                    remote_path = File.join(uri.path, installstamp)
                    begin
                        remote_stat = sftp.file.open(remote_path) do |f|
                            f.stat
                        end
                        [package, local_stat, remote_stat, remote_path]
                    rescue Net::SFTP::StatusException => e
                        if e.code != Net::SFTP::Constants::StatusCodes::FX_NO_SUCH_FILE
                            raise
                        end
                        package
                    end
                end

                stat.compact.map do |package, local_stat, remote_stat, remote_path|
                    yield(package) if !local_stat ||
                        changed_stat?(local_stat, remote_stat)
                end.compact
            end

            private def changed_stat?(local, remote)
                return true if local.size != remote.size

                local_sec = local.mtime.tv_sec
                local_usec = local.mtime.tv_usec
                if remote.mtime != local_sec
                    true
                elsif !remote.respond_to?(:remote_nseconds)
                    false
                else
                    (remote.mtime_nseconds / 1000) != local_usec
                end
            end

            private def remote_mkdir_p(sftp, local_path)
                remote_path = File.join(@uri.path, local_path)
                ops = []
                while remote_path != '/'
                    ops << [remote_path, sftp.stat(remote_path)]
                    remote_path = File.dirname(remote_path)
                end
                missing = ops.take_while do |_, op|
                    op.wait
                    !op.response.ok?
                end
                mkdirs = missing.reverse.map do |path, _|
                    sftp.mkdir(path)
                end
                mkdirs.each(&:wait)
            end

            def autoproj_annex_files(ws)
                user_files = %w[env.sh].
                    map do |file|
                        File.join(ws.root_dir, file)
                    end
                autoproj_files = %w[env.yml installation-manifest].
                    map do |file|
                        File.join(ws.root_dir, '.autoproj', file)
                    end
                bundler_files = %w[gems/Gemfile gems/Gemfile.lock].
                    map do |file|
                        File.join(ws.prefix_dir, file)
                    end
                [*user_files, *ws.env.source_before, *ws.env.source_after,
                 *autoproj_files, *bundler_files].
                   find_all { |file| File.exist?(file) }
            end

            def rsync_target
                if @uri.user && @uri.password
                    "#{@uri.user}:#{@uri.password}@#{@uri.host}"
                elsif @uri.user
                    "#{@uri.user}@#{@uri.host}"
                else
                    @uri.host
                end
            end

            def rsync_dir(sftp, local_dir)
                remote_dir = remote_path(local_dir)
                ["rsync", "-a", "--delete-after", "#{local_dir}/",
                    "#{rsync_target}:#{remote_dir}/"]
            end

            def rsync_file(sftp, local_file)
                remote_file = remote_path(local_file)
                ["rsync", "-a", local_file,
                    "#{rsync_target}:#{remote_file}"]
            end

            def osdeps(sftp, ws, osdep_packages)
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

                partitioned_packages.each do |manager_name, packages|
                    install_osdep_packages(sftp, ws, manager_name, packages)
                end
            end

            def install_osdep_packages(sftp, ws, manager_name, packages)
                Autobuild.progress_start "sync-#{name}-osdeps-#{manager_name}",
                    "sync: handling #{packages.size} osdeps #{manager_name} packages "\
                        "on #{name}",
                    done_message: "sync: handled #{packages.size} "\
                        "osdeps #{manager_name} packages on #{name}" do

                    result = remote_autoproj(sftp, ws.root_dir,
                        "sync", "install-osdeps",
                        manager_name, *packages)
                    if result[:exit_code] != 0
                        raise RuntimeError,
                            "remote autoproj command failed\n"\
                            "autoproj exited with status "\
                            "#{result[:exit_code]}\n#{result}"
                    end
                end
            end

            def create_package_directories(sftp, pkg)
                Autobuild.progress_start pkg, "sync: preparing #{pkg.name}@#{name}",
                    done_message: "sync: prepared #{pkg.name}@#{name}" do

                    remote_mkdir_p(sftp, pkg.autobuild.prefix)
                    remote_mkdir_p(sftp, File.dirname(pkg.autobuild.installstamp))
                end
            end

            def rsync_package(sftp, pkg)
                Autobuild.progress_start pkg, "sync: updating #{pkg.name}@#{name}",
                    done_message: "sync: updated #{pkg.name}@#{name}" do
                    ops = [rsync_dir(sftp, pkg.autobuild.prefix),
                        rsync_file(sftp, pkg.autobuild.installstamp)]
                    ops.each do |op|
                        if !system(*op)
                            raise "update of #{pkg.name} failed"
                        end
                    end
                end
            end

            def remote_path(local_path)
                File.join(@uri.path, local_path)
            end

            def remote_file_exist?(sftp, path)
                sftp.stat!(remote_path(path))
                true
            rescue Net::SFTP::StatusException => e
                if e.code == Net::SFTP::Constants::StatusCodes::FX_NO_SUCH_FILE
                    false
                else
                    raise
                end
            end

            def remote_file_get(sftp, local_path)
                sftp.download!(remote_path(local_path))
            end

            def remote_file_put(sftp, local_path, content)
                sftp.upload!(StringIO.new(content), remote_path(local_path))
            end

            def remote_file_transfer(sftp, local_path, target: remote_path(local_path))
                sftp.upload!(local_path, target)
            end

            def remote_autoproj(sftp, root_dir, *command, chdir: nil, interactive: false)
                remote_exec(sftp,
                    remote_path(File.join(root_dir, ".autoproj/bin/autoproj")),
                    *command, chdir: chdir, interactive: interactive)
            end

            def remote_exec(sftp, *command, chdir: nil, interactive: false)
                if interactive
                    remote_interactive_exec(sftp, *command, chdir: chdir)
                else
                    status = Hash.new
                    ios = Hash[:stdout => STDOUT, :stderr => STDOUT]
                    target_dir = @uri.path
                    target_dir = File.join(target_dir, chdir) if chdir
                    pid = nil
                    command = "cd '#{target_dir}' && "\
                        "echo \"AUTOPROJ_SYNC_PID=$$\" && "\
                        "exec '" + command.join("' '") + "'"
                    ch = sftp.session.exec(command, status: status) do |channel, stream, data|
                        if !pid && (m = /^AUTOPROJ_SYNC_PID=(\d+)/.match(data))
                            pid = Integer(m[1])
                        else
                            ios[stream].print(data)
                            ios[stream].flush
                        end
                    end

                    begin
                        ch.wait
                        status
                    rescue Interrupt
                        sftp.session.exec!("kill #{pid}") if pid
                        ch.wait
                        raise
                    end
                end
            end

            def remote_interactive_exec(sftp, *command, chdir: nil)
                channel = sftp.session.open_channel do |ch|
                    ch.on_data do |ch, data|
                        STDOUT.print data
                        STDOUT.flush
                    end
                    ch.on_extended_data do |ch, type, data|
                        STDERR.print data
                    end

                    ch.request_pty
                    ch.exec("cd '#{chdir}' && '" + command.join("' '") + "'")
                end

                ssh = sftp.session
                while channel.active?
                    ssh.process(0.1)
                    begin
                        while true
                            data = STDIN.read_nonblock(4096)
                            channel.send_data(data)
                        end
                    rescue IO::WaitReadable
                    end
                end
            rescue EOFError
                channel.close
            end

            def local_file_get(local_path)
                File.read(local_path)
            end

            def info(message)
                Autoproj.message "  #{message}", force: true
            end

            def bootstrap_or_update_autoproj(sftp, ws)
                gemfile_lock_path = File.join(ws.root_dir, ".autoproj/Gemfile.lock")
                if remote_file_exist?(sftp, gemfile_lock_path)
                    remote_gemfile_lock = remote_file_get(sftp, gemfile_lock_path)
                    local_gemfile_lock  = local_file_get(gemfile_lock_path)
                    if remote_gemfile_lock == local_gemfile_lock
                        info "remote Autoproj install up-to-date"
                        info "sync: Autoproj install up-to-date on #{name}"
                        return
                    end

                    info "sync: updating the Autoproj install on #{name}"

                    remote_file_put(sftp, gemfile_lock_path, local_gemfile_lock)
                    remote_file_transfer(
                        sftp, File.join(ws.root_dir, ".autoproj/Gemfile"))
                    remote_file_transfer(
                        sftp, File.join(ws.root_dir, ".autoproj/config.yml"))
                    result = remote_autoproj(
                        sftp, ws.root_dir, "update", "--autoproj")
                    unless result[:exit_code] == 0
                        raise FailedRemoteCommand, "failed to update Autoproj:\n"\
                            "autoproj update --autoproj finished with exit status "\
                            "#{result[:exit_code]}\n"\
                            "#{result}"
                    end
                else
                    info "sync: installing Autoproj on #{name}"

                    autoproj_spec = Bundler.definition.specs.
                        find { |spec| spec.name == "autoproj" }
                    autoproj_dir = autoproj_spec.full_gem_path
                    install_script = File.join(autoproj_dir, "bin", "autoproj_install")
                    remote_mkdir_p(sftp, ws.root_dir)
                    sftp.upload!(install_script,
                        remote_path(File.join(ws.root_dir, "autoproj_install")))
                    remote_file_transfer(sftp, File.join(ws.root_dir, ".autoproj/config.yml"),
                        target: remote_path(File.join(ws.root_dir, 'bootstrap-config.yml')))
                    remote_file_transfer(sftp, File.join(ws.root_dir, ".autoproj/Gemfile"),
                        target: remote_path(File.join(ws.root_dir, 'bootstrap-Gemfile')))
                    result = sftp.session.exec!("cd '#{remote_path(ws.root_dir)}' && "\
                        "#{ws.config.ruby_executable} autoproj_install "\
                        "--gemfile bootstrap-Gemfile "\
                        "--seed-config bootstrap-config.yml")
                    if result.exitstatus != 0
                        raise RuntimeError, "failed to install autoproj: #{result}"
                    end
                end
            end

            def update(sftp, ws, packages)
                # First check if autoproj is bootstrapped on the target already
                bootstrap_or_update_autoproj(sftp, ws)

                packages = each_outdated_package(sftp, ws, packages).to_a

                info "sync: #{packages.size} outdated packages on #{name}"

                executor = Concurrent::FixedThreadPool.new(6)
                futures = packages.map do |pkg|
                    create_package_directories(sftp, pkg)
                    Concurrent::Future.execute(executor: executor) do
                        rsync_package(sftp, pkg)
                    end
                end

                # Copy some autoproj installation-manifest files
                Autobuild.progress_start "sync-#{name}-autoproj",
                    "sync: updating Autoproj configuration files on #{name}",
                    done_message: "sync: updated Autoproj configuration files on #{name}" do
                    autoproj_annex_files(ws).each do |file|
                        missing = []
                        dir = File.join(@uri.path, File.dirname(file))
                        while dir != '/'
                            begin
                                sftp.stat!(dir)
                                break
                            rescue Net::SFTP::StatusException
                                missing.unshift dir
                                dir = File.dirname(dir)
                            end
                        end

                        missing.each do |dir|
                            sftp.mkdir!(dir)
                        end

                        sftp.upload!(file, File.join(@uri.path, file))
                    end
                end

                futures.each_with_index do |f, i|
                    f.value!
                end

            ensure
                if executor
                    executor.shutdown
                    executor.wait_for_termination
                end
            end
        end
    end
end
