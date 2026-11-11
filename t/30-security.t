use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use Time::HiRes qw(time alarm sleep);
use POSIX       qw(WNOHANG);

sub caught {
    my ( $code, $kind, $name ) = @_;
    my $ok = eval { $code->(); 1 };
    my $e  = $@;
    ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq $kind, $name ) or diag("$e");
    $e;
}
my $valid     = TestServer::response('{"expiration":1}');
my @responses = (
    "HTTP/1.1 103 Hints\r\nLink: </style>\r\n\r\n" . $valid,
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nContent-Length: 16\r\n\r\n{\"expiration\":1}",
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nTransfer-Encoding: chunked\r\n\r\n",
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"expiration\":1}\r\n0\r\nX-Safe: yes\r\n\r\n",
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 101 Switch\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999999\r\n\r\n",
    TestServer::response('{"expiration":1,"expiration":2}'),
    TestServer::response('{"expiration":-1}'),
    TestServer::response( '{"error":"synthetic-company-secret private-label-123 9007199254740993"}', 400 ),
    TestServer::response( '{"error":"refused"}',                                                     500 ),
    TestServer::response(
        '{}',
        302,
        'application/json',
'Location: https://files.example.test/file/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa?token=capability-secret'
    ),
"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nX-Correlation-Id: safe-correlation\r\n\r\n2\r\n{}\r\n0\r\nLocation: https://files.example.test/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa?token=x\r\n",
    [ [0.25], $valid ],
    [ [0.25], $valid ],
);
my $s = TestServer->new( \@responses );
my $p = $s->pool;
my $n = $p->{Nfe};
isa_ok( $n->get_certificate_validity, 'Webmania::Model', 'informational response consumed' );
caught( sub { $n->get_certificate_validity }, 'protocol', 'duplicate singleton length' );
caught( sub { $n->get_certificate_validity }, 'protocol', 'TE and CL conflict' );
isa_ok( $n->get_certificate_validity, 'Webmania::Model', 'chunked plus safe trailer succeeds' );
caught( sub { $n->get_certificate_validity }, 'protocol',        'forbidden trailer rejected' );
caught( sub { $n->get_certificate_validity }, 'protocol',        'switching protocol rejected' );
caught( sub { $n->get_certificate_validity }, 'body_limit',      'declared oversize body rejected' );
caught( sub { $n->get_certificate_validity }, 'protocol',        'duplicate response JSON keys rejected' );
caught( sub { $n->get_certificate_validity }, 'response_schema', 'response numeric constraint applied' );
my $e = caught(
    sub {
        $n->update_company(
            body => { ID => 'private-label-123', extension => Webmania::number('9007199254740993') } );
    },
    'http',
    'HTTP error preserves safe envelope'
);
unlike(
    Webmania::JSON::encode_json( $e->details ),
    qr/synthetic-company-secret|private-label-123|9007199254740993/,
    'credentials and fiscal strings/numbers redacted'
);
$e = caught( sub { $n->update_company( body => { ID => 'ordinary-selector-123' } ) },
    'http', 'mutation 500 fails once' );
is( $e->outcome, 'unknown', 'mutation server failure is uncertain' );
is( $e->recovery->value->{ID},
    'ordinary-selector-123', 'ordinary selector recovery requires explicit sensitive access' );
$e = caught( sub { $n->update_company( body => { uuid => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } ) },
    'redirect', 'redirect refused without follow' );
is( $e->outcome, 'unknown', 'mutation redirect is uncertain' );
ok( !defined $e->recovery, 'Location capability suppresses matching recovery' );
unlike( "" . $e->location, qr/capability-secret|aaaa/, 'redirect location hidden by default' );
$e = caught( sub { $n->update_company( body => { uuid => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } ) },
    'protocol', 'incomplete trailers rejected' );
ok(
    !defined $e->recovery && !defined $e->correlation_id,
    'incomplete trailers suppress recovery and correlation'
);
my $start = time;
$e =
  caught( sub { $n->update_company( body => { ID => 'timeout-selector' }, options => { timeout => .06 } ) },
    'timeout', 'body wait total deadline' );
cmp_ok( time - $start, '<', .3, 'deadline promptly returns' );
is( $e->outcome, 'unknown', 'timeout after write is uncertain' );
sleep(.25);
my $cancel = Webmania::Cancel->new;
{
    local $SIG{ALRM} = sub { $cancel->cancel };
    alarm(.06);
    $e = caught(
        sub {
            $n->update_company(
                body    => { ID      => 'cancel-selector' },
                options => { timeout => 1, cancel => $cancel }
            );
        },
        'cancelled',
        'cancellation while reading'
    );
    alarm(0)
}
is( $e->outcome, 'unknown', 'cancellation after write is uncertain' );
sleep(.25);
is( scalar @{ $s->records }, 15, 'no implicit redirects or retries across failures' );
$s->stop;
my $pre = Webmania::Cancel->new;
$pre->cancel;
caught( sub { $n->get_certificate_validity( options => { cancel => $pre } ) },
    'cancelled', 'pre-cancelled call has no I/O' );
$n->close;
caught( sub { $n->get_certificate_validity }, 'closed', 'closed client rejected' );
my $tls       = TestServer->new( [$valid] );
my $untrusted = Webmania::NfeClient->new(
    credentials => Webmania::CompanyCredentials->new(
        consumer_key        => 'a',
        consumer_secret     => 'b',
        access_token        => 'c',
        access_token_secret => 'd'
    ),
    base_url => $tls->base,
    options  => { timeout => .5 }
);
caught( sub { $untrusted->get_certificate_validity }, 'tls', 'untrusted certificate rejected' );
is( scalar @{ $tls->records }, 0, 'untrusted TLS sends no HTTP' );
$tls->stop;
my $cn       = TestServer->new( [$valid], cn_only => 1, cn => '127.0.0.1' );
my $cnclient = $cn->pool->{Nfe};
caught( sub { $cnclient->get_certificate_validity },
    'tls', 'CN-only certificate rejected despite trusted CA' );
is( scalar @{ $cn->records }, 0, 'CN-only TLS sends no HTTP' );
$cn->stop;
my $wrong = TestServer->new( [$valid], san => 'DNS:wrong.example.test' );
caught( sub { $wrong->pool->{Nfe}->get_certificate_validity }, 'tls', 'SAN hostname mismatch rejected' );
is( scalar @{ $wrong->records }, 0, 'mismatched TLS sends no HTTP' );
$wrong->stop;

# Resolver stall and cancellation are tested inside its owned subprocess. No
# resolver hook is part of the public API, and no process-wide alarm is used by SDK.
my $context = {
    options  => Webmania::Transport::options( { timeout => .06 } ),
    deadline => Webmania::Transport::now() + .06
};
{
    no warnings 'redefine';
    local *Webmania::Transport::getaddrinfo = sub { sleep(5); return ('synthetic failure') };
    $start = time;
    caught( sub { Webmania::Transport::_resolve( 'synthetic.test', 443, $context ) },
        'timeout', 'stalled DNS honors total deadline' );
    cmp_ok( time - $start, '<', .3, 'stalled resolver promptly killed and reaped' )
}
is( waitpid( -1, WNOHANG ), -1, 'no resolver child retained after timeout' );
my $r = Webmania::Redactor->new( [ 'abcdefgh', 'defghijk', '1' ] );
is( $r->text('abcdefghijk'), '[redacted]', 'overlap ranges merge' );
is(
    $r->text('0.1 -1 1 10'),
    '0.1 -1 [redacted] 10',
    'short numeric literal matching respects alphanumeric boundaries'
);
done_testing;
