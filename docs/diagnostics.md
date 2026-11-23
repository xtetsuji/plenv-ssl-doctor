# Diagnose HTTPS for the selected Perl

```sh
plenv ssl-doctor check
plenv ssl-doctor check --online
```

By default, `check` reads local state. It makes no HTTP requests, runs no
installer, and leaves the environment and installed modules unchanged. It
reports:

- The selected Perl's absolute path and version on stderr, followed by the
  `perl` command path and `PLENV_VERSION` value (if set) on stdout.
- Loadability and versions of `Net::SSLeay`, `IO::Socket::SSL`, and
  `HTTP::Tiny`. A module missing from the Perl search path is reported
  separately from a module that fails to load. If a broken module set its
  version before failing, the report includes that version.
- The runtime TLS library version reported by the loaded `Net::SSLeay`,
  using `OpenSSL_version(0)` or `SSLeay_version(0)`.
- Available OpenSSL prefixes for future builds, including their versions and
  discovery sources. Discovery checks `OPENSSL_PREFIX` if set, or queries
  Homebrew and an already installed `Crypt::OpenSSL::Guess`. Candidate
  validation uses the same conventional `lib` and `lib64` layouts as the
  installer. Installations using other layouts, including some Linux
  multiarch paths, may yield no candidates.
- The result of the local `HTTP::Tiny->can_ssl` capability check, using an
  HTTPS client configured to verify TLS. This includes CA availability checks
  where supported by the installed `HTTP::Tiny`.

The installed TLS modules and local `HTTP::Tiny` HTTPS capability are required
checks. A missing or broken discovery helper, no automatic build candidate, or
unavailable runtime version metadata can produce a `Warning:` line with a
successful exit. Check output distinguishes the running library from the
development files available for a future build. Build compatibility is
`UNKNOWN` because its target comes from a future Net::SSLeay install.
See [Net::SSLeay build compatibility](net-ssleay-compatibility.md).

## Online probe

When the local required checks pass, `--online` issues a HEAD request to
`https://www.cpan.org/`. It uses a 10-second timeout, follows zero redirects,
and disables proxy environment settings for this request. Certificate chain and
hostname verification are explicitly enabled, including when
`HTTP_TINY_SSL_INSECURE_BY_DEFAULT` is set.

The probe prints the numeric HTTP status for a received response. HTTP 4xx and
5xx responses count as success for TLS and HTTP connectivity, independent of
the endpoint's health. If there is no HTTP response, the probe reports
certificate or hostname verification failures and DNS or network failures when
the available error text supports that classification. Ambiguous failures get
a general connection error. It omits raw exception text, request headers, and
response contents.

## Exit status

| Status | Meaning |
| --- | --- |
| `0` | All required local checks passed. If `--online` was supplied, the probe also received an HTTP response. |
| `1` | The selected Perl, a required module, or local HTTPS capability check failed, or the requested online probe failed to receive an HTTP response. |
| `2` | Invalid arguments to `check` or an invalid explicit `OPENSSL_PREFIX`, including an empty value. |

`--online` is accepted before or after `check`. The installer options
`--openssl-prefix` and `--net-ssleay-version` are reserved for
`install-net-ssleay`. Scripts that depend on the original version-only output
can continue to use `plenv ssl-doctor check-io-socket-ssl`.
