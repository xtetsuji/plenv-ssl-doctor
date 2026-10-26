use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use DoctorTest;

subtest 'fixtures isolate modules and executable lookup' => sub {
    my $fixture = DoctorTest->new;
    $fixture->module('DoctorFixture', <<'PERL');
package DoctorFixture;
our $VALUE = 'fixture only';
1;
PERL
    $fixture->executable('cpanm', <<'SH');
#!/bin/sh
printf '%s\n' "$@" > "$HOME/cpanm.log"
SH
    # These inherited settings must not reach the child.
    local $ENV{PERL5OPT} = '-MNoSuchHostModule';
    local $ENV{PERL5LIB} = '/no/such/host/library';
    local $ENV{PLENV_DEBUG} = 1;
    local $ENV{BASH_ENV} = $fixture->write_file('poison.sh', 'exit 91');
    local $ENV{'BASH_FUNC_cpanm%%'} = '() { exit 92; }';
    my $result = $fixture->run(command => ['/bin/bash', '-c', <<'SH']);
set -eu
test -z "${PLENV_DEBUG:-}"
perl -MDoctorFixture -e 'print "$DoctorFixture::VALUE\n"; eval { require File::Temp }; die "host module leaked" unless $@'
cpanm 'a module' '; touch forbidden'
SH
    is $result->{exit}, 0, 'mock Perl and cpanm succeed despite poisoned host environment';
    is $result->{signal}, 0, 'child exits normally';
    is $result->{stdout}, "fixture only\n", 'only fixture module is loaded';
    is $result->{stderr}, '', 'no host initialization or module errors';
    is $fixture->read_file('cpanm.log'), "a module\n; touch forbidden\n",
        'mock executable records literal arguments without installing anything';
};

subtest 'discovered Perl retains fixture isolation' => sub {
    my $fixture = DoctorTest->new;
    $fixture->module('DoctorFixture', 'package DoctorFixture; our $VALUE = "isolated"; 1;');
    my $discovery = $fixture->run(
        command => ['/bin/bash', '-c', q{perl -e 'print $^X'}],
    );
    is $discovery->{status}, 0, 'interpreter discovery succeeds';
    is $discovery->{stdout}, $fixture->path('bin/perl'),
        'discovery returns the absolute fixture wrapper path';
    my $result = $fixture->run(command => [
        $discovery->{stdout}, '-MDoctorFixture', '-e', 'print $DoctorFixture::VALUE',
    ]);
    is $result->{status}, 0, 'discovered interpreter loads a fixture-only module';
    is $result->{stdout}, 'isolated', 'fixture module executes through the discovered path';
    is $result->{stderr}, '', 'fixture load has no errors';
    $result = $fixture->run(command => [$discovery->{stdout}, '-MFile::Temp', '-e', '1']);
    isnt $result->{status}, 0, 'host module is inaccessible through the discovered path';
    like $result->{stderr}, qr/Can't locate File\/Temp\.pm in \@INC/,
        'host module fails because only fixture modules are visible';
};

subtest 'capture handles large stderr before stdout and preserves argument boundaries' => sub {
    my $fixture = DoctorTest->new;
    my $literal = 'spaces; $(command) "quotes"';
    my $result = $fixture->run(command => [$^X, '-e', <<'PERL', $literal]);
print STDERR 'e' x (1024 * 1024);
print STDOUT $ARGV[0];
exit 7;
PERL
    is $result->{exit}, 7, 'nonzero exit code is preserved';
    is $result->{signal}, 0, 'normal exit is distinguished from a signal';
    is $result->{stdout}, $literal, 'arguments are not interpreted by a shell';
    is $result->{stderr}, 'e' x (1024 * 1024), 'stderr is captured in full without pipe deadlock';
};

subtest 'stdin is EOF and explicit environment overrides are local' => sub {
    my $fixture = DoctorTest->new;
    local $ENV{DOCTOR_HELPER_TEST} = 'parent';
    my $result = $fixture->run(
        command => [$^X, '-e', 'exit 8 if defined <STDIN>; print "$ENV{DOCTOR_HELPER_TEST}:$ENV{PLENV_DEBUG}"'],
        env => { DOCTOR_HELPER_TEST => 'child', PLENV_DEBUG => 1 },
    );
    is $result->{exit}, 0, 'child receives EOF on stdin';
    is $result->{stdout}, 'child:1', 'explicit overrides reach the child';
    is $ENV{DOCTOR_HELPER_TEST}, 'parent', 'parent environment remains unchanged';
    $result = $fixture->run(
        command => [$^X, '-e', 'exit exists $ENV{DOCTOR_HELPER_TEST} ? 9 : 0'],
        env => { DOCTOR_HELPER_TEST => undef },
    );
    is $result->{exit}, 0, 'undef override removes a variable';
};

subtest 'signals and missing executables cannot masquerade as success' => sub {
    my $fixture = DoctorTest->new;
    my $result = $fixture->run(command => [$^X, '-e', 'kill "TERM", $$; sleep 1; exit 9']);
    is $result->{signal}, 15, 'termination signal is preserved';
    isnt $result->{status}, 0, 'raw wait status is nonzero';
    $result = $fixture->run(command => [$fixture->path('bin/missing')]);
    is $result->{exit}, 127, 'failed exec returns 127';
    like $result->{stderr}, qr/exec .*bin\/missing:/, 'failed executable is identified';
};

done_testing;
