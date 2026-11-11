use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;

sub caught {
    my ( $call, $kind, $name ) = @_;
    my $ok = eval { $call->(); 1 };
    my $e  = $@;
    ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq $kind, $name ) or diag("$e");
    $e;
}
my $uuid     = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
open my $pdf_handle, '<:raw', 't/fixtures/catalog49/canonical-plain.pdf' or die $!;
my $pdf = do { local $/; <$pdf_handle> }; close $pdf_handle;
my @response = (
    TestServer::response( $pdf,                   200, 'application/pdf' ),
    TestServer::response( $pdf,                   201, 'application/pdf' ),
    TestServer::response( '<html>pending</html>', 200, 'text/html' ),
    TestServer::response( '{"error":null}',       200 ),
    TestServer::response(
        '{}', 302, 'application/json', 'Location: https://files.example.test/protected?token=opaque-secret'
    ),
    TestServer::response( $pdf,                  200, 'application/pdf' ),
    TestServer::response( $pdf,                  200, 'application/pdf' ),
    TestServer::response( '{"error":"pending"}', 500 ),
    TestServer::response( '{"error":"pending"}', 500 ),
    TestServer::response( { uuid => $uuid, status => 'processando' } )
);
my $s      = TestServer->new( \@response );
my $p      = $s->pool;
my $f      = $p->{EmitterFiles};
my $issuer = Webmania::FileAuth->new( mode => 'issuer' );
my $r      = $f->get_nfse_pdf( identifier => $uuid, auth => $issuer );
isa_ok( $r, 'Webmania::FileResponse' );
is( $r->bytes, $pdf, 'fiscal PDF bytes exact' );
caught( sub { $f->get_nfse_pdf( identifier => $uuid, auth => $issuer ) },
    'protocol', 'undocumented successful file status refused' );
caught( sub { $f->get_nfse_pdf( identifier => $uuid, auth => $issuer ) },
    'protocol', 'HTML is not file readiness' );
caught( sub { $f->get_nfse_pdf( identifier => $uuid, auth => $issuer ) },
    'business', '200 JSON error presence is failure' );
my $redirect = $f->get_nfse_pdf( identifier => $uuid, auth => $issuer );
isa_ok( $redirect, 'Webmania::FileRedirect' );
is(
    $redirect->location->value,
    'https://files.example.test/protected?token=opaque-secret',
    'absolute redirect metadata preserved explicitly'
);
unlike( "$redirect", qr/opaque-secret/, 'redirect default display private' );
$f->get_nfse_pdf(
    identifier => $uuid,
    auth       => Webmania::FileAuth->new( mode => 'document_token', token => 'document-secret' )
);
$f->get_nfse_pdf( identifier => $uuid, auth => Webmania::FileAuth->new( mode => 'anonymous' ) );
my $e = caught( sub { $f->get_nfse_pdf( identifier => $uuid, auth => $issuer ) },
    'http', 'effectful file GET provider failure' );
is( $e->outcome, 'unknown', 'declared effectful file GET gets uncertainty' );
$e = caught( sub { $p->{Nfe}->update_company( body => { uuid => $uuid } ) },
    'http', 'mutation recovery source failure' );
my $selector = $e->recovery->value;
my $result   = $p->{Nfe}->get_document( query => $selector );
is( $result->uuid, $uuid, 'protected ordinary selector reused for one actual consultation' );
my $records = $s->records;
is( scalar @$records, 10, 'no auth fallback, redirect transfer or mutation replay' );
ok( !exists $records->[5]{headers}{authorization}, 'document token mode carries no stored bearer' );
like( $records->[5]{path},
    qr/token=document-secret/, 'explicit document token is sent only in intended query' );
ok( !exists $records->[6]{headers}{authorization}, 'anonymous mode carries no stored bearer' );
$s->stop;
done_testing;
