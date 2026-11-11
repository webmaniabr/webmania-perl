use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;

sub caught {
    my ( $call, $kind, $label ) = @_;
    my $ok = eval { $call->(); 1 };
    my $e  = $@;
    ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq $kind, $label ) or diag("$e");
    $e;
}
my $uuid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
my $json = '{"status":"online","STATUS":"extra","message":{"extra":true}}';
my @wire = (
    "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" . $json,
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999\r\n\r\n{}",
    TestServer::response($json)
);
push @wire,
  map { TestServer::response( '{"status":"online","error":' . $_ . '}' ) }
  ( 'false', 'null', '0', '""', '[]', '{}' );
push @wire,
  TestServer::response( '{}', 302, 'application/json', 'Location: /protected/report?token=literal-secret' );
push @wire,
  "HTTP/1.1 103 Hint\r\nLocation: https://files.example.test/file/$uuid\r\n\r\n"
  . TestServer::response( '{"error":"' . uc($uuid) . '"}',
    500, 'application/json', 'X-Correlation-Id: ' . uc($uuid) );
push @wire, TestServer::response( '{"error":"pending"}', 500 );
push @wire, TestServer::response( '{"error":"pending"}', 500 );
my $s = TestServer->new( \@wire );
my $p = $s->pool;
my $n = $p->{Nfe};
my $r = $n->get_sefaz_status;
is( $r->status,        'online', 'EOF-delimited HTTP1.0 success' );
is( $r->get('STATUS'), 'extra',  'case-distinct response extension preserved' );
ok( ref( $r->get('message') ) eq 'HASH', 'valid open success branch preserves message object' );
caught( sub { $n->get_sefaz_status }, 'protocol', 'truncated CL response fails' );
isa_ok( $n->get_sefaz_status, 'Webmania::Model', 'subsequent native call succeeds once' );

for ( 1 .. 6 ) {
    caught( sub { $n->get_sefaz_status }, 'business', 'presence of error discriminator always fails' );
}
my $f = $p->{EmitterFiles}
  ->get_nfse_pdf( identifier => $uuid, auth => Webmania::FileAuth->new( mode => 'anonymous' ) );
isa_ok( $f, 'Webmania::FileRedirect', 'documented relative Location' );
is(
    $f->location->value,
    '/protected/report?token=literal-secret',
    'relative metadata preserved for explicit access'
);
my $e = caught( sub { $n->update_company( body => { uuid => $uuid } ) },
    'http', 'informational Location context survives final error' );
ok( !defined $e->recovery, 'informational capability suppresses recovery' );
unlike( $e->correlation_id, qr/aaaaaaaa/i, 'informational capability redacts equivalent correlation' );
unlike( Webmania::JSON::encode_json( $e->details ),
    qr/aaaaaaaa/i, 'informational capability redacts equivalent body' );
$e = caught( sub { $p->{Monitor}->get_document( fd => $uuid, query => { atualizar_status => 1 } ) },
    'http', 'conditional effectful GET failure' );
is( $e->outcome, 'unknown', 'actual status refresh GET is uncertain' );
$e = caught( sub { $p->{Monitor}->get_document( fd => $uuid, query => { atualizar_status => 0 } ) },
    'http', 'passive GET control failure' );
ok( !defined $e->outcome, 'passive GET remains nonmutating' );
is( scalar @{ $s->records }, 13, 'all calls transfer once; redirect not followed' );
$s->stop;
my $red = Webmania::Redactor->new;
$red->observe_location( 'https://files.example.test/file?token=' . $uuid );
is( $red->text( uc $uuid ), uc $uuid,     'opaque query token keeps literal case semantics' );
is( $red->text($uuid),      '[redacted]', 'opaque exact token is protected' );
my $auth = Webmania::Redactor->new;
$auth->observe_location('https://user%3Aprivatepass%40malformed.test/path');
unlike( $auth->text('privatepass'), qr/privatepass/, 'malformed encoded userinfo remains protected' );

for my $policy (
    [ 'TLSv12', 'HIGH:!aNULL:!eNULL', 1 ],
    [ 'TLSv12', 'aNULL:@SECLEVEL=0',  0 ],
    [ 'TLSv12', 'eNULL:@SECLEVEL=0',  0 ]
  )
{
    my ( $version, $cipher, $good ) = @$policy;
    my $t = TestServer->new( [ TestServer::response('{"expiration":1}') ],
        ssl_options => { SSL_version => $version, SSL_cipher_list => $cipher } );
    my $c = $t->pool->{Nfe};
    if ($good) { isa_ok( $c->get_certificate_validity, 'Webmania::Model', 'authenticated TLS1.2 positive' ) }
    else {
        caught( sub { $c->get_certificate_validity }, 'tls', 'anonymous/NULL TLS suite refused' );
        is( scalar @{ $t->records }, 0, 'weak-suite server gets no HTTP' );
    }
    $t->stop;
}
done_testing;
