# plenv-ssl-doctor

A [plenv](https://github.com/tokuhirom/plenv) plugin for installing and checking
Perl's TLS modules in the currently selected Perl environment.

## Prerequisites and installation

- A Unix-like environment with Bash at `/bin/bash` and Git.
- plenv installed and initialized, with a working Perl selected. The plugin
  discovers the selected Perl from `PATH` and pins its absolute interpreter path
  for subsequent checks and installs; verify the intended environment first.
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
plenv which cpanm
```

## Commands and exit status

```text
plenv ssl-doctor install-net-ssleay [--openssl-prefix PATH] [--net-ssleay-version VERSION]
plenv ssl-doctor install-io-socket-ssl
plenv ssl-doctor check-io-socket-ssl
```

Both options are accepted before or after `install-net-ssleay` only. If either
is repeated, its last value wins. `--net-ssleay-version VERSION` accepts an
exact release in the form digits.digits, optionally followed by an underscore
and digits (for example `1.96` or `1.97_01`); ranges and `=VERSION` syntax are
not accepted. A missing or malformed version exits **2**.

A missing or empty prefix value or a value beginning with `--` exits **2**.
An unknown `--` option, an extra positional argument, or use of either option
with another command also exits **2**. The form
`--openssl-prefix=PATH` is not supported. An empty `OPENSSL_PREFIX` is also an
invalid explicit selection; a CLI value takes precedence over it.

With no arguments or a single unknown command, usage is printed and the exit
status is **0**, so usage output is not evidence that a diagnostic succeeded.

To inspect a command's exit status, run `echo "$?"` immediately after it, before
running another command.

### Selected Perl and installer

Each recognized command discovers Perl using `perl -e 'print $^X'`, requires an
executable absolute path, and queries its version. It prints the selected path
and version to stderr, then uses that absolute interpreter for module checks,
Guess queries, and installer invocations. Failed discovery or version queries
exit **1**.

When installation is needed, the plugin locates cpanm using `command -v cpanm`.
A path ending in `/shims/cpanm` is resolved using `plenv which cpanm`; the shim
itself is not executed as the installer. The resolved script must be an
absolute, readable regular file. Supported first-line shebangs are:

- Exactly `#!/usr/bin/env perl` (the plugin still runs the selected absolute Perl).
- An absolute interpreter path without arguments that refers to the same file
  as the selected Perl, including a symlink to it.

The plugin invokes the installer as `selected-perl /absolute/path/to/cpanm ...`.
It conservatively rejects shell wrappers, other unverifiable shebangs, shebang
arguments (including `env -S`), and scripts naming a different Perl. Such a
rejection exits **1** before installation; it does not prove the wrapper could
never work. Check `plenv version`, `plenv which perl`, and `plenv which cpanm`,
and run `plenv install-cpanm` for the selected Perl to obtain a supported script.
An already usable module does not require cpanm.

### Install Net::SSLeay

```sh
plenv ssl-doctor install-net-ssleay
```

An explicit prefix is validated even when Net::SSLeay already loads. If it is
valid (or absent) and the module loads, the command reports its installed
version and does not reinstall it. If a requested version differs from that
reported version, the command exits **1**; otherwise it exits **0**. When the
module does not load, the command selects cpanm, selects an OpenSSL candidate,
sets `OPENSSL_PREFIX` for the Net::SSLeay installer, and verifies that the
selected Perl can load the installed module.

Selection precedence is CLI `--openssl-prefix PATH`, then the environment
variable `OPENSSL_PREFIX` (if set), then automatic discovery. An invalid
explicit selection exits **2** without falling back. For example, after
installing Homebrew's `openssl@3` development files and verifying the candidate
as described below, either invocation selects it for a new build:

```sh
plenv ssl-doctor install-net-ssleay --openssl-prefix "$(brew --prefix openssl@3)"
OPENSSL_PREFIX="$(brew --prefix openssl@3)" plenv ssl-doctor install-net-ssleay
```

Automatic discovery considers Homebrew `openssl@3`, then Homebrew `openssl`,
then the prefix returned by an already available `Crypt::OpenSSL::Guess`, in
that order. Invalid automatic candidates are skipped. Paths are canonicalized
and duplicate symlink targets are deduplicated. Candidates are ranked by
compatibility with the requested release: `KNOWN_SUPPORTED`, then `UNKNOWN`,
then `KNOWN_INCOMPATIBLE`, preserving discovery order within each rank. An
explicit prefix remains authoritative even if another candidate ranks higher.
If none is valid and Guess is unavailable, the installation command installs
Guess via cpanm and retries discovery. If Guess is already available but yields
no valid candidate, the command fails instead of reinstalling it. A valid
explicit or Homebrew candidate does not require installing Guess.

Each candidate must be an existing absolute directory without newline, carriage
return, or tab characters. Its executable `bin/openssl version` must succeed
and output a recognized OpenSSL version, `include/openssl/ssl.h` must be
readable, and both ssl and crypto libraries must be readable, nonempty files in
`lib` or `lib64` (conventional static or shared library names are accepted).
The selected canonical prefix, version, source, and selection reason are
printed to stderr for an installation. Validation establishes availability,
not compatibility with a particular Net::SSLeay release.

To evaluate and request an exact CPAN release for a new installation, use for
example:

```sh
plenv ssl-doctor install-net-ssleay --net-ssleay-version 1.96
plenv ssl-doctor install-net-ssleay --net-ssleay-version 1.97_01 --openssl-prefix "$(brew --prefix openssl@3)"
```

The installer requests `Net::SSLeay@VERSION` from cpanm and verifies that the
selected Perl loads exactly that version afterward. An underscore version also
passes `--dev` to enable developer-release lookup; the configured cpanm and
CPAN source must be able to resolve it. A loadable existing module is never
silently replaced, even if another version was requested.

Without a version option, the target is unknown until cpanm resolves it during
installation. The plugin makes no metadata query to predict it, reports
`UNKNOWN`, warns, and attempts the build. An installed module's version
identifies the current environment, not a future target.

The selected pair's status and reason are reported before the build:

- `KNOWN_SUPPORTED`: the version-scoped rules have evidence of support.
- `KNOWN_INCOMPATIBLE`: the rules identify an incompatibility; the command exits
  **1** before building Net::SSLeay, including for an explicit prefix.
- `UNKNOWN`: no rule establishes either result; the command warns and attempts
  the build. It does not imply that the pair is incompatible.

See the [compatibility rules and evidence](docs/net-ssleay-compatibility.md),
including [upstream PR #553](https://github.com/radiator-software/p5-net-ssleay/pull/553)
and the [OpenSSL versioning policy](https://openssl-library.org/policies/general/versioning-policy/#patch-release).
For example, the rules distinguish Net::SSLeay 1.96 with OpenSSL 4.0.x from
1.97_01 with OpenSSL 4.0.x; they do not reject OpenSSL 4 as a whole. Support
is evidence about a release pair, not a guarantee that a particular compiler,
architecture, downstream patches, headers, or libraries will build successfully.

Exit behavior and remaining limitations:

- A missing module and a broken installed module both enter the installation
  path; the initial load error is suppressed.
- Missing or rejected cpanm, or no valid automatic candidate, exits **1**.
- An installer failure preserves its nonzero status and prints build-log hints.
- After installer success, a missing or unloadable Net::SSLeay exits **1**, with
  the load error and build-log hints. Only a successful load produces the
  congratulations message and exits **0**. No minimum Net::SSLeay version or
  real TLS connection is checked.

To inspect the installed module version separately:

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
- Missing or rejected cpanm exits **1** before installation; missing cpanm
  recommends `plenv install-cpanm`.
- Installer failure preserves its nonzero status. After installer success, a
  module that fails to load or satisfy 1.42 exits **1**; otherwise exit **0**.
  Installer and post-install verification failures include build-log hints.

Version checks use Perl's `VERSION` method, including for dotted versions.
The internal missing-module status 2 selects installation; it is not the public
status for a missing module after failed verification.

### Check IO::Socket::SSL

```sh
plenv ssl-doctor check-io-socket-ssl
```

Print the installed version and exit **0** when the module loads. A missing or
unloadable module produces a generic missing-module message and exits **1**;
the underlying load error is suppressed. A failure to query the version after
a successful initial load also exits **1**. This command does **not** check the
1.42 minimum, make an HTTPS request, or validate certificates.

## OpenSSL discovery and compatibility

Automatic discovery can use [Crypt::OpenSSL::Guess](https://github.com/akiym/Crypt-OpenSSL-Guess)
as a fallback. Finding a prefix does not prove that a Net::SSLeay release can
compile against those headers and libraries. The version-scoped compatibility
rules described above provide evidence, not a guarantee of a successful build.

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

`brew --prefix` alone can print a path even when the formula is not installed;
it is not installation evidence. The version command checks the executable,
while the plugin also validates headers and libraries. These commands inspect a
candidate; they do not select it for the installer.

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

Read cpanm's reported `build.log` location. On installer or post-install load
failures, the plugin also suggests inspecting work directories under
`${PERL_CPANM_HOME:-$HOME/.cpanm}/work/`; it does not search or read those logs
automatically. Record the exact distribution version,
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
to control the build, then verify the module and runtime library. The explicit
OpenSSL 3 selection examples above can select a prefix for a new installation;
an already loadable Net::SSLeay is not automatically rebuilt. Confirm the chosen
prefix in the build log. Do not remove a working installation merely because
this command suggests uninstalling it.

## Contributing and offline tests

From the repository root, run:

```sh
bash -n bin/plenv-ssl-doctor
shellcheck bin/plenv-ssl-doctor
prove -v t
```

ShellCheck is an additional lint dependency; the Perl regression tests require
no CPAN installations. To run a focused suite, use for example
`prove -v t/installation-environment.t`.

The test files use temporary module fixtures and fake executables, with
isolated module lookup and executable paths. Tests do not access the network,
install CPAN modules, run real builds, or change your Perl/OpenSSL installation.
They cover IO::Socket::SSL missing/current/old/dotted versions and load errors,
Perl/cpanm selection, explicit and automatic OpenSSL selection, Guess and
installer failures, prefix validation and deduplication, compatibility ranking
and version boundaries, post-install load and requested-version checks, and test-helper isolation/output capture. They do
not establish compatibility with real OpenSSL libraries or test every possible
wrapper or platform.

Use the shared `t/lib/DoctorTest.pm` helper for new fixture-based tests; see its
embedded usage documentation and `t/test-helper.t`. `DoctorTest->new` creates a
temporary fixture; `module`, `executable`, and `write_file` populate it. Pass
`run(command => [executable, argument, ...], env => { ... })` an argument array,
not a shell command string. Assert both `exit` and `signal` (or raw `status`)
so signal termination cannot appear successful. The helper isolates PATH and
Perl module lookup, removes inherited startup hooks, and captures stdout and
stderr separately. Fake commands must use shell builtins or explicit absolute
paths; no real installer is supplied. The interpreter-discovery fixture also
preserves isolation when the script subsequently pins its Perl path.

The [CI workflow](.github/workflows/ci.yml) runs Bash syntax checks, ShellCheck,
and `prove -v t` on Ubuntu for pull requests, pushes to master, and manual
workflow runs. The regression tests themselves are offline; CI setup checks
out the repository and installs ShellCheck using the runner's package manager.

Keep user-facing messages and documentation in English. Add offline coverage
for behavior changes; avoid modifying the developer's Perl or OpenSSL during
tests. Include the command, exit status, selected interpreter/installer paths,
exact versions, and relevant redacted errors in bug reports.

General diagnostics (#5) are not yet implemented; this README documents the
current implementation.

## Author

OGATA Tetsuji <tetsuji.ogata@gmail.com>

## License

MIT License.
