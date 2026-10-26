# plenv-ssl-doctor

A [plenv](https://github.com/tokuhirom/plenv) plugin for installing and checking
Perl's TLS modules in the currently selected Perl environment.

## Prerequisites and installation

- A Unix-like environment with Bash at `/bin/bash` and Git.
- plenv installed and initialized, with a working Perl selected. Commands use
  `perl` and `cpanm` from `PATH`; verify the intended environment before installing.
- `cpanm` for installation commands. If missing, use `plenv install-cpanm` with
  your selected Perl.
- For building Net::SSLeay: a C compiler, make, and OpenSSL development headers
  and libraries matching your platform and architecture. An `openssl` executable
  alone is not enough. See the
  [upstream installation instructions](https://github.com/radiator-software/p5-net-ssleay/blob/master/README).
- Network access to retrieve the plugin and CPAN distributions. Regression tests
  run offline.

Clone using HTTPS (no GitHub SSH account setup required):

```sh
mkdir -p "${PLENV_ROOT:-$HOME/.plenv}/plugins"
git clone https://github.com/xtetsuji/plenv-ssl-doctor.git \
  "${PLENV_ROOT:-$HOME/.plenv}/plugins/plenv-ssl-doctor"
plenv ssl-doctor
```

For a custom plenv root, set `PLENV_ROOT` to that location first. Before running
installers, inspect the selected environment:

```sh
plenv version
plenv which perl
perl -e 'print "$^X\n$^V\n"'
command -v cpanm
```

## Commands and exit status

```text
plenv ssl-doctor install-net-ssleay
plenv ssl-doctor install-io-socket-ssl
plenv ssl-doctor check-io-socket-ssl
```

These are the implemented subcommands. There are no implemented command-line
options; extra arguments to recognized commands are currently ignored.
No argument or an unknown command prints usage and exits **0**, so usage output
is not evidence that a diagnostic succeeded.

To inspect a command's exit status, run `echo "$?"` immediately after it, before
running another command.

### Install Net::SSLeay

```sh
plenv ssl-doctor install-net-ssleay
```

If Net::SSLeay loads, report the existing installation and exit **0**, without
checking its version or reinstalling it. Otherwise the command:

1. Checks for `cpanm`.
2. Runs `cpanm Crypt::OpenSSL::Guess`.
3. Calls `Crypt::OpenSSL::Guess::find_openssl_prefix()` and prints the result.
4. Sets `OPENSSL_PREFIX` to that resolved result for `cpanm Net::SSLeay`.

The current command does not provide a reliable explicit OpenSSL selection
interface: a caller-supplied `OPENSSL_PREFIX` is not independently validated or
preserved by the plugin; the value passed to cpanm comes from Guess. Guess's
behavior can depend on its installed version and environment. Copy/paste
override examples are deferred until
[explicit selection is implemented (#3)](https://github.com/xtetsuji/plenv-ssl-doctor/issues/3).

Known limitations:

- A missing module and a broken installed module both enter the installation
  path; the initial load error is suppressed.
- Missing `cpanm` prints advice but currently exits **0**.
- An empty guessed prefix exits **1**. Failed installers or Guess invocations
  normally stop the script with the failing command's nonzero status.
- Installer success exits **0**, but there is no post-install module load check.
  Verify the result separately:

  ```sh
  perl -MNet::SSLeay -e 'print "Net::SSLeay $Net::SSLeay::VERSION\n"'
  ```

### Install IO::Socket::SSL

```sh
plenv ssl-doctor install-io-socket-ssl
```

The minimum version remains **1.42**, preserving the existing compatibility
baseline. This command only checks that the module loads and satisfies that
version; it does not use any API that requires raising the minimum. This is a
compatibility check, not a guarantee of current TLS security or suitability for
every application. Use a maintained release appropriate for your application.

- If the module is missing, run `cpanm IO::Socket::SSL` and verify the result.
- If version 1.42 or newer loads successfully, report the existing installation
  and exit **0** without invoking cpanm.
- If too old, exit **1** and ask you to upgrade with `cpanm IO::Socket::SSL`, then
  rerun the command. No automatic upgrade occurs.
- If loading fails (including a missing dependency), report the load error and
  exit **1** without invoking cpanm.
- Missing `cpanm` exits **1** and recommends `plenv install-cpanm`.
- Installer failure preserves its nonzero status. After installer success, a
  module that fails to load or satisfy 1.42 exits **1**; otherwise exit **0**.

Version checks use Perl's `VERSION` method, including for dotted versions.
The internal missing-module status 2 selects installation; it is not the public
status for a missing module after failed verification.

### Check IO::Socket::SSL

```sh
plenv ssl-doctor check-io-socket-ssl
```

Print the installed version and exit **0** when the module loads. A missing or
unloadable module produces a generic missing-module message and exits **1**;
the underlying load error is suppressed. This command does **not** check the
1.42 minimum, make an HTTPS request, or validate certificates.

## OpenSSL discovery and compatibility

[Crypt::OpenSSL::Guess](https://github.com/akiym/Crypt-OpenSSL-Guess) discovers
paths; finding a prefix does not prove that a Net::SSLeay release can compile
against those headers and libraries. This plugin currently performs no
compatibility policy check.

| Term | Meaning | How to inspect |
| --- | --- | --- |
| Shell OpenSSL | Command found on `PATH` | `command -v openssl` and `openssl version` |
| Future-build OpenSSL | Prefix supplied to a new Net::SSLeay build | Resolved-prefix output and cpanm build log |
| Runtime OpenSSL | Library loaded by an installed Net::SSLeay | `Net::SSLeay::SSLeay_version(0)` in the selected Perl |

Changing `PATH`, installing another OpenSSL, or discovering another prefix does
not rebuild installed Net::SSLeay. A future CPAN install can also fetch a
different module version from the one currently installed.

These read-only checks make no network requests:

```sh
command -v openssl
openssl version
perl -MNet::SSLeay -e 'print "Net::SSLeay $Net::SSLeay::VERSION\n"; print Net::SSLeay::SSLeay_version(0), "\n"'
```

On macOS, inspect an already installed Homebrew OpenSSL 3 formula without
assuming an Intel or Apple Silicon prefix:

```sh
brew --prefix openssl@3
"$(brew --prefix openssl@3)/bin/openssl" version
```

This inspects a candidate; it does not select it for the plugin's installer.

## Troubleshooting

### HTTP::Tiny reports status 599

[HTTP::Tiny](https://metacpan.org/pod/HTTP::Tiny) uses 599 for local request
exceptions, with details in the response's `content` field. This alone does not
prove an OpenSSL compatibility problem. Start with local checks:

```sh
perl -MIO::Socket::SSL -e 'IO::Socket::SSL->VERSION("1.42"); print "$IO::Socket::SSL::VERSION\n"'
perl -MNet::SSLeay -e 'print Net::SSLeay::SSLeay_version(0), "\n"'
perl -MHTTP::Tiny -e 'my ($ok, $why) = HTTP::Tiny->can_ssl; die "$why\n" unless $ok; print "Local TLS support available\n"'
```

These reveal load errors and local TLS capability without network requests;
success does not prove that a remote connection or certificate validation will
succeed. Inspect the original response content to distinguish dependency
failures from DNS, proxy, timeout, or CA trust problems. Check the system clock
and CA configuration appropriate to your module versions and environment.
Keep certificate and hostname verification enabled.

### IO::Socket::SSL is missing or will not load

Run the direct Perl load/version check above in the same plenv environment as
the failing application. Use `install-io-socket-ssl` for a missing module. For
an outdated module, explicitly run `cpanm IO::Socket::SSL` and rerun the check.
A dependency or shared-library error needs its underlying cause repaired;
read that error before repeating installation.

### Net::SSLeay will not build

Read cpanm's reported build log location. Record the exact distribution version,
resolved OpenSSL prefix, compiler error, Perl version, OS and architecture.
Check that headers and libraries are installed together for the intended
architecture. Compare the build prefix with shell and runtime versions above
rather than assuming all three are the same.

[Issue #4](https://github.com/xtetsuji/plenv-ssl-doctor/issues/4) reports
Net::SSLeay **1.96** failing with OpenSSL **4.0.3** on macOS / Perl **5.44.0**,
including `ASN1_TIME`, `SSLv3_method`, and `TLSv1_method` errors; an OpenSSL 3
build succeeded in that report. This is evidence about that combination,
not all OpenSSL 4 builds.

Upstream [PR #553](https://github.com/radiator-software/p5-net-ssleay/pull/553)
adds OpenSSL 4.0.0 support. The upstream
[Changes file](https://github.com/radiator-software/p5-net-ssleay/blob/master/Changes)
records that support in developer release **1.97_01**, separately from stable
**1.96**. A merged fix does not mean that `cpanm Net::SSLeay` fetches a release
containing it, or that every OpenSSL 4 patch version has been tested. Verify
the exact release's notes and build results.

For the reported 1.96/4.0.3 failure, a workaround is to rebuild against a
maintained OpenSSL 3 version supported by that Net::SSLeay release, using the
[upstream build instructions](https://github.com/radiator-software/p5-net-ssleay/blob/master/README)
to control the build, then verify the module and runtime library. This is
currently a manual operation outside this plugin's selection interface.
Confirm the chosen prefix in the build log; simply rerunning this plugin may
choose the same failing candidate. Do not remove a working installation merely
because this command suggests uninstalling it.

## Contributing and offline tests

From the repository root, run:

```sh
bash -n bin/plenv-ssl-doctor
prove -v t
```

The current `t/install-io-socket-ssl.t` regression suite uses temporary module
fixtures, an isolated module search path, and fake executables. It does not
access the network, install CPAN modules, run real builds, or change your Perl
installation. It covers missing/current/old/dotted versions, load failures,
missing cpanm, installer failures, and post-install verification. It does not
establish compatibility with real OpenSSL libraries or test every subcommand.

Keep user-facing messages and documentation in English. Add offline
fixture-based coverage for behavior changes; avoid modifying the developer's
Perl or OpenSSL during tests. Include the command, exit status, exact versions,
and relevant redacted errors in bug reports.

Further documentation will accompany explicit OpenSSL selection (#3),
compatibility diagnostics (#4), general diagnostics (#5), and expanded testing
(#6). Those features and their proposed examples are not available in this
version; this README documents the current implementation.

## Author

OGATA Tetsuji <tetsuji.ogata@gmail.com>

## License

MIT License.
