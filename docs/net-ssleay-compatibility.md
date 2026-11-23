# Net::SSLeay compatibility rules

To evaluate a specific CPAN release before building, pass its exact release
version.

```sh
plenv ssl-doctor install-net-ssleay --net-ssleay-version 1.96
plenv ssl-doctor install-net-ssleay --net-ssleay-version 1.97_01 --openssl-prefix /path/to/openssl
```

The installer requests that exact version through cpanm's `Net::SSLeay@VERSION`
syntax. An underscore version also enables cpanm's developer-release lookup.
The option requires a cpanm and CPAN source that can resolve the requested
release. A loadable module still prevents reinstallation. The installed version
is reported separately, and requesting a different version in that situation
returns an error. [cpanm documentation](https://metacpan.org/dist/App-cpanminus/view/bin/cpanm)

With no version option, cpanm resolves the distribution during installation.
Compatibility is then `UNKNOWN` and the installer warns and proceeds. The
compatibility evaluator does not query CPAN. A loaded module's version describes
the current environment. It does not identify a future cpanm target.

## Evidence behind the rules

| CPAN release | Stable OpenSSL release | Status and evidence |
| --- | --- | --- |
| 1.96 | 4.0.x | `KNOWN_INCOMPATIBLE`. Issue #4 reports the failure with 4.0.3. OpenSSL 4.0.0 made `ASN1_STRING` opaque. The 1.96 XS accesses that structure directly through `ASN1_TIME`, and also calls legacy TLS methods removed in 4.0. Upstream PR #553 replaces those uses. [Issue #4](https://github.com/xtetsuji/plenv-ssl-doctor/issues/4), [OpenSSL 4.0.0 changes](https://github.com/openssl/openssl/blob/openssl-4.0.0/CHANGES.md#changes-between-36-and-400-14-apr-2026), [Net::SSLeay 1.96 XS](https://github.com/radiator-software/p5-net-ssleay/blob/1.96/SSLeay.xs), [upstream PR #553](https://github.com/radiator-software/p5-net-ssleay/pull/553) |
| 1.96 and 1.97_01 | 3.0.x through 3.6.x | `KNOWN_SUPPORTED`. Both release READMEs list these stable OpenSSL series. [Net::SSLeay 1.96 README](https://github.com/radiator-software/p5-net-ssleay/blob/1.96/README), [Net::SSLeay 1.97_01 README](https://github.com/radiator-software/p5-net-ssleay/blob/1.97_01/README) |
| 1.97_01 | 4.0.x | `KNOWN_SUPPORTED`. This published developer release includes the 4.0.0 support changes. [Net::SSLeay 1.97_01 changes](https://metacpan.org/release/CHRISN/Net-SSLeay-1.97_01/changes), [upstream PR #553](https://github.com/radiator-software/p5-net-ssleay/pull/553) |

The 4.0.x boundaries infer continuity from 4.0.0 using OpenSSL's patch-level API
compatibility policy. These rules describe upstream distributions and API
compatibility evidence. Build settings, downstream patches, headers and
libraries under the prefix, and the local compiler can affect the actual
outcome. [OpenSSL versioning policy](https://openssl-library.org/policies/general/versioning-policy/#patch-release)

## Maintaining the rules

Review the release's Changes, tagged source, and applicable OpenSSL changes or
upstream tests before extending a rule. Record the version boundary and the
source in the table, then update `evaluate-net-ssleay-compatibility` in
`bin/plenv-ssl-doctor` and add fixtures to `t/net-ssleay-compatibility.t` for
matches and adjacent unverified releases. Keep combinations outside the
evidence at `UNKNOWN`, including development OpenSSL builds and newer minor
series until verified.

The evaluator takes a target release string (empty if unknown) and a full
`openssl version` line. It sets `COMPATIBILITY_STATUS` and
`COMPATIBILITY_REASON` without invoking external commands. The existing
`select-openssl-candidate` accepts the optional target release, sets
`SELECTED_COMPATIBILITY_STATUS` and `SELECTED_COMPATIBILITY_REASON`, and keeps
the existing selected prefix, version, source, index, and reason fields.
Selection prefers known support, then unknown combinations, then known
incompatible combinations, using discovery order within each status. Explicit
discovery yields a single candidate. The install command reports the selected
prefix and stops before building Net::SSLeay if compatibility is
`KNOWN_INCOMPATIBLE`.
