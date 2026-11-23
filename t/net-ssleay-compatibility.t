use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use DoctorTest;
use Cwd qw(abs_path);

my $script = abs_path("$FindBin::Bin/../bin/plenv-ssl-doctor");

subtest 'offline evaluator and version boundaries' => sub {
    my $f = DoctorTest->new;
    for my $case (
        ['1.96', 'OpenSSL 4.0.0', 'KNOWN_INCOMPATIBLE'],
        ['1.96', 'OpenSSL 4.0.3 (Library: OpenSSL 4.0.3)', 'KNOWN_INCOMPATIBLE'],
        ['1.96', 'OpenSSL 3.0.0', 'KNOWN_SUPPORTED'],
        ['1.96', 'OpenSSL 3.6.5', 'KNOWN_SUPPORTED'],
        ['1.97_01', 'OpenSSL 3.5.0', 'KNOWN_SUPPORTED'],
        ['1.97_01', 'OpenSSL 4.0.0', 'KNOWN_SUPPORTED'],
        ['1.97_01', 'OpenSSL 4.0.3 29 Sep 2026', 'KNOWN_SUPPORTED'],
        ['1.96', 'OpenSSL 3.7.0', 'UNKNOWN'],
        ['1.96', 'OpenSSL 4.1.0', 'UNKNOWN'],
        ['1.96', 'OpenSSL 5.0.0', 'UNKNOWN'],
        ['1.96', 'OpenSSL 4.0.0-beta1', 'UNKNOWN'],
        ['1.96', 'OpenSSL 4.0.3 (Library: OpenSSL 4.0.2)', 'UNKNOWN'],
        ['1.96', 'OpenSSL 4.0.3 (Library: OpenSSL 4x0x3)', 'UNKNOWN'],
        ['1.96', 'LibreSSL 4.0.3', 'UNKNOWN'],
        ['1.97_01', 'OpenSSL 4.1.0', 'UNKNOWN'],
        ['1.97_02', 'OpenSSL 4.0.3', 'UNKNOWN'],
        ['', 'OpenSSL 4.0.3', 'UNKNOWN'],
    ) {
        my ($target, $version, $status) = @$case;
        my $r = $f->run(command => ['/bin/bash', '-c', <<'SH', 'test', $script, $target, $version]);
source "$1"
evaluate-net-ssleay-compatibility "$2" "$3"
printf '%s\n%s\n' "$COMPATIBILITY_STATUS" "$COMPATIBILITY_REASON"
SH
        is $r->{status}, 0, 'evaluation succeeds';
        like $r->{stdout}, qr/\A$status\n[^\n]+\n\z/, "Net::SSLeay '$target' and $version";
        is $r->{stderr}, '', 'no external diagnostics';
    }
};

sub fixture {
    my $f = DoctorTest->new;
    $f->write_file('calls', '');
    $f->write_file('lib/Net/.keep', '');
    $f->executable('brew', <<'SH');
#!/bin/sh
case "$2" in
    openssl@3) printf '%s' "${BREW_FIRST:-}" ;;
    openssl) printf '%s' "${BREW_SECOND:-}" ;;
    *) exit 1 ;;
esac
SH
    $f->executable('cpanm', <<'PERL_SCRIPT');
#!/usr/bin/env perl
open my $log, '>>', "$ENV{HOME}/calls" or die $!;
print {$log} join('|', @ARGV, $ENV{OPENSSL_PREFIX} // ''), "\n";
close $log or die $!;
exit $ENV{BUILD_EXIT} if $ENV{BUILD_EXIT};
my ($version) = $ARGV[-1] =~ /\ANet::SSLeay\@([\d._]+)\z/;
$version = $ENV{BUILT_VERSION} // $version // '1.96';
open my $mod, '>', "$ENV{DOCTOR_TEST_LIB}/Net/SSLeay.pm" or die $!;
print {$mod} "package Net::SSLeay; \$VERSION = '$version'; 1;";
close $mod or die $!;
PERL_SCRIPT
    return $f;
}

sub prefix {
    my ($f, $version) = @_;
    my $name = "OpenSSL $version";
    my $openssl = $f->write_file("$name/bin/openssl", "#!/bin/sh\nprintf '%s\\n' 'OpenSSL $version'\n");
    chmod 0755, $openssl or die $!;
    $f->write_file("$name/$_", 'fixture') for qw(include/openssl/ssl.h lib/libssl.a lib/libcrypto.a);
    return abs_path($f->path($name));
}

sub install {
    my ($f, $env, @args) = @_;
    return $f->run(command => ['/bin/bash', $script, 'install-net-ssleay', @args],
        env => { OPENSSL_PREFIX => undef, BREW_FIRST => undef, BREW_SECOND => undef,
            BUILD_EXIT => undef, BUILT_VERSION => undef, %$env });
}

subtest 'explicit incompatible prefix is reported and preserved' => sub {
    for my $source ('cli', 'environment') {
        my $f = fixture();
        my $four = prefix($f, '4.0.3');
        my $three = prefix($f, '3.6.0');
        my @override = $source eq 'cli' ? ('--openssl-prefix', $four) : ();
        my $r = install($f, { OPENSSL_PREFIX => $source eq 'cli' ? $three : $four,
            BREW_FIRST => $three }, @override, '--net-ssleay-version', '1.96');
        is $r->{exit}, 1, "$source incompatibility fails before build";
        like $r->{stderr}, qr/Selected OpenSSL: \Q$four\E\n.*OpenSSL source: $source; reason: explicit /s,
            'explicit selection is visible';
        like $r->{stderr}, qr/target version: 1\.96\nCompatibility: KNOWN_INCOMPATIBLE.*ASN\.1/s,
            'diagnosis identifies target and reason';
        like $r->{stderr}, qr/Choose a compatible --openssl-prefix PATH/, 'diagnosis gives a next step';
        is $f->read_file('calls'), '', 'no fallback build or other installer calls';
    }
};

subtest 'automatic selection ranks supported above unknown and incompatible' => sub {
    for my $first ('4.0.3', '4.1.0') {
        my $f = fixture();
        my $early = prefix($f, $first);
        my $three = prefix($f, '3.6.0');
        my $r = install($f, { BREW_FIRST => $early, BREW_SECOND => $three }, '--net-ssleay-version', '1.96');
        is $r->{status}, 0, 'supported candidate builds';
        like $r->{stderr}, qr/Selected OpenSSL: \Q$three\E\n.*reason: first automatic candidate with known support/s,
            'later supported candidate selected and explained';
        like $r->{stderr}, qr/Compatibility: KNOWN_SUPPORTED/, 'known support reported';
        is $f->read_file('calls'), "Net::SSLeay\@1.96|$three\n", 'same target pinned for the build';
    }
};

subtest 'automatic selection ranks unknown above incompatible' => sub {
    my $f = fixture();
    my $bad = prefix($f, '4.0.3');
    my $unknown = prefix($f, '4.1.0');
    my $r = install($f, { BREW_FIRST => $bad, BREW_SECOND => $unknown, BUILD_EXIT => 17 },
        '--net-ssleay-version', '1.96');
    is $r->{exit}, 17, 'build status preserved';
    like $r->{stderr}, qr/Selected OpenSSL: \Q$unknown\E\n.*reason: first automatic candidate without a known incompatibility/s,
        'unknown combination preferred to known failure';
    like $r->{stderr}, qr/Warning: compatibility UNKNOWN.*cpanm failed for Net::SSLeay\@1\.96 \(exit 17\)/s,
        'warning precedes actionable build failure';
    is $f->read_file('calls'), "Net::SSLeay\@1.96|$unknown\n", 'unknown candidate attempted once';

    $f->write_file('calls', '');
    $r = install($f, { BREW_FIRST => $bad }, '--net-ssleay-version', '1.96');
    is $r->{exit}, 1, 'an exclusively incompatible automatic selection fails';
    like $r->{stderr}, qr/reason: all automatic candidates are known incompatible/, 'failure reason reported';
    is $f->read_file('calls'), '', 'no known-incompatible build';
};

subtest 'developer release supports OpenSSL 4 and must load at the requested version' => sub {
    for my $built ('1.97_01', '1.96') {
        my $f = fixture();
        my $four = prefix($f, '4.0.3');
        my $r = install($f, { OPENSSL_PREFIX => $four, BUILT_VERSION => $built },
            '--net-ssleay-version', '1.97_01');
        like $r->{stderr}, qr/Compatibility: KNOWN_SUPPORTED/, 'OpenSSL 4 support reported';
        is $f->read_file('calls'), "--dev|Net::SSLeay\@1.97_01|$four\n", 'exact developer release requested';
        if ($built eq '1.97_01') {
            is $r->{status}, 0, 'supported developer release builds';
            like $r->{stdout}, qr/Congratulations!/, 'success reported after verification';
        } else {
            is $r->{exit}, 1, 'different loaded version fails verification';
            like $r->{stderr}, qr/Requested Net::SSLeay 1\.97_01 but the selected Perl reports 1\.96/,
                'version mismatch explained';
            unlike $r->{stdout}, qr/Congratulations!/, 'no unverified success';
        }
    }
};

subtest 'installed and target versions are independent' => sub {
    my $f = fixture();
    my $four = prefix($f, '4.0.3');
    $f->module('Net::SSLeay', q{package Net::SSLeay; $VERSION = '1.96'; 1;});
    my $r = install($f, { OPENSSL_PREFIX => $four });
    is $r->{status}, 0, 'existing loadable module still skips installation';
    like $r->{stderr}, qr/Installed Net::SSLeay version: 1\.96/, 'installed version is identified';
    unlike $r->{stderr}, qr/Net::SSLeay target version:|KNOWN_INCOMPATIBLE/, 'installed version is not used as a build target';

    $r = install($f, { OPENSSL_PREFIX => $four }, '--net-ssleay-version', '1.97_01');
    is $r->{exit}, 1, 'different pinned version cannot silently reuse installed module';
    like $r->{stderr}, qr/Requested Net::SSLeay 1\.97_01 was not installed/, 'requested version reported separately';
    is $f->read_file('calls'), '', 'loadable module is never replaced';

    $f->module('Net::SSLeay', q{package Net::SSLeay; $VERSION = '1.96'; die "fixture XS load error";});
    $r = install($f, { OPENSSL_PREFIX => $four, BUILT_VERSION => '1.97_01' });
    is $r->{status}, 0, 'unresolved distribution is allowed to build';
    like $r->{stderr}, qr/Net::SSLeay target version: unknown.*\nWarning: compatibility UNKNOWN/,
        'the broken local version does not determine the target';
    is $f->read_file('calls'), "Net::SSLeay|$four\n", 'no installer metadata query or implicit version pin';
};

subtest 'version option validates its command and argument' => sub {
    my $f = fixture();
    for my $args (['install-net-ssleay', '--net-ssleay-version'],
        ['install-net-ssleay', '--net-ssleay-version', '>= 1.96'],
        ['install-net-ssleay', '--net-ssleay-version', '--dev'],
        ['install-net-ssleay', '--net-ssleay-version', ''],
        ['install-io-socket-ssl', '--net-ssleay-version', '1.96']) {
        my $r = $f->run(command => ['/bin/bash', $script, @$args]);
        is $r->{exit}, 2, 'invalid option use returns 2';
        like $r->{stderr}, qr/--net-ssleay-version/, 'option named in error';
    }

    my $three = prefix($f, '3.6.0');
    my $r = $f->run(command => ['/bin/bash', $script, '--net-ssleay-version', '1.97_01',
        'install-net-ssleay', '--net-ssleay-version', '1.96'],
        env => { OPENSSL_PREFIX => $three });
    is $r->{status}, 0, 'option works before or after the command and last value wins';
    is $f->read_file('calls'), "Net::SSLeay\@1.96|$three\n", 'the last version is passed to cpanm';
};

done_testing;
