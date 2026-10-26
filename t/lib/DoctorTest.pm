package DoctorTest;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use POSIX ();

sub new {
    my ($class) = @_;
    my $self = bless { root => tempdir(CLEANUP => 1) }, $class;
    make_path($self->path('bin'), $self->path('lib'));
    # Load core pragmas before excluding all real module directories.
    $self->write_file('lib/DoctorTestIsolation.pm', <<'PERL');
use strict;
use warnings;
@INC = ($ENV{DOCTOR_TEST_LIB});
1;
PERL
    $self->executable('perl', <<'SH');
#!/bin/sh
exec "$DOCTOR_TEST_PERL" -I"$DOCTOR_TEST_LIB" -MDoctorTestIsolation "$@"
SH
    return $self;
}

sub path {
    my ($self, $relative) = @_;
    return "$self->{root}/$relative";
}

sub write_file {
    my ($self, $relative, $content) = @_;
    my $path = $self->path($relative);
    make_path(dirname($path));
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content or die "$path: $!";
    close $fh or die "$path: $!";
    return $path;
}

sub executable {
    my ($self, $name, $source) = @_;
    my $path = $self->write_file("bin/$name", $source);
    chmod 0755, $path or die "$path: $!";
    return $path;
}

sub module {
    my ($self, $name, $source) = @_;
    $name =~ s{::}{/}g;
    return $self->write_file("lib/$name.pm", $source);
}

sub read_file {
    my ($self, $relative) = @_;
    my $path = $self->path($relative);
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh> // '';
}

sub run {
    my ($self, %args) = @_;
    my @command = @{ $args{command} || die 'command is required' };
    die 'command must not be empty' unless @command;
    my ($out, $out_path) = tempfile(DIR => $self->{root});
    my ($err, $err_path) = tempfile(DIR => $self->{root});

    local %ENV = %ENV;
    delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PLENV_DEBUG BASH_ENV ENV
        CDPATH SHELLOPTS BASHOPTS)};
    # Exported Bash functions can otherwise bypass the fake executables.
    delete @ENV{grep { /\ABASH_FUNC_/ } keys %ENV};
    $ENV{PATH} = $self->path('bin');
    $ENV{HOME} = $self->{root};
    $ENV{LC_ALL} = 'C';
    $ENV{DOCTOR_TEST_PERL} = abs_path($^X);
    $ENV{DOCTOR_TEST_LIB} = $self->path('lib');
    for my $name (keys %{ $args{env} || {} }) {
        if (defined $args{env}{$name}) {
            $ENV{$name} = $args{env}{$name};
        } else {
            delete $ENV{$name};
        }
    }

    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDIN, '<', '/dev/null' or POSIX::_exit(127);
        open STDOUT, '>&', $out or POSIX::_exit(127);
        open STDERR, '>&', $err or POSIX::_exit(127);
        # List-form exec preserves arguments and never invokes a shell.
        exec { $command[0] } @command or do {
            print STDERR "exec $command[0]: $!\n";
            POSIX::_exit(127);
        };
    }
    waitpid($pid, 0) == $pid or die "waitpid: $!";
    my $status = $?;
    close $out or die "$out_path: $!";
    close $err or die "$err_path: $!";
    # Files avoid deadlocks when either output stream exceeds pipe capacity.
    my $result = {
        status => $status,
        exit => $status >> 8,
        signal => $status & 127,
        stdout => $self->read_file(substr($out_path, length($self->{root}) + 1)),
        stderr => $self->read_file(substr($err_path, length($self->{root}) + 1)),
    };
    unlink $out_path, $err_path;
    return $result;
}

1;

__END__

=head1 NAME

DoctorTest - offline fixtures for plenv-ssl-doctor tests

=head1 USAGE

    use FindBin;
    use lib "$FindBin::Bin/lib";
    use DoctorTest;

    my $fixture = DoctorTest->new;
    $fixture->module('Net::SSLeay', 'package Net::SSLeay; 1;');
    $fixture->executable('brew', "#!/bin/sh\nprintf '%s\\n' /fake/openssl\n");
    my $result = $fixture->run(
        command => ['/bin/bash', $script, 'check-io-socket-ssl'],
        env => { PLENV_DEBUG => 1 },
    );

Each fixture has a temporary bin directory as its entire PATH and an isolated
Perl wrapper that can load only fixture modules. Files are removed at process
exit by File::Temp. write_file, module and executable return absolute paths;
path and read_file take paths relative to the fixture root. Supply executable
paths and arguments as a command array, never a shell command string. Child
stdin is closed via /dev/null. run returns stdout, stderr, exit, signal and the
raw wait status; assert signal as well as exit when checking success. Explicit
env overrides (undef removes a variable) apply after environment isolation.
Mocks must use shell builtins or absolute executable paths since host commands
are deliberately absent from PATH. No real installer is provided.

=cut
