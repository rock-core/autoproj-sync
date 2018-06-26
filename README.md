# Autoproj::Sync

This Autoproj plugin provides a way to keep remote location(s) synchronized
with a local workspace, as part of the build process. This allows for to keep
a local development workflow, but run things remotely in a very flexible way.

It is not *that* magical. It is based on the assumption that:
- the local and remote hosts have equivalent environments. In practice, it means
  that binaries built with the local machine are compatible with the environment
  on the remote machine (same shared libraries, ...)
- the remote environment is synchronized at the same path than the local one

## Installation

Run

```
autoproj plugin install autoproj-sync
```

## Usage

### Preparing the remote target

To function, Autoproj Sync needs the remote target to match the local target, that is:

- allow to run binaries built locally (meaning same or compatible shared libraries)
- use the same full paths
- have a compatible ruby binary at the same path than the one used locally. If you
  for instance use rbenv, you will need to install the same Ruby version through rbenv.
- if you are using a git version of Autoproj, or plugins that are not available through
  RubyGems, you will have to install them manually at the same path than on the local
  machine

Moreover the remote target should be accessible via SSH public key authentication.

### CLI Usage

Add and enable a synchronisation target with

```
autoproj sync add NAME URL
```

This will trigger a synchronization.

Targets can be listed with

```
autoproj sync list
```

And removed with

```
autoproj sync remove NAME
```

Synchronisation can be temporarily disabled with

```
autoproj sync disable
```

And reenabled with

```
autoproj sync enable
```

Re-enabling a target will force a synchronisation to occur. Once a target is
enabled, synchronisation happens during the build, whenever a package has
been built and installed.

The `enable` and `disable` subcommands both accept target names, which allows
to selectively enable and disable.

```
autoproj sync enable
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rock-core/autoproj-sync.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
