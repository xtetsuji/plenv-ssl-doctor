use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);

my $script = "$FindBin::Bin/../bin/plenv-ssl-doctor";
sub write_file {
    my ($path, $text, $mode) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh or die $!;
    chmod $mode, $path or die $! if $mode;
}
sub run_case {
    my (%args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/bin", "$dir/lib/Net", "$dir/lib/IO/Socket",
        "$dir/lib/Crypt/OpenSSL", "$dir/openssl prefix", "$dir/shims");
    write_file("$dir/lib/Isolation.pm", <<'PERL');
use strict;
use warnings;
@INC = ($ENV{TEST_LIB});
1;
PERL
    write_file("$dir/lib/Crypt/OpenSSL/Guess.pm", <<'PERL');
package Crypt::OpenSSL::Guess;
sub import { *main::find_openssl_prefix = sub {
    die "guess query failed\n" if $ENV{TEST_QUERY_FAIL};
    return $ENV{TEST_PREFIX};
} }
1;
PERL
    write_file("$dir/lib/Net/SSLeay.pm", 'package Net::SSLeay; 1;') if $args{existing};
    # This fake selected interpreter logs all invocations and intercepts discovery.
    write_file("$dir/bin/perl", <<'SH', 0755);
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_PERL_LOG"
if [ "$1" = '-e' ]; then
    case "$2" in
        'print $^X')
            [ "$TEST_DISCOVERY_FAIL" = 1 ] && exit 8
            printf '%s' "$TEST_SELECTED"
            exit 0 ;;
        'printf "%vd", $^V')
            [ "$TEST_VERSION_FAIL" = 1 ] && exit 9 ;;
    esac
fi
exec "$TEST_REAL_PERL" -I"$TEST_LIB" -MIsolation "$@"
SH
    my $cpanm = "$dir/bin/cpanm";
    unless ($args{no_cpanm}) {
        write_file($cpanm, (($args{same_perl} ? "#!$dir/bin/perl" : $args{shebang}) || '#!/usr/bin/env perl') . "\n" . <<'PERL', 0755);
open my $log, '>>', $ENV{TEST_CPANM_LOG} or die $!;
print {$log} "$ARGV[0]|", ($ENV{OPENSSL_PREFIX} || ''), "\n";
close $log or die $!;
exit 7 if $ARGV[0] eq $ENV{TEST_FAIL_MODULE};
if ($ARGV[0] eq 'Net::SSLeay' && !$ENV{TEST_NO_MODULE}) {
    open my $mod, '>', "$ENV{TEST_LIB}/Net/SSLeay.pm" or die $!;
    print {$mod} $ENV{TEST_BROKEN_MODULE} ? 'die "broken XS load\n";' : 'package Net::SSLeay; 1;';
    close $mod or die $!;
}
PERL
    }
    if ($args{shim}) {
        write_file("$dir/shims/cpanm", "#!/bin/sh\nexit 99\n", 0755);
        write_file("$dir/bin/plenv", <<'SH', 0755);
#!/bin/sh
[ "$1" = which ] && [ "$2" = cpanm ] || exit 98
[ "$TEST_PLENV_FAIL" = 1 ] && exit 6
printf '%s' "$TEST_CPANM"
SH
    }
    local %ENV = %ENV;
    delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PLENV_DEBUG BASH_ENV ENV)};
    @ENV{qw(TEST_REAL_PERL TEST_SELECTED TEST_LIB TEST_PERL_LOG TEST_CPANM_LOG TEST_CPANM)} =
        ($^X, "$dir/bin/perl", "$dir/lib", "$dir/perl.log", "$dir/cpanm.log", $cpanm);
    $ENV{PATH} = ($args{shim} ? "$dir/shims:" : '') . "$dir/bin";
    $ENV{PERL5OPT} = "-I$dir/lib -MIsolation";
    $ENV{TEST_SELECTED} = $args{selected} if exists $args{selected};
    $ENV{TEST_PREFIX} = exists $args{prefix} ? $args{prefix} : "$dir/openssl prefix";
    $ENV{TEST_FAIL_MODULE} = $args{fail_module} || '';
    for my $pair ([TEST_DISCOVERY_FAIL => 'discovery_fail'], [TEST_VERSION_FAIL => 'version_fail'],
        [TEST_QUERY_FAIL => 'query_fail'], [TEST_NO_MODULE => 'no_module'],
        [TEST_BROKEN_MODULE => 'broken_module'], [TEST_PLENV_FAIL => 'plenv_fail']) {
        $ENV{$pair->[0]} = $args{$pair->[1]} || 0;
    }
    $ENV{PLENV_DEBUG} = 1 if $args{debug};
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, '/bin/bash', $script,
        $args{command} || 'install-net-ssleay');
    close $in;
    my $selector = IO::Select->new($out, $err);
    my %captured;
    while (my @ready = $selector->can_read) {
        for my $fh (@ready) {
            my $n = sysread($fh, my $chunk, 8192);
            die $! unless defined $n;
            if ($n) { $captured{fileno $fh} .= $chunk }
            else { $selector->remove($fh) }
        }
    }
    waitpid $pid, 0;
    my $status = $? >> 8;
    my @logs;
    for my $name ('cpanm', 'perl') {
        my $text = '';
        if (open my $log, '<', "$dir/$name.log") { local $/; $text = <$log>; close $log }
        push @logs, $text;
    }
    return ($status, $captured{fileno $out} || '', $captured{fileno $err} || '', @logs);
}

for my $args ({}, {debug => 1}, {shim => 1}, {same_perl => 1}) {
    subtest 'installation pins interpreter and validates the module' => sub {
        my ($status, $out, $err, $calls, $perl_calls) = run_case(%$args);
        is $status, 0, 'succeeds';
        like $out, qr/Congratulations! Net::SSLeay is installed/, 'success after load validation';
        like $err, qr/Selected Perl: .*version/, 'interpreter and version visible';
        like $err, qr/Selected cpanm: .*run with selected Perl/, 'installer strategy visible';
        like $calls, qr/\ACrypt::OpenSSL::Guess\|.*\nNet::SSLeay\|.*openssl prefix\n\z/, 'discovered prefix passed without splitting';
        like $perl_calls, qr{/bin/cpanm Crypt::OpenSSL::Guess}, 'selected interpreter runs Guess installer';
        like $perl_calls, qr{/bin/cpanm Net::SSLeay}, 'selected interpreter runs module installer';
        like $perl_calls, qr/-MNet::SSLeay -e 1\n\z/, 'final operation verifies selected Perl can load';
    };
}
my @failures = (
    ['missing cpanm', {no_cpanm => 1}, qr/plenv install-cpanm/, ''],
    ['discovery subprocess', {discovery_fail => 1}, qr/Cannot discover/, ''],
    ['version subprocess', {version_fail => 1}, qr/Cannot query.*version/, ''],
    ['empty selected Perl', {selected => ''}, qr/executable absolute path/, ''],
    ['invalid selected Perl', {selected => '/missing/perl'}, qr/executable absolute path/, ''],
    ['different Perl shebang', {shebang => '#!/other/version/bin/perl'}, qr/Perl\/cpanm mismatch/, ''],
    ['shell wrapper', {shebang => '#!/bin/sh'}, qr/Perl\/cpanm mismatch/, ''],
    ['unverifiable script', {shebang => 'not a shebang'}, qr/Cannot verify cpanm/, ''],
    ['failed shim discovery', {shim => 1, plenv_fail => 1}, qr/Cannot resolve.*shim/, ''],
    ['Guess installer', {fail_module => 'Crypt::OpenSSL::Guess'}, qr/cpanm failed.*Guess.*exit 7.*\n.*work/s, 'Guess'],
    ['Guess query', {query_fail => 1}, qr/Cannot query Crypt::OpenSSL::Guess/, 'Guess'],
    ['empty prefix', {prefix => ''}, qr/empty or invalid OPENSSL_PREFIX/, 'Guess'],
    ['carriage return prefix', {prefix => "/tmp\r"}, qr/empty or invalid OPENSSL_PREFIX/, 'Guess'],
    ['relative prefix', {prefix => '.'}, qr/empty or invalid OPENSSL_PREFIX/, 'Guess'],
    ['missing directory', {prefix => '/missing/openssl'}, qr/empty or invalid OPENSSL_PREFIX/, 'Guess'],
    ['multiple lines', {prefix => "/tmp\n/tmp"}, qr/empty or invalid OPENSSL_PREFIX/, 'Guess'],
    ['Net installer', {fail_module => 'Net::SSLeay'}, qr/cpanm failed.*SSLeay.*exit 7.*\n.*work/s, 'Net'],
    ['missing after install', {no_module => 1}, qr/installation could not be verified.*build.log/, 'Net'],
    ['broken after install', {broken_module => 1}, qr/installation could not be verified.*build.log/, 'Net'],
);
for my $case (@failures) {
    subtest "failure: $case->[0]" => sub {
        my ($status, $out, $err, $calls) = run_case(%{$case->[1]});
        isnt $status, 0, 'nonzero exit';
        is $status, 7, 'installer status preserved' if $case->[1]{fail_module};
        like $err, $case->[2], 'actionable diagnostic';
        unlike $out, qr/Congratulations/, 'no false success';
        if (!$case->[3]) { is $calls, '', 'no installer runs' }
        elsif ($case->[3] eq 'Guess') { unlike $calls, qr/^Net::SSLeay/m, 'no later install after failure' }
    };
}
subtest 'existing Net::SSLeay does not require installer or discovery' => sub {
    my ($status, $out, $err, $calls) = run_case(existing => 1, no_cpanm => 1);
    is $status, 0, 'succeeds';
    like $out, qr/Already installed Net::SSLeay/, 'existing module recognized';
    is $calls, '', 'no installation';
};
subtest 'IO::Socket::SSL also rejects a mismatched installer before installing' => sub {
    my ($status, $out, $err, $calls) = run_case(command => 'install-io-socket-ssl', shebang => '#!/other/perl');
    isnt $status, 0, 'fails';
    like $err, qr/Perl\/cpanm mismatch/, 'mismatch explained';
    is $calls, '', 'other Perl never modified';
};
done_testing;
