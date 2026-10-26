# plenv-ssl-doctor

plenv-ssl-doctor is plenv's plugin.

This plugin provides `ssl-doctor` sub-command to plenv.

```
$ plenv ssl-doctor
Usage:
  plenv ssl-doctor [install-net-ssleay]
```

For future release, `ssl-doctor` is taken its sub-command
as `plenv ssl-doctor install-net-ssleay` .

## Installation

```
mkdir -p $PLENV_ROOT/plugins
git clone git@github.com:xtetsuji/plenv-ssl-doctor.git $PLENV_ROOT/plugins/plenv-ssl-doctor
```

## Usage

### plenv ssl-doctor install-net-ssleay

Install `Net::SSLeay` by some methods.

### plenv ssl-doctor install-io-socket-ssl

Install `IO::Socket::SSL` by some methods.

The minimum version remains **1.42**, preserving the existing compatibility
baseline. This command only checks that the module loads and satisfies that
version; it does not use any API that requires raising the minimum. This is a
compatibility check, not a guarantee of current TLS security or suitability for
every application. Use a maintained release appropriate for your application.

- If the module is missing, run `cpanm IO::Socket::SSL` and verify the result.
- If version 1.42 or newer loads successfully, report the existing installation
  and exit successfully.
- If the installed version is too old, exit nonzero and ask you to upgrade with
  `cpanm IO::Socket::SSL`, then rerun this command.
- If the module fails to load (including a missing dependency), report the load
  error and exit nonzero. Installer and post-install verification failures also
  return nonzero. If `cpanm` is missing, run `plenv install-cpanm` first.

Version checks use Perl's `VERSION` method, including for dotted versions.

### plenv ssl-doctor check-io-socket-ssl

Check `IO::Socket::SSL` installation status.

## Tests

Run `prove -v t` from the repository root. The regression tests use temporary
module fixtures and a stub installer; they do not install modules, access the
network, or change your Perl installation.

## Author

OGATA Tetsuji <tetsuji.ogata@gmail.com>

## License

MIT License.
