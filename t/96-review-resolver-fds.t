use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use IO::Socket::IP;
use IO::Select;
use Time::HiRes  qw(sleep setitimer ITIMER_REAL);
use POSIX        qw(WNOHANG);
use File::Temp   qw(tempdir);
use Scalar::Util qw(refaddr);
sub now { Webmania::Transport::now() }

sub fds {
    my ($pid) = @_;
    opendir my $d, "/proc/$pid/fd" or return [];
    my @f = grep { /\A[0-9]+\z/ } readdir $d;
    closedir $d;
    \@f;
}
my $dir      = tempdir( CLEANUP => 1 );
my $baseline = @{ fds($$) };
my $listener = IO::Socket::IP->new( LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1 )
  or die;
my $caller = IO::Socket::IP->new( PeerHost => '127.0.0.1', PeerPort => $listener->sockport ) or die;
my $peer   = $listener->accept                                                               or die;
$peer->blocking(0);
my ( $tick, $eof_during, $worker_fd_count, $closed_at, $observed_at ) = ( 0, 0, undef, undef, undef );
my $start = now();
my $ok;
my $worker_targets;
{
    no warnings 'redefine';
    local *Webmania::Transport::getaddrinfo = sub {
        open my $f, '>', "$dir/worker-pid" or POSIX::_exit(2);
        print $f $$;
        $f->flush;
        POSIX::close( fileno($f) );
        close $f;
        sleep(3);
        return ('held resolver');
    };
    local $SIG{ALRM} = sub {
        ++$tick;
        if    ( $tick == 1 ) { close $caller; $closed_at = now() - $start }
        elsif ( $tick == 2 ) {
            if ( IO::Select->new($peer)->can_read(0) ) {
                my $n = sysread( $peer, my $buf, 1 );
                $eof_during  = defined $n && $n == 0;
                $observed_at = now() - $start;
            }
            if ( open my $f, '<', "$dir/worker-pid" ) {
                my $pid = <$f>;
                close $f;
                $worker_fd_count = @{ fds($pid) };
                $worker_targets =
                  join( "; ",
                    map { $_ . "=" . ( readlink("/proc/$pid/fd/$_") // "closed" ) } @{ fds($pid) } );
            }
        }
    };
    setitimer( ITIMER_REAL, .10, .15 );
    $ok = eval {
        Webmania::Transport::_resolve( 'held.synthetic.test', 443,
            { options => Webmania::Transport::options( { timeout => .6 } ), deadline => now() + .6 } );
        1;
    };
    setitimer( ITIMER_REAL, 0, 0 );
}
my $e = $@;
ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq 'timeout',
    'held resolver deadline remains structured' );
ok( $eof_during, 'caller-owned TCP A reaches EOF while DNS B is still held' );
cmp_ok( $observed_at // 99, '<', .45, 'caller TCP release precedes resolver deadline' );
is( $worker_fd_count, 1, 'held resolver keeps only its owned IPC descriptor' )
  or diag( $worker_targets // 'no targets' );
close $caller if defined fileno($caller);
close $peer;
close $listener;
is( waitpid( -1, WNOHANG ), -1,        'held resolver killed and reaped' );
is( scalar @{ fds($$) },    $baseline, 'caller parent descriptor table unchanged after resolver cleanup' );

# Both requests enter public clients. Test-only hooks capture the actual active
# A socket so the caller's independent signal callback can close it while a
# reentrant public B call is held in DNS. A timer helper is forked before A
# exists, preventing the test helper itself from retaining A's descriptor.
my $server = TestServer->new(
    [
        sub {
            my ( $record, $index, $socket ) = @_;
            my $begin    = now();
            my $readable = IO::Select->new($socket)->can_read(.40);
            my $eof      = 0;
            if ($readable) {
                my $n = POSIX::read( fileno($socket), my $buf, 1 );
                $eof = defined $n && $n == 0;
            }
            open my $f, '>', "$dir/sdk-peer-eof" or die;
            print $f "$eof " . ( now() - $begin );
            close $f;
            return undef;
        }
    ]
);
my $a    = $server->pool->{Nfe};
my $cred = Webmania::CompanyCredentials->new(
    consumer_key        => 'a',
    consumer_secret     => 'b',
    access_token        => 'c',
    access_token_secret => 'd'
);
my $b = Webmania::NfeClient->new(
    credentials => $cred,
    base_url    => 'https://held-reentrant.synthetic.test',
    options     => { timeout => .55 }
);
pipe( my $go_r, my $go_w ) or die;
my $parent = $$;
my $timer  = fork();
die unless defined $timer;
if ( !$timer ) {
    close $go_w;
    POSIX::_exit(2) unless IO::Select->new($go_r)->can_read(3);
    sysread( $go_r, my $byte, 1 );
    close $go_r;
    sleep(.08);
    kill 'ALRM', $parent;
    sleep(.14);
    kill 'USR1', $parent;
    POSIX::_exit(0);
}
close $go_r;
my ( $active_a, $b_error, $b_end, $a_close );
my $connect = \&Webmania::Transport::_connect;
my $resolve = \&Webmania::Transport::getaddrinfo;
{
    no warnings 'redefine';
    local *Webmania::Transport::getaddrinfo = sub {
        if ( $_[0] eq 'held-reentrant.synthetic.test' ) { sleep(3); return ('held resolver') }
        return $resolve->(@_);
    };
    local *Webmania::Transport::_connect = sub {
        my ( $transport, $context ) = @_;
        my $socket = $connect->(@_);
        if ( refaddr($transport) == refaddr( $a->{transport} ) ) {
            $active_a = $socket;
            syswrite( $go_w, 'x' );
            close $go_w;
        }
        return $socket;
    };
    local $SIG{ALRM} = sub {
        eval { $b->get_certificate_validity };
        $b_error = $@;
        $b_end   = now();
    };
    local $SIG{USR1} = sub {
        if ($active_a) { $active_a->close( SSL_no_shutdown => 1 ); $a_close = now() }
    };
    eval { $a->update_company( body => { ID => 'reentrant-safe-selector' }, options => { timeout => 2 } ) };
    $e = $@;
}
waitpid( $timer, 0 );
ok( ref($b_error) eq 'Webmania::Error' && $b_error->kind eq 'timeout',
    'reentrant public B honors its own DNS deadline' );
ok(
    ref($e) eq 'Webmania::Error' && $e->outcome eq 'unknown',
    'sent public A keeps mutation uncertainty after caller close'
);
my ( $sdk_eof, $sdk_delay );
if ( open my $f, '<', "$dir/sdk-peer-eof" ) { ( $sdk_eof, $sdk_delay ) = split / /, <$f>; close $f }
ok( $sdk_eof, 'native public SDK A peer reaches EOF before held B resolver exits' );
cmp_ok( $sdk_delay // 99, '<', .40, 'SDK A descriptor release is prompt during reentrant B' );
ok( defined $a_close && defined $b_end && $a_close < $b_end, 'caller closes A while B is still active' );
is( scalar @{ $server->records }, 1, 'public A mutation transferred once without retry' );
$server->stop;
$a->close;
$b->close;
is( waitpid( -1, WNOHANG ), -1,        'reentrant timer/resolver/server children reaped' );
is( scalar @{ fds($$) },    $baseline, 'reentrant SDK path retains no parent descriptors' );
my $owner = $$;
my $worker_exception;
{
    no warnings 'redefine';
    local *Webmania::Transport::getaddrinfo = sub { die 'synthetic native resolver boundary fault' };
    eval {
        Webmania::Transport::_resolve( 'fault.synthetic.test', 443,
            { options => Webmania::Transport::options( { timeout => .5 } ), deadline => now() + .5 } );
    };
    $worker_exception = $@;
}
if ( $$ != $owner ) {
    open my $escaped, '>', "$dir/worker-escaped-caller";
    print $escaped 'escaped';
    close $escaped;
    POSIX::_exit(93);
}
ok( ref($worker_exception) eq 'Webmania::Error' && $worker_exception->kind eq 'network',
    'resolver exception returns static network failure to parent' );
ok( !-e "$dir/worker-escaped-caller", 'resolver exception cannot unwind into copied caller continuation' );
is( waitpid( -1, WNOHANG ), -1,        'exceptional resolver worker reaped' );
is( scalar @{ fds($$) },    $baseline, 'exceptional resolver path retains no parent descriptors' );
done_testing;
