use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use File::Temp qw(tempdir);
use JSON::PP ();

# The neutral homologation example against a loopback fixture: masked lines, ledger, no replay.
my $main = 'examples/homologacao/main.pl';
my %secrets = ( WEBMANIA_CONSUMER_KEY => 'example-key-value', WEBMANIA_CONSUMER_SECRET => 'example-secret-value',
    WEBMANIA_ACCESS_TOKEN => 'example-access-value', WEBMANIA_ACCESS_TOKEN_SECRET => 'example-access-secret-value',
    WEBMANIA_ISSUER_TOKEN => 'example-issuer-value' );
my $libs = join ':', grep { !ref } @INC;
sub run_example {
    my (%env) = @_;
    local %ENV = ( PATH => $ENV{PATH}, PERL5LIB => $libs, %env );
    my $out = `$^X $main 2>&1`;
    ( $? >> 8, $out );
}
my ( $rc, $out ) = run_example(%secrets);
is( $rc, 77, 'without WEBMANIA_LIVE=1 the example is blocked' );
is( $out, qq({"result":"blocked"}\n), 'blocked marker printed' );

my $corpus = Webmania::Schema::readfile('t/fixtures/operations.json');
my %case   = map { $_->{operation} => $_ } @{ $corpus->{cases} };
my ( $nfe, $nfse ) = ( '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2' );
open my $p, '<:raw', 't/fixtures/catalog49/canonical-plain.pdf' or die $!;
my $pdf = do { local $/; <$p> };
close $p;
my $xml = '<?xml version="1.0"?><nfeProc><NFe/></nfeProc>';
my %nfse_doc = ( %{ $case{emitterGetNfse}{response} }, uuid => $nfse, pdf_nfse => 'ok' );
my @responses = (
    TestServer::response( { status => 'online' } ),
    TestServer::response( { expiration => 30 } ),
    TestServer::response( [] ),
    TestServer::response( $case{emitterGetNfseProviderStatus}{response} ),
    TestServer::response( { uuid => $nfe, status => 'processando' } ),
    TestServer::response( { uuid => $nfe, status => 'aprovado' } ),
    TestServer::response( [ { uuid => $nfe, status => 'aprovado' } ] ),
    TestServer::response( $pdf, 200, 'application/pdf' ),
    TestServer::response( $pdf, 200, 'application/pdf' ),
    TestServer::response( $xml, 200, 'text/xml' ),
    TestServer::response( { status => 'cancelado' } ),
    TestServer::response( { uuid => $nfe, status => 'cancelado' } ),
    TestServer::response( $xml, 200, 'text/xml' ),
    TestServer::response( { %{ $case{emitterIssueNfse}{response} }, uuid => $nfse, status => 'processando' } ),
    TestServer::response( { %nfse_doc, status => 'aprovado' } ),
    TestServer::response( '<?xml version="1.0"?><CompNfse/>', 200, 'text/xml' ),
    TestServer::response( $pdf, 200, 'application/pdf' ),
    TestServer::response( { %{ $case{emitterCancelNfse}{response} }, uuid => $nfse, status => 'cancelado' } ),
    TestServer::response( { %nfse_doc, status => 'cancelado' } ),
);
my $server = TestServer->new( \@responses );
my $dir    = tempdir( CLEANUP => 1 );
my $json   = JSON::PP->new->canonical;
open my $f1, '>:raw', "$dir/nfe.json"  or die; print $f1 Webmania::JSON::encode_json( { %{ $case{nfeIssueDocument}{request} }, ambiente => 2 } ); close $f1;
open my $f2, '>:raw', "$dir/nfse.json" or die; print $f2 Webmania::JSON::encode_json( { %{ $case{emitterIssueNfse}{request} }, ambiente => 2 } ); close $f2;
( $rc, $out ) = run_example(
    %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => 'all', WEBMANIA_API1_BASE_URL => $server->base . '/api',
    WEBMANIA_FILES_BASE_URL => $server->base, WEBMANIA_API2_BASE_URL => $server->base, WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1',
    WEBMANIA_CA_FILE => $server->ca, WEBMANIA_LIVE_LEDGER => "$dir/ledger.jsonl",
    WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/nfe.json", WEBMANIA_LIVE_NFSE_PAYLOAD => "$dir/nfse.json"
);
is( $rc, 0, 'full cycle succeeds' ) or diag $out;
my @lines = map { $json->decode($_) } grep { length } split /\n/, $out;
ok( !grep( { !$_->{ok} } @lines ), 'every step ok' );
my %steps = map { $_->{step} => 1 } @lines;
ok( $steps{$_}, "step $_ present" ) for qw(readonly.sefaz readonly.nfse_provider nfe.issue nfe.cancel nfe.cancellation_xml nfse.issue nfse.cancel nfse.pdf);
my $base = $server->base;
ok( !grep( { index( $out, $_ ) >= 0 } values(%secrets), $nfe, $nfse, $base ), 'no credential, identifier or origin printed' );
open my $l, '<', "$dir/ledger.jsonl" or die;
my @entries = map { $json->decode($_) } <$l>;
close $l;
is_deeply( [ sort map { "$_->{model}:$_->{identifier}" } grep { $_->{operation} =~ /Issue/ } @entries ], [ "nfe:$nfe", "nfse:$nfse" ], 'ledger records each document' );
is_deeply( [ map { $_->{status} } grep { $_->{operation} =~ /Cancel/ } @entries ], [ 'cancelado', 'cancelado' ], 'ledger records cancellation' );
my $records = $server->records;
is( scalar( grep { $_->{method} eq 'POST' && $_->{path} =~ m{\A(?:/api/1/nfe/emissao/|/2/nfse/emissao)\z} } @$records ), 2, 'each document issued exactly once' );
$server->stop;

# An unknown cancellation outcome stops the run, is recorded in the ledger and is never repeated.
my @readonly = @responses[ 0 .. 3 ];
for my $c (
    [ 'nfe', 'nfeCancelDocument', $nfe, qr{\A/api/1/nfe/cancelar/\z}, @responses[ 4 .. 9 ] ],
    [ 'nfse', 'emitterCancelNfse', $nfse, qr{\A/2/nfse/cancelar\z}, @responses[ 13 .. 16 ] ] )
{
    my ( $scope, $operation, $id, $path, @cycle ) = @$c;
    my $unknown = TestServer->new( [ @readonly, @cycle, TestServer::response( { error => 'controlled failure' }, 500 ) ] );
    unlink "$dir/ledger.jsonl";
    ( $rc, $out ) = run_example(
        %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => $scope, WEBMANIA_API1_BASE_URL => $unknown->base . '/api',
        WEBMANIA_FILES_BASE_URL => $unknown->base, WEBMANIA_API2_BASE_URL => $unknown->base, WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1',
        WEBMANIA_CA_FILE => $unknown->ca, WEBMANIA_LIVE_LEDGER => "$dir/ledger.jsonl",
        WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/nfe.json", WEBMANIA_LIVE_NFSE_PAYLOAD => "$dir/nfse.json"
    );
    is( $rc, 1, "$scope: unknown cancellation ends with 1" ) or diag $out;
    my @steps = map { $json->decode($_) } grep { length } split /\n/, $out;
    ok( grep( { $_->{step} eq "$scope.cancel" && !$_->{ok} && ( $_->{outcome} // '' ) eq 'unknown' } @steps ), "$scope: cancel reported unknown" );
    open my $u, '<', "$dir/ledger.jsonl" or die;
    my @ledger = map { $json->decode($_) } <$u>;
    close $u;
    is_deeply( $ledger[-1], { model => $scope, identifier => $id, status => 'unknown', operation => $operation },
        "$scope: ledger records the unknown cancellation" );
    is( scalar( grep { $_->{path} =~ $path } @{ $unknown->records } ), 1, "$scope: cancellation sent exactly once" );
    $unknown->stop;
}
( $rc, $out ) = run_example( %secrets, WEBMANIA_LIVE => 1, WEBMANIA_API1_BASE_URL => 'https://other.example.invalid/api', WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1' );
is( $rc, 77, 'origin outside the allowed hosts is blocked' );

# Without an allow list no origin is trusted: blocked before credentials or any request.
my $silent = TestServer->new( [ TestServer::response( { error => 'unexpected' }, 500 ) ] );
for my $hosts ( undef, ' , ' ) {
    ( $rc, $out ) = run_example( %secrets, WEBMANIA_LIVE => 1, WEBMANIA_API1_BASE_URL => $silent->base . '/api',
        WEBMANIA_FILES_BASE_URL => $silent->base, WEBMANIA_API2_BASE_URL => $silent->base,
        defined $hosts ? ( WEBMANIA_LIVE_ALLOWED_HOSTS => $hosts ) : () );
    is( $rc, 77, 'missing or empty allow list is blocked' );
    is( $out, qq({"reason":"allowed_hosts","result":"blocked"}\n), 'allow-list reason printed' );
}
is( scalar @{ $silent->records }, 0, 'no request without an allow list' );

# Only a decoded top-level integer 2 passes the ambiente guard.
for my $doc ( '{"ambiente":"2"}', '{"amb\\u0069ente":1,"pedido":{"ambiente":2}}', '{"pedido":{"ambiente":2}}' ) {
    open my $fh, '>:raw', "$dir/guard.json" or die; print $fh $doc; close $fh;
    ( $rc, $out ) = run_example( %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => 'nfe', WEBMANIA_API1_BASE_URL => $silent->base . '/api',
        WEBMANIA_FILES_BASE_URL => $silent->base, WEBMANIA_API2_BASE_URL => $silent->base, WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1',
        WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/guard.json" );
    is( $rc, 77, "ambiente guard blocks $doc" );
    is( $out, qq({"reason":"payload","result":"blocked"}\n), 'payload reason printed' );
}
is( scalar @{ $silent->records }, 0, 'no request for a payload outside homologation' );

# A mutation scope needs a writable ledger (unset, empty, a directory, a missing parent): 77, no request.
for my $scope (qw(nfe nfse all)) {
    for my $c ( [ 'unset', undef ], [ 'empty', '' ], [ 'a directory', $dir ], [ 'a missing parent', "$dir/absent/ledger.jsonl" ] ) {
        my ( $label, $ledger ) = @$c;
        ( $rc, $out ) = run_example( %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => $scope, WEBMANIA_API1_BASE_URL => $silent->base . '/api',
            WEBMANIA_FILES_BASE_URL => $silent->base, WEBMANIA_API2_BASE_URL => $silent->base, WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1',
            WEBMANIA_CA_FILE => $silent->ca, WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/nfe.json", WEBMANIA_LIVE_NFSE_PAYLOAD => "$dir/nfse.json",
            defined $ledger ? ( WEBMANIA_LIVE_LEDGER => $ledger ) : () );
        is( $rc, 77, "$scope: ledger $label is blocked" );
        is( $out, qq({"reason":"ledger","result":"blocked"}\n), "$scope: ledger reason printed for $label" );
    }
}
ok( !-e "$dir/absent", 'the missing parent is not created' );
is( scalar @{ $silent->records }, 0, 'no request without a writable ledger' );
$silent->stop;

# A ledger record that cannot be written (a full device) fails the run; the approved NF-e is still cancelled once.
SKIP: {
    skip 'no /dev/full on this system', 3 unless -e '/dev/full';
    my $full = TestServer->new( [ @responses[ 0 .. 12 ] ] );
    ( $rc, $out ) = run_example( %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => 'nfe', WEBMANIA_API1_BASE_URL => $full->base . '/api',
        WEBMANIA_FILES_BASE_URL => $full->base, WEBMANIA_API2_BASE_URL => $full->base, WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1',
        WEBMANIA_CA_FILE => $full->ca, WEBMANIA_LIVE_LEDGER => '/dev/full', WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/nfe.json" );
    is( $rc, 1, 'an unwritable ledger record fails the run' ) or diag $out;
    my @kinds = map { $_->{kind} } grep { $_->{step} eq 'ledger' } map { $json->decode($_) } grep { length } split /\n/, $out;
    ok( @kinds && !grep( { $_ ne 'ledger_unwritable' } @kinds ), 'each failed record is reported' ) or diag $out;
    my $seen = $full->records;
    is_deeply( [ map { my $p = $_; scalar grep { $_->{path} eq $p } @$seen } '/api/1/nfe/emissao/', '/api/1/nfe/cancelar/' ], [ 1, 1 ],
        'issued and cancelled exactly once' );
    $full->stop;
}

# An accepted cancellation whose consult never shows 'cancelado' fails the run; the consult
# waits are skipped here (same example, sleep replaced) so every attempt runs at once.
my @stuck_nfe  = map { TestServer::response( { uuid => $nfe, status => 'aprovado' } ) } 1 .. 24;
my @stuck_nfse = map { TestServer::response( { %nfse_doc, status => 'aprovado' } ) } 1 .. 24;
my $stuck = TestServer->new( [ @responses[ 0 .. 10 ], @stuck_nfe, @responses[ 13 .. 17 ], @stuck_nfse ] );
unlink "$dir/ledger.jsonl";
{
    local %ENV = ( PATH => $ENV{PATH}, PERL5LIB => $libs, %secrets, WEBMANIA_LIVE => 1, WEBMANIA_LIVE_SCOPE => 'all',
        WEBMANIA_API1_BASE_URL => $stuck->base . '/api', WEBMANIA_FILES_BASE_URL => $stuck->base, WEBMANIA_API2_BASE_URL => $stuck->base,
        WEBMANIA_LIVE_ALLOWED_HOSTS => '127.0.0.1', WEBMANIA_CA_FILE => $stuck->ca, WEBMANIA_LIVE_LEDGER => "$dir/ledger.jsonl",
        WEBMANIA_LIVE_NFE_PAYLOAD => "$dir/nfe.json", WEBMANIA_LIVE_NFSE_PAYLOAD => "$dir/nfse.json" );
    my $no_wait = 'BEGIN { *CORE::GLOBAL::sleep = sub { 0 } } $0 = shift; do "./$0"; die $@ if $@';
    open my $ph, '-|', $^X, '-e', $no_wait, $main or die "example: $!";
    $out = do { local $/; <$ph> } // '';
    close $ph;
    $rc = $? >> 8;
}
is( $rc, 1, 'a document that never shows cancelado fails the run' ) or diag $out;
my @stuck_lines = map { $json->decode($_) } grep { length } split /\n/, $out;
for ( [ 'nfe', 'nfeGetDocument' ], [ 'nfse', 'emitterGetNfse' ] ) {
    my ( $model, $operation ) = @$_;
    my @verdict = grep { $_->{step} eq "$model.consult_cancelled" && !$_->{ok} } @stuck_lines;
    is( scalar @verdict, 1, "$model: one failed final consult" ) or diag $out;
    is_deeply( [ $verdict[0]{operation}, $verdict[0]{kind} ], [ $operation, 'not_cancelled' ], "$model: final consult reported not_cancelled" );
}
ok( !grep( { $_->{step} eq 'nfe.cancellation_xml' } @stuck_lines ), 'no cancellation XML without cancelado' );
is( scalar( grep { $_->{path} =~ m{\A(?:/api/1/nfe/cancelar/|/2/nfse/cancelar)\z} } @{ $stuck->records } ), 2, 'each cancellation sent once' );
$stuck->stop;
done_testing;
