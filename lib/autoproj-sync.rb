require 'autoproj/cli/main_sync'

class Autoproj::CLI::Main
    desc 'sync', 'synchronize a workspace with remote location(s)'
    subcommand 'sync', Autoproj::CLI::MainSync
end
