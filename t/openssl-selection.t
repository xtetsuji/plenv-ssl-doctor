use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use DoctorTest;
use Cwd qw(abs_path);

my $script = abs_path("$FindBin::Bin/../bin/plenv-ssl-doctor");
sub fixture {
    my $f = DoctorTest->new;
    $f->write_file('calls', '');
    $f->executable('brew', <<'SH');
#!/bin/sh
[ "$1" = --prefix ] || exit 8
[ "${BREW_FAIL:-0}" = 0 ] || exit 9
case "$2" in
    openssl@3) [ -n "${BREW_THREE:-}" ] || exit 1; printf '%s' "$BREW_THREE" ;;
    openssl) [ -n "${BREW_OTHER:-}" ] || exit 1; printf '%s' "$BREW_OTHER" ;;
    *) exit 1 ;;
esac
SH
    $f->executable('cpanm', <<'PERL_SCRIPT');
#!/usr/bin/env perl
open my $log, '>>', "$ENV{HOME}/calls" or die $!;
print {$log} "$ARGV[0]|", ($ENV{OPENSSL_PREFIX} // ''), "\n";
close $log or die $!;
if ($ARGV[0] eq 'Net::SSLeay') {
    print STDERR "BUILD Net::SSLeay\n";
    open my $mod, '>', "$ENV{DOCTOR_TEST_LIB}/Net/SSLeay.pm" or die $!;
    print {$mod} 'package Net::SSLeay; 1;';
    close $mod or die $!;
} else { exit 7 }
PERL_SCRIPT
    $f->write_file('lib/Net/.keep', '');
    return $f;
}
sub prefix {
    my ($f, $name, $version, $kind) = @_;
    $kind ||= '';
    my $path = $f->write_file("$name/bin/openssl", "#!/bin/sh\n" .
        ($kind eq 'version-fail' ? "exit 3\n" : "printf '%s\\n' '$version'\n"));
    chmod 0755, $path or die $!;
    unlink $path if $kind eq 'executable';
    $f->write_file("$name/include/openssl/ssl.h", 'fixture') unless $kind eq 'header';
    my $libdir = $kind eq 'lib64' ? 'lib64' : 'lib';
    my $ext = $kind eq 'lib64' ? 'so.3' : 'a';
    $f->write_file("$name/$libdir/libssl.$ext", 'fixture');
    $f->write_file("$name/$libdir/libcrypto.$ext", $kind eq 'empty-library' ? '' : 'fixture')
        unless $kind eq 'library' || $kind eq 'dangling-library';
    symlink "$path.missing", $f->path("$name/$libdir/libcrypto.$ext") or die $!
        if $kind eq 'dangling-library';
    return abs_path($f->path($name));
}
sub run_install {
    my ($f, $env, @args) = @_;
    return $f->run(command => ['/bin/bash', $script, @args ? @args : 'install-net-ssleay'],
        env => { OPENSSL_PREFIX => undef, BREW_THREE => undef, BREW_OTHER => undef,
            BREW_FAIL => undef, GUESS_PREFIX => undef, %{$env || {}} });
}
sub succeeds {
    my ($r) = @_;
    is $r->{exit}, 0, 'successful exit';
    is $r->{signal}, 0, 'no signal';
}
for my $case ('three', 'four', 'both') {
    subtest "automatic $case" => sub {
        my $f = fixture();
        my $three = prefix($f, 'OpenSSL 3', 'OpenSSL 3.6.0 fixture');
        my $four = prefix($f, 'OpenSSL 4', 'OpenSSL 4.0.3 fixture', 'lib64');
        my $r = run_install($f, { BREW_THREE => $case eq 'four' ? '' : $three,
            BREW_OTHER => $case eq 'three' ? '' : $four });
        succeeds($r);
        my $chosen = $case eq 'four' ? $four : $three;
        like $r->{stderr}, qr/Selected OpenSSL: \Q$chosen\E\n/, 'deterministic canonical selection';
        like $r->{stderr}, qr/OpenSSL version: OpenSSL [34]\./, 'version reported';
        like $r->{stderr}, qr/source: homebrew:.*reason: first valid/, 'source and reason reported';
        like $r->{stderr}, qr/Selected OpenSSL:.*OpenSSL version:.*reason:.*BUILD Net::SSLeay/s, 'selection reported before build';
        is $f->read_file('calls'), "Net::SSLeay|$chosen\n", 'no Guess prerequisite and prefix preserves spaces';
    };
}
subtest 'explicit priority and option placement' => sub {
    for my $placement ('before', 'after', 'repeat') {
        my $f = fixture();
        my $cli = prefix($f, 'custom install', 'OpenSSL 4.0.3 fixture');
        my $env = prefix($f, 'environment', 'OpenSSL 3.0.0 fixture');
        my @args = $placement eq 'before' ? ('--openssl-prefix', $cli, 'install-net-ssleay') :
            ('install-net-ssleay', '--openssl-prefix', $cli);
        unshift @args, '--openssl-prefix', '/invalid' if $placement eq 'repeat';
        my $r = run_install($f, { OPENSSL_PREFIX => $env, BREW_THREE => $env }, @args);
        succeeds($r);
        like $r->{stderr}, qr/source: cli; reason: explicit --openssl-prefix/, 'CLI wins';
        is $f->read_file('calls'), "Net::SSLeay|$cli\n", 'CLI prefix used';
    }
    my $f = fixture();
    my $env = prefix($f, 'environment', 'OpenSSL 3.0.0 fixture');
    my $r = run_install($f, { OPENSSL_PREFIX => $env, BREW_OTHER => '/invalid' });
    succeeds($r);
    like $r->{stderr}, qr/source: environment; reason: explicit OPENSSL_PREFIX/, 'environment wins';
};
for my $kind ('executable', 'version-fail', 'malformed', 'header', 'library', 'empty-library', 'dangling-library') {
    subtest "invalid candidate $kind" => sub {
        for my $source ('cli', 'environment', 'automatic') {
            my $f = fixture();
            my $bad = prefix($f, 'bad', $kind eq 'malformed' ? 'garbage' : 'OpenSSL 3.0.0', $kind);
            my $good = prefix($f, 'good', 'OpenSSL 4.0.0');
            my @args = ('install-net-ssleay');
            push @args, '--openssl-prefix', $bad if $source eq 'cli';
            my $r = run_install($f, { BREW_THREE => $bad, BREW_OTHER => $good,
                ($source eq 'environment' ? (OPENSSL_PREFIX => $bad) : ()) }, @args);
            like $r->{stderr}, qr/Rejected .*prefix.*(?:failed|malformed|missing)/, 'validation explained';
            if ($source eq 'automatic') {
                succeeds($r);
                is $f->read_file('calls'), "Net::SSLeay|$good\n", 'invalid automatic candidate skipped';
            } else {
                is $r->{exit}, 2, 'explicit error status';
                is $f->read_file('calls'), '', 'no install or silent fallback';
            }
        }
    };
}
subtest 'empty and malformed overrides and option arguments' => sub {
    for my $value ('', '.', "/tmp\n/tmp", "/tmp\r", "/tmp\t", '/missing/openssl') {
        my $f = fixture();
        my $r = run_install($f, { OPENSSL_PREFIX => $value });
        is $r->{exit}, 2, 'invalid environment fails';
        is $f->read_file('calls'), '', 'no prerequisites installed';
    }
    for my $args (['install-net-ssleay', '--openssl-prefix'],
        ['--openssl-prefix', '', 'install-net-ssleay'],
        ['install-net-ssleay', '--openssl-prefix', '--unknown'],
        ['check-io-socket-ssl', '--openssl-prefix', '/tmp'],
        ['install-net-ssleay', '--unknown'], ['install-net-ssleay', 'extra']) {
        my $f = fixture();
        my $r = run_install($f, {}, @$args);
        is $r->{exit}, 2, 'usage error';
        is $f->read_file('calls'), '', 'usage error cannot install';
    }
};
subtest 'existing Guess fallback and optional source failures' => sub {
    for my $brew ('missing', 'failing', 'uninstalled') {
        my $f = fixture();
        unlink $f->path('bin/brew') if $brew eq 'missing';
        my $custom = prefix($f, 'custom', 'OpenSSL 3.0.0');
        $f->module('Crypt::OpenSSL::Guess', <<'GUESS');
package Crypt::OpenSSL::Guess;
sub import { *main::find_openssl_prefix = sub { $ENV{GUESS_PREFIX} } }
1;
GUESS
        my $r = run_install($f, { GUESS_PREFIX => $custom, BREW_FAIL => $brew eq 'failing' ? 1 : 0,
            BREW_THREE => $f->path('uninstalled') });
        succeeds($r);
        like $r->{stderr}, qr/source: guess;/, 'Guess used when available';
        is $f->read_file('calls'), "Net::SSLeay|$custom\n", 'existing Guess is not installed again';
    }
    for my $guess ('missing', 'failing') {
        my $f = fixture();
        $f->module('Crypt::OpenSSL::Guess', 'die "fixture failure";') if $guess eq 'failing';
        my $good = prefix($f, 'homebrew', 'OpenSSL 4.0.0');
        my $r = run_install($f, { BREW_OTHER => $good });
        succeeds($r);
        is $f->read_file('calls'), "Net::SSLeay|$good\n", 'optional Guess failure cannot block Homebrew';
    }
    my $f = fixture();
    $f->module('Crypt::OpenSSL::Guess', 'package Crypt::OpenSSL::Guess; sub import { die "query failure" if $_[1]; *main::find_openssl_prefix = sub { die "query failure" } } 1;');
    my $r = run_install($f);
    isnt $r->{exit}, 0, 'no candidates fails';
    like $r->{stderr}, qr/Cannot query.*Guess.*No valid OpenSSL/s, 'query failure explained';
    is $f->read_file('calls'), '', 'no pointless reinstall of existing Guess';
};
subtest 'read-only API deduplicates canonical symlink aliases' => sub {
    my $f = fixture();
    my $real = prefix($f, 'real prefix', 'OpenSSL 3.0.0');
    symlink $real, $f->path('alias') or die $!;
    $f->module('Crypt::OpenSSL::Guess', 'package Crypt::OpenSSL::Guess; sub import { *main::find_openssl_prefix = sub { $ENV{BREW_OTHER} } } 1;');
    my $env = { OPENSSL_PREFIX => undef, BREW_FAIL => undef, BREW_THREE => $f->path('alias'), BREW_OTHER => $real };
    my $r = $f->run(command => ['/bin/bash', '-c', <<'SH', 'test', $script], env => $env);
source "$1"
select-perl || exit
discover-openssl-candidates || exit
select-openssl-candidate || exit
printf '%s\n%s\n%s\n' "$OPENSSL_CANDIDATE_COUNT" "$RESOLVED_OPENSSL_PREFIX" "$SELECTED_OPENSSL_SOURCE"
SH
    succeeds($r);
    is $r->{stdout}, "1\n$real\nhomebrew:openssl\@3\n", 'one record, physical path, first source retained';
    is $f->read_file('calls'), '', 'discovery never calls cpanm';
};
subtest 'all automatic records remain available for compatibility policy' => sub {
    my $f = fixture();
    my $three = prefix($f, 'three', 'OpenSSL 3.0.0');
    my $four = prefix($f, 'four', 'OpenSSL 4.0.0');
    my $custom = prefix($f, 'custom', 'OpenSSL 3.1.0');
    $f->module('Crypt::OpenSSL::Guess', 'package Crypt::OpenSSL::Guess; sub import { *main::find_openssl_prefix = sub { $ENV{GUESS_PREFIX} } } 1;');
    my $env = { OPENSSL_PREFIX => undef, BREW_FAIL => undef, BREW_THREE => $three, BREW_OTHER => $four, GUESS_PREFIX => $custom };
    my $r = $f->run(command => ['/bin/bash', '-c', <<'SH', 'test', $script], env => $env);
source "$1"
select-perl &&discover-openssl-candidates || exit
printf '%s\n' "$OPENSSL_CANDIDATE_COUNT" "${OPENSSL_PREFIXES[@]}" "${OPENSSL_SOURCES[@]}"
SH
    succeeds($r);
    is $r->{stdout}, "3\n$three\n$four\n$custom\nhomebrew:openssl\@3\nhomebrew:openssl\nguess\n", 'ordered records without version policy';
    is $f->read_file('calls'), '', 'no installation';
};
subtest 'valid CLI overrides an empty environment override' => sub {
    my $f = fixture();
    my $custom = prefix($f, 'custom prefix', 'OpenSSL 4.0.0');
    my $r = run_install($f, { OPENSSL_PREFIX => '' }, 'install-net-ssleay', '--openssl-prefix', $custom);
    succeeds($r);
    is $f->read_file('calls'), "Net::SSLeay|$custom\n", 'higher priority valid CLI is authoritative';
};
subtest 'invalid explicit override fails even with an installed module' => sub {
    my $f = fixture();
    $f->module('Net::SSLeay', 'package Net::SSLeay; 1;');
    my $r = run_install($f, { OPENSSL_PREFIX => '' });
    is $r->{exit}, 2, 'invalid explicit input fails';
    is $f->read_file('calls'), '', 'no installer';
};
subtest 'neither installed: read-only discovery does not bootstrap Guess' => sub {
    my $f = fixture();
    my $r = $f->run(command => ['/bin/bash', '-c', 'source "$1"; select-perl && discover-openssl-candidates', 'test', $script],
        env => { OPENSSL_PREFIX => undef, BREW_THREE => undef, BREW_OTHER => undef, BREW_FAIL => undef });
    is $r->{exit}, 1, 'no candidate status';
    is $f->read_file('calls'), '', 'offline discovery never installs';
    $r = run_install($f);
    is $r->{exit}, 7, 'optional bootstrap failure preserves cpanm status';
    is $f->read_file('calls'), "Crypt::OpenSSL::Guess|\n", 'installation may bootstrap only after discovery is exhausted';
};
done_testing;
