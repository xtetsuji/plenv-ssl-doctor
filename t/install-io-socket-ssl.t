use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/lib";
use DoctorTest;

my $script = "$FindBin::Bin/../bin/plenv-ssl-doctor";

sub module_source {
    my ($version) = @_;
    return "package IO::Socket::SSL; our \$VERSION = '$version'; 1;\n";
}

sub run_case {
    my (%args) = @_;
    my $fixture = DoctorTest->new;
    # The stub installer needs this directory even when the module is missing.
    make_path($fixture->path('lib/IO/Socket'));
    $fixture->module('IO::Socket::SSL', $args{module})
        if defined $args{module};
    unless ($args{no_cpanm}) {
        $fixture->executable('cpanm', <<'PERL');
#!/usr/bin/env perl
open my $log, '>>', $ENV{DOCTOR_TEST_LOG} or die $!;
print {$log} "@ARGV\n";
close $log or die $!;
exit $ENV{DOCTOR_TEST_CPANM_STATUS} if $ENV{DOCTOR_TEST_CPANM_STATUS};
if (length $ENV{DOCTOR_TEST_INSTALL_SOURCE}) {
    open my $module, '>', "$ENV{DOCTOR_TEST_LIB}/IO/Socket/SSL.pm" or die $!;
    print {$module} $ENV{DOCTOR_TEST_INSTALL_SOURCE};
    close $module or die $!;
}
PERL
    }

    my $result = $fixture->run(
        command => ['/bin/bash', $script, 'install-io-socket-ssl'],
        env => {
            DOCTOR_TEST_LOG => $fixture->path('cpanm.log'),
            DOCTOR_TEST_CPANM_STATUS => $args{cpanm_status} || 0,
            DOCTOR_TEST_INSTALL_SOURCE => $args{install_source} || '',
        },
    );
    is $result->{signal}, 0, 'command exits without a signal';
    my $calls = -f $fixture->path('cpanm.log')
        ? $fixture->read_file('cpanm.log') : '';
    return ($result->{exit}, $result->{stdout}, $result->{stderr}, $calls);
}

subtest 'missing module is installed and verified' => sub {
    my ($status, $out, $err, $calls) = run_case(
        install_source => module_source('2.099'));
    is $status, 0, 'installation succeeds';
    like $out, qr/=== install IO::Socket::SSL ===/, 'installation path reached';
    like $err, qr/IO::Socket::SSL is not installed/, 'missing module identified';
    is $calls, "IO::Socket::SSL\n", 'only requested module installed';
};

for my $version ('1.42', '2.099', 'v2.0.0') {
    subtest "installed version $version satisfies minimum" => sub {
        my ($status, $out, $err, $calls) = run_case(module => module_source($version));
        is $status, 0, 'succeeds';
        like $out, qr/already installed/, 'existing installation reported';
        like $err, qr/Selected Perl: .*version/, 'selected Perl reported';
        unlike $err, qr/Failed|Cannot|not installed/, 'no errors';
        is $calls, '', 'installer not invoked';
    };
}

subtest 'outdated module requires explicit upgrade' => sub {
    my ($status, $out, $err, $calls) = run_case(module => module_source('1.41'));
    is $status, 1, 'fails';
    like $err, qr/minimum version 1\.42/, 'required version reported';
    like $err, qr/1\.41/, 'installed version reported';
    like $err, qr/cpanm IO::Socket::SSL/, 'upgrade command provided';
    is $calls, '', 'no implicit installation';
    unlike $out, qr/already installed/, 'no success message';
};

for my $source ('this is invalid perl !!!',
                'package IO::Socket::SSL; require DoctorMissingDependency; 1;',
                'package IO::Socket::SSL; die "broken module\n";') {
    subtest "load failure: $source" => sub {
        my ($status, $out, $err, $calls) = run_case(module => $source);
        is $status, 1, 'fails';
        like $err, qr/Failed to load IO::Socket::SSL:/, 'load failure identified';
        unlike $err, qr/IO::Socket::SSL is not installed/, 'not classified as missing';
        unlike $out, qr/already installed/, 'no success message';
        is $calls, '', 'installer not invoked';
    };
}

subtest 'missing installer fails with instructions' => sub {
    my ($status, $out, $err) = run_case(no_cpanm => 1);
    is $status, 1, 'fails';
    like $err, qr/plenv install-cpanm/, 'installation command provided';
};

subtest 'installer failure is propagated' => sub {
    my ($status, $out, $err, $calls) = run_case(cpanm_status => 7);
    is $status, 7, 'preserves installer exit code';
    is $calls, "IO::Socket::SSL\n", 'installer invoked';
};

for my $source ('', module_source('1.41'), 'die "broken installation\n";') {
    subtest 'installer success must produce a usable module' => sub {
        my ($status, $out, $err, $calls) = run_case(install_source => $source);
        is $status, 1, 'verification failure returns nonzero';
        like $err, qr/installation could not be verified/, 'failure reported';
        is $calls, "IO::Socket::SSL\n", 'installer invoked once';
    };
}

done_testing;
