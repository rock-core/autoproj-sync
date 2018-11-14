
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "autoproj/sync/version"

Gem::Specification.new do |spec|
    spec.name          = "autoproj-sync"
    spec.version       = Autoproj::Sync::VERSION
    spec.authors       = ["Sylvain Joyeux"]
    spec.email         = ["sylvain.joyeux@13robotics.com"]

    spec.summary       = %q{Synchronizes the build byproducts of an Autoproj workspace to remote target(s)}
    spec.homepage      = "https://rock-core.github.io/rock-and-syskit"
    spec.license       = "MIT"

    # Specify which files should be added to the gem when it is released.
    # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
    spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
      `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
    end
    spec.bindir        = "exe"
    spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
    spec.require_paths = ["lib"]

    spec.add_dependency "autoproj", "~> 2.4"
    spec.add_dependency "net-sftp"
    spec.add_development_dependency "bundler", "~> 1.16"
    spec.add_development_dependency "minitest", "~> 5.0"
end
