use strict;
use warnings;
use Test::More;
use Cwd qw(abs_path);
use File::Find qw(find);
use FindBin;
use lib "$FindBin::Bin/lib";
use DoctorTest;

my $script = "$FindBin::Bin/../bin/plenv-ssl-doctor";
my $ssleay = <<'PERL';
package Net::SSLeay;
our $VERSION = '1.96';
sub OpenSSL_version { die 'expected runtime version selector' unless $_[0] == 0; 'OpenSSL 3.5.2 (loaded)' }
1;
PERL
my $io_socket_ssl = 'package IO::Socket::SSL; our $VERSION = "2.099"; 1;';

sub fixture {
    my $f = DoctorTest->new;
    $f->module('Net::SSLeay', $ssleay);
    $f->module('IO::Socket::SSL', $io_socket_ssl);
    $f->module('HTTP::Tiny', <<'PERL');
package HTTP::Tiny;
our $VERSION = '0.096';
sub new {
    my ($class, %args) = @_;
    my $tls = $args{SSL_options};
    die 'TLS verification must be explicit' unless $args{verify_SSL} == 1
        && $tls->{SSL_verify_mode} == 1 && $tls->{SSL_verifycn_scheme} eq 'http'
        && $tls->{SSL_verifycn_name} eq 'www.cpan.org';
    die 'client must ignore proxy env' if grep { !exists $args{$_} || defined $args{$_} }
        qw(proxy http_proxy https_proxy);
    die 'timeout or redirects' unless $args{timeout} == 10 && $args{max_redirect} == 0;
    return bless {}, $class;
}
sub can_ssl {
    return (0, "Couldn't find a CA bundle") if $ENV{PROBE_MODE} eq 'no-ca';
    return (0, 'missing TLS modules') unless eval { require Net::SSLeay; require IO::Socket::SSL; 1 };
    return (1, '');
}
sub head {
    my ($self, $url) = @_;
    open my $fh, '>>', "$ENV{HOME}/network" or die $!;
    print {$fh} "HEAD $url\n";
    close $fh or die $!;
    die 'unexpected endpoint' unless $url eq 'https://www.cpan.org/';
    if ($ENV{PROBE_MODE} eq 'deadline') {
        kill 'ALRM', $$;
        die 'alarm handler did not run';
    }
    die 'no total timeout' unless alarm(0) > 0;
    return { status => 503, reason => 'secret-probe-value', content => '' }
        if $ENV{PROBE_MODE} eq 'http';
    return { status => 404, reason => 'Not Found', content => '' }
        if $ENV{PROBE_MODE} eq 'http-404';
    return { status => 599, reason => 'Internal Exception', content => '' }
        if $ENV{PROBE_MODE} eq 'actual-599';
    my %failure = (
        certificate => 'SSL connect attempt failed: certificate verify failed',
        hostname    => 'hostname verification failed',
        dns         => 'Could not resolve host',
        network     => 'Connection refused',
        timeout     => 'Timed out while waiting for socket',
        ambiguous   => 'SSL connect attempt failed: protocol error',
    );
    die 'unexpected network call' unless exists $failure{$ENV{PROBE_MODE}};
    return {
        status => 599, reason => 'Internal Exception',
        content => "$failure{$ENV{PROBE_MODE}} (secret-probe-value)",
    };
}
1;
PERL
    $f->executable('cpanm', <<'PERL');
#!/usr/bin/env perl
open my $fh, '>>', "$ENV{HOME}/installer" or die $!;
print {$fh} "cpanm\n";
die 'unexpected install';
PERL
    for my $name (qw(curl wget openssl)) {
        $f->executable($name, <<'SH');
#!/bin/sh
printf '%s\n' "$0" >> "$HOME/unexpected-command"
exit 97
SH
    }
    return $f;
}

sub prefix {
    my ($f, $directory, $version) = @_;
    my $openssl = $f->write_file("$directory/bin/openssl", "#!/bin/sh\nprintf '%s\\n' '$version'\n");
    chmod 0755, $openssl or die $!;
    $f->write_file("$directory/include/openssl/ssl.h", 'ssl fixture');
    $f->write_file("$directory/lib/libssl.a", 'ssl fixture');
    $f->write_file("$directory/lib/libcrypto.a", 'crypto fixture');
    return abs_path($f->path($directory));
}

sub run_doctor {
    my ($f, $env, @args) = @_;
    return $f->run(
        command => ['/bin/bash', $script, @args ? @args : ('check')],
        env => {
            OPENSSL_PREFIX => undef, PLENV_VERSION => undef, PROBE_MODE => 'offline',
            HTTP_TINY_SSL_INSECURE_BY_DEFAULT => 1,
            HTTPS_PROXY => 'http://secret-probe-value@example.invalid:80',
            DOCTOR_SECRET => 'secret-probe-value',
            %{$env || {}},
        },
    );
}

sub expect_exit {
    my ($r, $exit) = @_;
    is $r->{exit}, $exit, "exit $exit";
    is $r->{signal}, 0, 'exited without a signal';
    unlike $r->{stdout} . $r->{stderr}, qr/secret-probe-value/, 'no secret in diagnostics';
}

sub snapshot {
    my ($f) = @_;
    my %files;
    my $root = $f->path('');
    find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        my $relative = substr($_, length $root);
        $files{$relative} = $f->read_file($relative);
    }}, $root);
    return \%files;
}

subtest 'offline checks keep loaded and build OpenSSL separate' => sub {
    my $f = fixture();
    my $three = prefix($f, 'OpenSSL 3', 'OpenSSL 3.6.0 (build)');
    my $four = prefix($f, 'OpenSSL 4', 'OpenSSL 4.0.3 (build)');
    $f->executable('brew', <<'SH');
#!/bin/sh
[ "$1" = --prefix ] || exit 8
case "$2" in
    openssl@3) printf '%s' "$BREW_THREE" ;;
    openssl) printf '%s' "$BREW_OTHER" ;;
    *) exit 9 ;;
esac
SH
    my $before = snapshot($f);
    my $env = { BREW_THREE => $three, BREW_OTHER => $four, PLENV_VERSION => '5.44.0' };
    my $r = run_doctor($f, $env);
    expect_exit($r, 0);
    is_deeply run_doctor($f, $env), $r, 'same fixture produces the same output and status';
    my $perl = $f->path('bin/perl');
    like $r->{stderr}, qr/^Selected Perl: \Q$perl\E \(version [\d.]+\)$/m, 'selected path and version';
    like $r->{stdout}, qr/PLENV_VERSION=5\.44\.0; perl command=\Q$perl\E/, 'narrow plenv context';
    like $r->{stdout}, qr/Net::SSLeay: loadable \(version 1\.96\)/, 'Net::SSLeay version';
    like $r->{stdout}, qr/IO::Socket::SSL: loadable \(version 2\.099\)/, 'IO::Socket::SSL version';
    like $r->{stdout}, qr/^Loaded OpenSSL \(Net::SSLeay\): OpenSSL 3\.5\.2 \(loaded\)$/m, 'runtime version from module';
    like $r->{stdout}, qr/future builds:\n  \Q$three\E \(OpenSSL 3\.6\.0 \(build\), source: homebrew:openssl\@3\)/, 'first build candidate';
    like $r->{stdout}, qr/\Q$four\E \(OpenSSL 4\.0\.3 \(build\), source: homebrew:openssl\)/, 'second build candidate';
    my @warnings = $r->{stdout} =~ /Compatibility: UNKNOWN\. Net::SSLeay target version is unknown\./g;
    is scalar @warnings, 2, 'compatibility uses an unknown install target for both candidates';
    like $r->{stdout}, qr/Local HTTPS .*: available/, 'local capability reported';
    ok !-e $f->path($_), "$_ not invoked" for qw(network installer unexpected-command);
    is_deeply snapshot($f), $before, 'no persistent fixture-state changes';
};

subtest 'missing, broken, and legacy module checks' => sub {
    my $f = fixture();
    my $legacy = run_doctor($f, {}, 'check-io-socket-ssl');
    expect_exit($legacy, 0);
    is $legacy->{stdout}, "2.099\n", 'legacy stdout contains only version';

    unlink $f->path('lib/Net/SSLeay.pm'), $f->path('lib/IO/Socket/SSL.pm');
    my $r = run_doctor($f, {});
    expect_exit($r, 1);
    like $r->{stdout}, qr/Error: Net::SSLeay: missing/, 'Net::SSLeay is missing';
    like $r->{stdout}, qr/Error: IO::Socket::SSL: missing/, 'IO::Socket::SSL is missing';
    like $r->{stdout}, qr/Error: local HTTPS unavailable/, 'local HTTPS failed';

    $f->module('Net::SSLeay', <<'PERL');
package Net::SSLeay;
our $VERSION = '1.96';
die "Can't load XS library: secret-probe-value\n";
PERL
    $f->module('IO::Socket::SSL', 'package IO::Socket::SSL; require Missing::Dependency; 1;');
    $r = run_doctor($f, {}, 'check', '--online');
    expect_exit($r, 1);
    like $r->{stdout}, qr/Net::SSLeay: broken \(version 1\.96, XS or shared library load failure\)/, 'XS load failure';
    like $r->{stdout}, qr/IO::Socket::SSL: broken \(version unknown, missing dependency Missing\/Dependency\.pm\)/, 'dependency failure';
    like $r->{stdout}, qr/Online HTTPS: skipped/, 'skip network when modules fail';
    ok !-e $f->path($_), "$_ not invoked" for qw(network installer);
    for my $kind ('broken', 'missing') {
        $legacy = run_doctor($f, {}, 'check-io-socket-ssl');
        expect_exit($legacy, 1);
        is $legacy->{stdout}, '', "legacy $kind stdout remains empty";
        like $legacy->{stderr}, qr/It seems that IO::Socket::SSL is not installed/, "legacy $kind message";
        unlink $f->path('lib/IO/Socket/SSL.pm');
    }
};

subtest 'optional discovery and runtime reporting' => sub {
    my $f = fixture();
    $f->module('Net::SSLeay', 'package Net::SSLeay; our $VERSION = "1.96"; 1;');
    my $r = run_doctor($f, {});
    expect_exit($r, 0);
    like $r->{stdout}, qr/Warning: loaded OpenSSL version unavailable/, 'missing runtime API is optional';
    like $r->{stdout}, qr/Warning: no OpenSSL candidates/, 'no candidate is optional';
    like $r->{stdout}, qr/Warning: Crypt::OpenSSL::Guess: missing/, 'missing optional Guess';
    $f->module('Net::SSLeay', 'package Net::SSLeay; sub SSLeay_version { "OpenSSL 1.1.1w" } 1;');
    $f->module('Crypt::OpenSSL::Guess', 'package Crypt::OpenSSL::Guess; die "broken";');
    $f->executable('brew', "#!/bin/sh\nexit 7\n");
    $r = run_doctor($f, {});
    expect_exit($r, 0);
    like $r->{stdout}, qr/Warning: Crypt::OpenSSL::Guess: broken/, 'broken optional Guess';
    like $r->{stdout}, qr/Loaded OpenSSL .*: OpenSSL 1\.1\.1w/, 'legacy runtime API fallback';
    $f->module('Crypt::OpenSSL::Guess', <<'PERL');
package Crypt::OpenSSL::Guess;
sub import { *main::find_openssl_prefix = sub { $ENV{GUESS_PREFIX} // die "cannot guess" } }
1;
PERL
    $r = run_doctor($f, { GUESS_PREFIX => undef });
    expect_exit($r, 0);
    like $r->{stderr}, qr/Cannot query Crypt::OpenSSL::Guess/, 'optional Guess query failure';
    my $dir = prefix($f, 'guessed', 'OpenSSL 3.6.0');
    $r = run_doctor($f, { GUESS_PREFIX => $dir });
    expect_exit($r, 0);
    like $r->{stdout}, qr/\Q$dir\E \(OpenSSL 3\.6\.0, source: guess\)/, 'existing Guess discovery works';
    ok !-e $f->path('installer'), 'no automatic recovery via cpanm';
};

subtest 'honor explicit prefix and discovery status' => sub {
    my $f = fixture();
    my $dir = prefix($f, 'explicit', 'OpenSSL 4.0.3');
    my $r = run_doctor($f, { OPENSSL_PREFIX => $dir });
    expect_exit($r, 0);
    like $r->{stdout}, qr/\Q$dir\E \(OpenSSL 4\.0\.3, source: environment\)/, 'explicit environment candidate';
    $r = run_doctor($f, { OPENSSL_PREFIX => '' }, 'check', '--online');
    expect_exit($r, 2);
    like $r->{stderr}, qr/Error: invalid OPENSSL_PREFIX/, 'invalid explicit input is an error';
    unlike $r->{stdout}, qr/Warning: no OpenSSL candidates/, 'explicit invalidity does not fall back';
    ok !-e $f->path('network'), 'invalid input does not reach the network';
};

subtest 'local HTTPS capability required' => sub {
    my $f = fixture();
    my $r = run_doctor($f, { PROBE_MODE => 'no-ca' }, 'check', '--online');
    expect_exit($r, 1);
    like $r->{stdout}, qr/Check the CA trust store/, 'can_ssl CA failure is actionable';
    ok !-e $f->path('network'), 'no HTTP request when can_ssl fails';
    unlink $f->path('lib/HTTP/Tiny.pm');
    $r = run_doctor($f, {});
    expect_exit($r, 1);
    like $r->{stdout}, qr/Error: HTTP::Tiny: missing/, 'missing HTTP::Tiny is a required check failure';
};

subtest 'online response and failure classes' => sub {
    my @cases = (
        [http          => 0, qr/HTTP response 503 received/],
        ['http-404'    => 0, qr/HTTP response 404 received/],
        ['actual-599'  => 0, qr/HTTP response 599 received/],
        [certificate   => 1, qr/certificate or hostname verification failed/],
        [hostname      => 1, qr/certificate or hostname verification failed/],
        [dns           => 1, qr/DNS\/network failure/],
        [network       => 1, qr/DNS\/network failure/],
        [timeout       => 1, qr/DNS\/network failure \(timed out\)/],
        [deadline      => 1, qr/DNS\/network failure \(timed out\)/],
        [ambiguous     => 1, qr/failed before receiving an HTTP response/],
    );
    for my $case (@cases) {
        my ($mode, $status, $pattern) = @$case;
        subtest $mode => sub {
            my $f = fixture();
            my $r = run_doctor($f, { PROBE_MODE => $mode }, '--online', 'check');
            expect_exit($r, $status);
            like $r->{stdout}, qr/certificate and hostname verification enabled/, 'verification announced';
            like $r->{stdout}, $pattern, 'outcome classified';
            is $f->read_file('network'), "HEAD https://www.cpan.org/\n", 'one mocked HEAD to fixed endpoint';
            ok !-e $f->path('installer'), 'no installer';
        };
    }
};

subtest 'command-line validation and Perl selection' => sub {
    my $f = fixture();
    for my $args (
        [qw(check --openssl-prefix /example)],
        [qw(check --net-ssleay-version 1.96)],
        [qw(check-io-socket-ssl --online)],
        [qw(install-io-socket-ssl --online)],
        [qw(install-net-ssleay --online)],
        [qw(check --onlin)],
        [qw(check --online https://example.invalid)],
    ) {
        my $r = run_doctor($f, {}, @$args);
        expect_exit($r, 2);
        unlike $r->{stderr}, qr/Selected Perl/, 'invalid options rejected before selection';
    }
    my $usage = $f->run(command => ['/bin/bash', $script]);
    expect_exit($usage, 0);
    like $usage->{stdout}, qr/plenv ssl-doctor check \[--online\]/, 'usage includes diagnostics';
    unlink $f->path('bin/perl');
    my $r = run_doctor($f, {}, 'check', '--online');
    expect_exit($r, 1);
    like $r->{stderr}, qr/Cannot discover the selected Perl/, 'selected Perl required';
    ok !-e $f->path('network'), 'invalid invocations do not reach the network';
};

done_testing;
