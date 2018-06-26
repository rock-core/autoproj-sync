module Autoproj
    module Sync
        class Config
            def initialize(ws)
                @ws = ws
            end

            def each_remote
                return enum_for(__method__) unless block_given?

                targets = @ws.config.get('sync', Hash.new)
                targets.each do |name, config|
                    yield Remote.from_uri(URI.parse(config['uri']),
                        name: name, enabled: config['enabled'])
                end
            end

            def each_enabled_remote
                return enum_for(__method__) unless block_given?

                each_remote do |remote|
                    yield(remote) if remote.enabled?
                end
            end

            def remote_by_name(name)
                unless remote = find_remote_by_name(name)
                    raise ArgumentError, "no remote named '#{name}', "\
                        "existing remotes: #{each_remote.map(&:name).sort.join(", ")}"
                end
                remote
            end

            def find_remote_by_name(name)
                targets = @ws.config.get('sync', Hash.new)
                if config = targets[name]
                    remote_from_config(name, config)
                end
            end

            private def remote_from_config(name, config)
                Remote.from_uri(URI.parse(config['uri']),
                    name: name, enabled: config['enabled'])
            end

            private def remote_to_config(remote)
                [remote.name, Hash[
                    'uri' => remote.uri.to_s,
                    'enabled' => remote.enabled?
                ]]
            end

            def add_remote(remote)
                name, config = remote_to_config(remote)
                targets = @ws.config.get('sync', Hash.new)
                targets[name] = config
                @ws.config.set('sync', targets)
                @ws.save_config
            end

            def delete_remote(name)
                targets = @ws.config.get('sync', Hash.new)
                targets.delete(name)
                @ws.config.set('sync', targets)
                @ws.save_config
            end

            def update_remote_config(name)
                targets = @ws.config.get('sync', Hash.new)
                unless (config = targets[name])
                    raise ArgumentError, "There is no target called #{name}"
                end

                new_config = config.dup
                yield(new_config)
                if new_config != config
                    targets[name] = new_config
                    @ws.config.set('sync', targets)
                    @ws.save_config
                end
            end
        end
    end
end
