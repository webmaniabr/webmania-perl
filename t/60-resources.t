use strict;
use warnings;
use Test::More;
use Webmania;
use IO::Socket::IP;
use Time::HiRes qw(time sleep alarm);
use POSIX       qw(WNOHANG);

sub error_kind {
    my ( $call, $kind, $name ) = @_;
    my $ok = eval { $call->(); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq $kind, $name ) or diag("$@");
}

sub fdcount {
    opendir my $d, '/proc/self/fd' or die;
    my @n = grep { $_ ne '.' && $_ ne '..' } readdir $d;
    scalar @n;
}
my $cred = Webmania::CompanyCredentials->new(
    consumer_key        => 'a',
    consumer_secret     => 'b',
    access_token        => 'c',
    access_token_secret => 'd'
);
my $l = IO::Socket::IP->new( LocalHost => '127.0.0.1', LocalPort => 0, Listen => 64, ReuseAddr => 1 ) or die;
my $port = $l->sockport;
my $pid  = fork();
die unless defined $pid;
if ( !$pid ) {
    close $l;
    POSIX::_exit(0);
}    # parent listener accepts TCP in a dedicated fixture child and never begins TLS
waitpid( $pid, 0 );
$pid = fork();
die unless defined $pid;
if ( !$pid ) {
    $SIG{TERM} = 'DEFAULT';
    while ( my $s = $l->accept ) { sleep(5); close $s }
    POSIX::_exit(0);
}
my $c = Webmania::NfeClient->new(
    credentials => $cred,
    base_url    => "https://127.0.0.1:$port",
    options     => { timeout => .07 }
);
my $start = time;
error_kind( sub { $c->get_certificate_validity }, 'timeout', 'stalled native TLS handshake bounded' );
cmp_ok( time - $start, '<', .3, 'stalled handshake returns promptly' );
my $cancel = Webmania::Cancel->new;
{
    local $SIG{ALRM} = sub { $cancel->cancel };
    alarm(.06);
    $start = time;
    error_kind( sub { $c->get_certificate_validity( options => { timeout => 1, cancel => $cancel } ) },
        'cancelled', 'stalled TLS handshake cancellable' );
    alarm(0)
}
cmp_ok( time - $start, '<', .3, 'stalled handshake cancellation returns promptly' );
kill 'KILL', $pid;
waitpid( $pid, 0 );
close $l;

# Saturate a loopback accept queue without accepting. The call must bound its
# real nonblocking TCP connect, before any TLS handshake or HTTP write.
my $listen = IO::Socket::IP->new( LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1 )
  or die;
my @fill;
for ( 1 .. 16 ) {
    my $s = IO::Socket::IP->new( PeerHost => '127.0.0.1', PeerPort => $listen->sockport, Blocking => 0 );
    push @fill, $s if $s;
}
my $cc = Webmania::NfeClient->new(
    credentials => $cred,
    base_url    => 'https://127.0.0.1:' . $listen->sockport,
    options     => { timeout => .07 }
);
$start = time;
error_kind( sub { $cc->get_certificate_validity }, 'timeout', 'native TCP connect wait bounded' );
cmp_ok( time - $start, '<', .3, 'pending connect returns promptly' );
@fill = ();
close $listen;
my $fd = fdcount();
my $before;
{ open my $f, '<', '/proc/self/statm' or die; my $line = <$f>; $before = ( split / /, $line )[1] }

for ( 1 .. 30 ) {
    my $ctx = {
        options  => Webmania::Transport::options( { timeout => .006 } ),
        deadline => Webmania::Transport::now() + .006
    };
    {
        no warnings 'redefine';
        local *Webmania::Transport::getaddrinfo = sub { sleep(5); return ('fixture') };
        eval { Webmania::Transport::_resolve( 'stall.test', 443, $ctx ) }
    }
}
is( fdcount(),              $fd, 'repeated resolver timeouts retain no descriptors' );
is( waitpid( -1, WNOHANG ), -1,  'repeated resolver timeouts retain no children' );
for ( 1 .. 300 ) {
    my $v = Webmania::JSON::snapshot( { n => Webmania::number('9007199254740993.1'), array => [ 0, 1, 2 ] } );
    eval { Webmania::JSON::decode_json('[[') }
}
my $after;
{ open my $f, '<', '/proc/self/statm' or die; my $line = <$f>; $after = ( split / /, $line )[1] }
cmp_ok( ( $after - $before ) * 4096, '<', 8 * 1024 * 1024,
    'repeated JSON success/failure bounded retention' );
done_testing;
