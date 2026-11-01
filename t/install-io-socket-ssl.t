use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use IPC::Open3;
use Symbol qw(gensym);

my $script = "$FindBin::Bin/../bin/plenv-ssl-doctor";

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
}

sub module_source {
    my ($version) = @_;
    return "package IO::Socket::SSL; our \$VERSION = '$version'; 1;\n";
}

sub run_case {
    my (%args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/bin", "$dir/lib/IO/Socket");
    write_file("$dir/lib/IO/Socket/SSL.pm", $args{module})
        if defined $args{module};
    # Load core pragmas first, then exclude every real module directory.
    write_file("$dir/lib/DoctorTestIsolation.pm", <<'PERL');
use strict;
use warnings;
@INC = ($ENV{DOCTOR_TEST_LIB});
1;
PERL
    write_file("$dir/bin/perl", <<'SH');
#!/bin/sh
if [ "$1" = '-e' ] && [ "$2" = 'print $^X' ]; then
    printf '%s' "$DOCTOR_TEST_SELECTED"
    exit 0
fi
exec "$DOCTOR_TEST_PERL" -I"$DOCTOR_TEST_LIB" -MDoctorTestIsolation "$@"
SH
    chmod 0755, "$dir/bin/perl" or die $!;
    unless ($args{no_cpanm}) {
        write_file("$dir/bin/cpanm", <<'SH');
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
SH
        chmod 0755, "$dir/bin/cpanm" or die $!;
    }

    local %ENV = %ENV;
    delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PLENV_DEBUG BASH_ENV ENV)};
    $ENV{PATH} = "$dir/bin";
    $ENV{DOCTOR_TEST_PERL} = $^X;
    $ENV{DOCTOR_TEST_SELECTED} = "$dir/bin/perl";
    $ENV{DOCTOR_TEST_LIB} = "$dir/lib";
    $ENV{DOCTOR_TEST_LOG} = "$dir/cpanm.log";
    $ENV{DOCTOR_TEST_CPANM_STATUS} = $args{cpanm_status} || 0;
    $ENV{DOCTOR_TEST_INSTALL_SOURCE} = $args{install_source} || '';

    my $err = gensym;
    my $pid = open3(my $in, my $out, $err,
        '/bin/bash', $script, 'install-io-socket-ssl');
    close $in;
    my $stdout = do { local $/; <$out> } || '';
    my $stderr = do { local $/; <$err> } || '';
    waitpid $pid, 0;
    my $status = $? >> 8;
    my $calls = '';
    if (-f "$dir/cpanm.log") {
        open my $log, '<', "$dir/cpanm.log" or die $!;
        $calls = do { local $/; <$log> };
    }
    return ($status, $stdout, $stderr, $calls);
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
