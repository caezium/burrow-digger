#!/usr/bin/perl

use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :flock :mode);

# Darwin syscall numbers are stable across the supported Intel and Apple
# Silicon macOS releases. openat/mkdirat arrived in OS X 10.10; using them
# with O_NOFOLLOW keeps every mutable component descriptor-relative without
# relying on newer path-wide open flags.
use constant {
    SYS_FCHOWN  => 123,
    SYS_FCHMOD  => 124,
    SYS_OPENAT  => 463,
    SYS_MKDIRAT => 475,
};

sub usage {
    print STDERR <<'USAGE';
usage:
  operation_log_io.pl backend
  operation_log_io.pl prepare HOME ROOT_NAME UID GID DEVICE
  operation_log_io.pl append|ensure|truncate HOME ROOT_NAME FILE UID GID DEVICE
USAGE
    exit 64;
}

sub fail_log {
    my ($scope, $reason, $path) = @_;
    print STDERR "Invalid operation log $scope: $reason: $path\n";
    exit 1;
}

my $command = shift(@ARGV) // usage();
if ($command eq 'backend') {
    @ARGV == 0 or usage();
    print "openat+mkdirat+O_NOFOLLOW (OS X 10.10+)\n";
    exit 0;
}

my ($home, $root_name, $filename, $expected_uid, $expected_gid, $expected_device);
if ($command eq 'prepare') {
    @ARGV == 5 or usage();
    ($home, $root_name, $expected_uid, $expected_gid, $expected_device) = @ARGV;
} elsif ($command eq 'append' || $command eq 'ensure' || $command eq 'truncate') {
    @ARGV == 6 or usage();
    ($home, $root_name, $filename, $expected_uid, $expected_gid, $expected_device) = @ARGV;
} else {
    usage();
}

$home =~ m{\A/} && $home !~ m{//} && $home !~ /[[:cntrl:]]/ && $home !~ m{/$}
    or fail_log('root', 'invoking home is not canonical', $home);
$root_name =~ /\A[A-Za-z0-9][A-Za-z0-9._ -]*\z/
    && $root_name ne '.' && $root_name ne '..'
    or fail_log('root', 'unsupported directory name', $root_name);
$expected_uid =~ /\A[0-9]+\z/ && $expected_gid =~ /\A[0-9]+\z/
    && $expected_device =~ /\A[0-9]+\z/
    or fail_log('root', 'invoking identity is unavailable', $home);

$expected_uid += 0;
$expected_gid += 0;
$expected_device += 0;

if (defined($filename)) {
    $filename =~ /\A(?:operations|deletions|mole|mole_debug_session)\.log\z/
        or fail_log('file', 'unsupported filename', $filename);
}

my $logical_root = "$home/Library/Logs/$root_name";
my $compat_mode = ($ENV{MOLE_TEST_MODE} // '') eq '1'
    && ($ENV{MOLE_TEST_LOG_IO_COMPAT} // '') eq '1';

sub checked_flags {
    my ($flags) = @_;
    # The compatibility probe makes a future accidental dependency on a
    # post-10.14 path-wide flag executable rather than a source-text check.
    my $post_compat_path_flag = hex('20000000');
    if ($compat_mode && ($flags & $post_compat_path_flag) != 0) {
        fail_log('file', 'backend requires a post-10.14 open flag', $logical_root);
    }
}

sub openat_fd {
    my ($parent, $name, $flags, $mode) = @_;
    checked_flags($flags);
    my $name_arg = "$name";
    return syscall(SYS_OPENAT, fileno($parent), $name_arg, $flags, $mode);
}

sub mkdirat_fd {
    my ($parent, $name, $mode) = @_;
    my $name_arg = "$name";
    return syscall(SYS_MKDIRAT, fileno($parent), $name_arg, $mode);
}

sub handle_for_fd {
    my ($fd, $scope, $path) = @_;
    open(my $handle, "<&=$fd") or fail_log($scope, "cannot bind descriptor ($!)", $path);
    return $handle;
}

sub write_handle_for_fd {
    my ($fd, $scope, $path) = @_;
    open(my $handle, ">&=$fd") or fail_log($scope, "cannot bind descriptor ($!)", $path);
    return $handle;
}

sub validate_directory {
    my ($handle, $path, $owner_required) = @_;
    my @stat = stat($handle);
    @stat or fail_log('root', 'cannot inspect directory descriptor', $path);
    S_ISDIR($stat[2]) or fail_log('root', 'opened component is not a directory', $path);
    $stat[0] == $expected_device
        or fail_log('root', 'unexpected volume', $path);
    if ($owner_required && $stat[4] != $expected_uid) {
        fail_log('root', 'unexpected owner', $path);
    }
    return @stat;
}

sub verify_directory_entry {
    my ($parent, $name, $opened, $path) = @_;
    my $flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK;
    my $fd = openat_fd($parent, $name, $flags, 0);
    $fd >= 0 or fail_log('root', "directory entry changed while open ($!)", $path);
    my $check = handle_for_fd($fd, 'root', $path);
    my @opened_stat = stat($opened);
    my @check_stat = stat($check);
    close($check) or fail_log('root', "cannot close verification descriptor ($!)", $path);
    @opened_stat && @check_stat
        && $opened_stat[0] == $check_stat[0]
        && $opened_stat[1] == $check_stat[1]
        or fail_log('root', 'directory entry no longer names opened descriptor', $path);
}

sub open_existing_directory_at {
    my ($parent, $name, $path) = @_;
    my $flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK;
    my $fd = openat_fd($parent, $name, $flags, 0);
    $fd >= 0 or fail_log('root', "cannot open path component ($!)", $path);
    my $handle = handle_for_fd($fd, 'root', $path);
    my @stat = stat($handle);
    @stat && S_ISDIR($stat[2])
        or fail_log('root', 'path component is not a directory', $path);
    return $handle;
}

sub maybe_run_test_hook {
    my ($phase, $path) = @_;
    my $hook = $ENV{MOLE_TEST_LOG_IO_HOOK} // '';
    return if ($ENV{MOLE_TEST_MODE} // '') ne '1';
    return if $> != $expected_uid;
    return if $hook eq '';
    $hook =~ m{\A/} && -x $hook
        or fail_log('root', 'test hook is not an absolute executable', $hook);
    system($hook, $phase, $path) == 0
        or fail_log('root', 'test hook failed', $hook);
}

sub open_owned_directory_at {
    my ($parent, $name, $path, $hook_phase) = @_;
    my $flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK;
    my $fd = openat_fd($parent, $name, $flags, 0);
    my $created = 0;

    if ($fd < 0 && $! == ENOENT) {
        my $mkdir_result = mkdirat_fd($parent, $name, 0700);
        if ($mkdir_result == 0) {
            $created = 1;
        } elsif ($! != EEXIST) {
            fail_log('root', "cannot create directory ($!)", $path);
        }
        $fd = openat_fd($parent, $name, $flags, 0);
    }
    $fd >= 0 or fail_log('root', "cannot open owned directory ($!)", $path);

    my $handle = handle_for_fd($fd, 'root', $path);
    my @stat = stat($handle);
    @stat && S_ISDIR($stat[2])
        or fail_log('root', 'opened component is not a directory', $path);
    $stat[0] == $expected_device
        or fail_log('root', 'unexpected volume', $path);

    maybe_run_test_hook($hook_phase, $path) if $hook_phase ne '';

    if ($created && $> == 0
        && ($stat[4] != $expected_uid || $stat[5] != $expected_gid)) {
        syscall(SYS_FCHOWN, fileno($handle), $expected_uid, $expected_gid) == 0
            or fail_log('root', "cannot assign invoking-user ownership ($!)", $path);
    }
    if ($created) {
        syscall(SYS_FCHMOD, fileno($handle), 0700) == 0
            or fail_log('root', "cannot restrict directory permissions ($!)", $path);
    }

    validate_directory($handle, $path, 1);
    verify_directory_entry($parent, $name, $handle, $path);
    return $handle;
}

sub prepare_root {
    my $root_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK;
    checked_flags($root_flags);
    sysopen(my $cursor, '/', $root_flags)
        or fail_log('root', "cannot open filesystem root ($!)", '/');
    my @held = ($cursor);
    my $path = '';

    for my $component (grep { length($_) > 0 } split(m{/}, $home)) {
        $component ne '.' && $component ne '..'
            or fail_log('root', 'invoking home contains traversal', $home);
        $path .= "/$component";
        my $next = open_existing_directory_at($cursor, $component, $path);
        push @held, $next;
        $cursor = $next;
    }

    my $home_handle = $cursor;
    validate_directory($home_handle, $home, 1);
    my $library = open_owned_directory_at(
        $home_handle, 'Library', "$home/Library", ''
    );
    my $logs = open_owned_directory_at(
        $library, 'Logs', "$home/Library/Logs", ''
    );
    my $root = open_owned_directory_at(
        $logs, $root_name, $logical_root, 'opened-log-root'
    );
    push @held, $library, $logs, $root;

    return {
        held    => \@held,
        home    => $home_handle,
        library => $library,
        logs    => $logs,
        root    => $root,
    };
}

sub verify_root_chain {
    my ($context) = @_;
    verify_directory_entry(
        $context->{home}, 'Library', $context->{library}, "$home/Library"
    );
    verify_directory_entry(
        $context->{library}, 'Logs', $context->{logs}, "$home/Library/Logs"
    );
    verify_directory_entry(
        $context->{logs}, $root_name, $context->{root}, $logical_root
    );
}

sub verify_file_entry {
    my ($root, $name, $opened, $path) = @_;
    my $flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK;
    my $fd = openat_fd($root, $name, $flags, 0);
    $fd >= 0 or fail_log('file', "file entry changed while open ($!)", $path);
    my $check = handle_for_fd($fd, 'file', $path);
    my @opened_stat = stat($opened);
    my @check_stat = stat($check);
    close($check) or fail_log('file', "cannot close verification descriptor ($!)", $path);
    @opened_stat && @check_stat
        && $opened_stat[0] == $check_stat[0]
        && $opened_stat[1] == $check_stat[1]
        or fail_log('file', 'file entry no longer names opened descriptor', $path);
}

sub write_log_file {
    my ($context) = @_;
    my $path = "$logical_root/$filename";
    my $flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK;
    $flags |= O_APPEND if $command eq 'append';
    my $fd = openat_fd($context->{root}, $filename, $flags, 0);
    my $created = 0;

    for (1 .. 4) {
        last if $fd >= 0;
        fail_log('file', "open failed ($!)", $path) if $! != ENOENT;
        $fd = openat_fd(
            $context->{root}, $filename, $flags | O_CREAT | O_EXCL, 0600
        );
        if ($fd >= 0) {
            $created = 1;
            last;
        }
        next if $! == EEXIST;
        fail_log('file', "create failed ($!)", $path);
    }
    $fd >= 0 or fail_log('file', 'leaf changed repeatedly while opening', $path);

    my $handle = write_handle_for_fd($fd, 'file', $path);
    my @stat = stat($handle);
    @stat or fail_log('file', 'cannot inspect opened descriptor', $path);
    S_ISREG($stat[2]) or fail_log('file', 'opened leaf is not a regular file', $path);
    $stat[3] == 1 or fail_log('file', 'opened leaf has multiple hard links', $path);
    $stat[0] == $expected_device or fail_log('file', 'unexpected volume', $path);

    if ($created && $> == 0
        && ($stat[4] != $expected_uid || $stat[5] != $expected_gid)) {
        syscall(SYS_FCHOWN, fileno($handle), $expected_uid, $expected_gid) == 0
            or fail_log('file', "cannot assign invoking-user ownership ($!)", $path);
    }
    syscall(SYS_FCHMOD, fileno($handle), 0600) == 0
        or fail_log('file', "cannot restrict permissions ($!)", $path);

    @stat = stat($handle);
    @stat && S_ISREG($stat[2]) && $stat[3] == 1
        && $stat[0] == $expected_device && $stat[4] == $expected_uid
        or fail_log('file', 'descriptor identity changed', $path);
    flock($handle, LOCK_EX) or fail_log('file', "cannot lock descriptor ($!)", $path);

    verify_root_chain($context);
    verify_file_entry($context->{root}, $filename, $handle, $path);
    truncate($handle, 0) or fail_log('file', "cannot truncate descriptor ($!)", $path)
        if $command eq 'truncate';

    my $buffer;
    while (1) {
        my $read = sysread(STDIN, $buffer, 65536);
        defined($read) or fail_log('file', "cannot read log payload ($!)", $path);
        last if $read == 0;
        my $offset = 0;
        while ($offset < $read) {
            my $written = syswrite($handle, $buffer, $read - $offset, $offset);
            defined($written) && $written > 0
                or fail_log('file', "cannot write descriptor ($!)", $path);
            $offset += $written;
        }
    }

    verify_root_chain($context);
    verify_file_entry($context->{root}, $filename, $handle, $path);
    close($handle) or fail_log('file', "cannot close descriptor ($!)", $path);
}

my $context = prepare_root();
verify_root_chain($context);
if ($command eq 'prepare') {
    print "$logical_root\n";
    exit 0;
}

write_log_file($context);
