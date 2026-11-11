use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use Scalar::Util ();

# Model accessors return independent copies of composite values.
my $m = Webmania::Models::Api2MonitorDocuments::MonitorImportStatus->new(
    uuid        => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    status      => 'concluido',
    processado  => 1,
    importados  => [ { arquivo => 'a.xml', uuid => 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } ],
    descartados => []
);
my $copy = $m->get('importados');
my $first = $copy->[0];
if ( Scalar::Util::blessed($first) ) { $first->{values}{arquivo} = 'changed' }
else                                 { $first->{arquivo} = 'changed' }
push @$copy, 'not a valid item';
is( scalar @{ $m->get('importados') }, 1, 'get returns a copy: list growth does not reach the model' );
is( $m->as_hash->{importados}[0]{arquivo}, 'a.xml', 'get returns a deep copy: nested changes do not reach the model' );
is( $m->as_hash->{importados}[0]{arquivo}, 'a.xml', 'as_hash keeps the validated state' );

# FILE-07: only the legacy report route accepts text/xml, classified by its bytes.
open my $wb, '<:raw', 't/fixtures/catalog49/canonical-workbook.xlsx' or die $!;
my $workbook = do { local $/; <$wb> };
close $wb;
my $xlsx   = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
my $latin1 = "numero;destinatario\r\n1;Jo\xe3o\r\n";
my $csv    = Webmania::Files::report( 200, 'text/xml', $latin1, ['text/xml'], undef, 1 );
is( $csv->bytes,      $latin1,    'legacy CSV labeled text/xml is byte-exact, Latin-1 included' );
is( $csv->media_type, 'text/csv', 'legacy CSV detected type' );
is( Webmania::Files::report( 200, 'text/xml', $workbook, ['text/xml'], undef, 1 )->media_type,
    $xlsx, 'legacy XLSX labeled text/xml identified by the ZIP signature' );
for my $bad ( '<?xml version="1.0"?><nfeProc><NFe/></nfeProc>', '<!doctype html><html></html>', '  {"error":"x"}' ) {
    my $ok = eval { Webmania::Files::report( 200, 'text/xml', $bad, ['text/xml'], undef, 1 ); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'protocol', 'legacy report refuses XML, HTML and JSON bodies' );
}
my $ok = eval { Webmania::Files::result( 200, 'text/xml', $latin1, ['text/xml'] ); 1 };
ok( !$ok, 'other file operations gain no text/xml tolerance' );
is( Webmania::Files::report( 200, 'text/html', '<html><body>r</body></html>', ['text/html'], undef, 0 )->kind,
    'html', 'current report HTML rendering kept as bytes' );
$ok = eval { Webmania::Files::report( 200, 'application/zip', 'not a zip', ['application/zip'], undef, 0 ); 1 };
ok( !$ok, 'declared report format must match its bytes' );

# A cancellation signaled while a report is inspected is never returned as success.
{
    package Webmania::Test::LateCancel;    # cancelled once more than `after` guard checks happened
    our @ISA = ('Webmania::Cancel');
    sub cancelled { ++$_[0]{checks} > $_[0]{after} }
}
sub late_guard { { options => { cancel => bless( { after => $_[0], checks => 0 }, 'Webmania::Test::LateCancel' ) }, deadline => Webmania::Transport::now() + 60 } }
my $big_csv = "numero;valor\n" . ( "1;2\n" x 20000 );
for my $c ( [ 'text/csv', $big_csv ], [ 'text/html', '<html><body>r</body></html>' ], [ 'application/octet-stream', "\x01synthetic" ],
    [ 'application/xml', '<?xml version="1.0"?><r/>' ] )
{
    my ( $media, $raw ) = @$c;
    $ok = eval { Webmania::Files::report( 200, $media, $raw, [$media], late_guard(1), 0 ); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'cancelled', "report $media checks the guard before returning" );
}
my $guard = late_guard(1e9);
is( Webmania::Files::report( 200, 'text/csv', $big_csv, ['text/csv'], $guard, 0 )->kind, 'csv', 'CSV report accepted while not cancelled' );
cmp_ok( $guard->{options}{cancel}{checks}, '>', 3, 'CSV scan consults the guard block by block' );
for my $route ( [ report => sub { Webmania::Files::report( 200, 'text/csv', $big_csv, ['text/csv'], $_[0], 0 ) } ],
    [ result => sub { Webmania::Files::result( 200, 'text/csv', $big_csv, ['text/csv'], $_[0] ) } ] )
{
    $ok = eval { $route->[1]->( late_guard(2) ); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'cancelled', "$route->[0] stops the CSV scan when cancelled midway" );
}

# Wire: legacy report and current report downloads, capability only, no replay.
my $nfe_xml = '<?xml version="1.0"?><!-- ' . ( 'synthetic ' x 2400 ) . '--><nfeProc><NFe/></nfeProc>';
my $chunked = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nTransfer-Encoding: chunked\r\n\r\n"
  . join( '', map { "1\r\n$_\r\n" } split //, $nfe_xml ) . "0\r\n\r\n";
ok( length($chunked) > 65536, 'chunk-size lines exceed one header budget' );
my $oversized = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nTransfer-Encoding: chunked\r\n\r\n1;" . ( 'x' x 5000 ) . "\r\nA\r\n0\r\n\r\n";
my $server = TestServer->new(
    [
        TestServer::response( $latin1, 200, 'text/xml' ),
        TestServer::response( $latin1, 200, 'text/csv' ),
        TestServer::response( { error => 'processando' }, 200, 'application/json' ),
        $chunked, $oversized
    ]
);
my %a     = ( base_url => $server->base, ca_file => $server->ca, options => { timeout => 3 }, trusted_origins => [ $server->base ] );
my $files = Webmania::NfeFilesClient->new(%a);
my $uuid  = '00000000-0000-4000-8000-000000000123';
my $legacy = $files->download_report( uuid => $uuid, auth => Webmania::FileAuth->new( mode => 'capability' ) );
is( $legacy->media_type, 'text/csv', 'legacy report over the wire classified by bytes' );
my $reports = Webmania::ReportFilesClient->new(%a);
is( $reports->download_report_v2( uuid => $uuid, auth => Webmania::FileAuth->new( mode => 'anonymous' ) )->bytes,
    $latin1, 'current report downloaded byte-exact' );
$ok = eval { $reports->download_report_v2( uuid => $uuid, auth => Webmania::FileAuth->new( mode => 'anonymous' ) ); 1 };
ok( !$ok && $@->kind eq 'business', 'JSON error at HTTP 200 is a failure, never a file' );
my $company = Webmania::CompanyCredentials->new(
    consumer_key        => 'k', consumer_secret => 's',
    access_token        => 'a', access_token_secret => 't'
);
my $xmlfiles = Webmania::NfeFilesClient->new( credentials => $company, %a );
is( $xmlfiles->download_xml( identifier => $uuid, auth => Webmania::FileAuth->new( mode => 'company' ) )->bytes,
    $nfe_xml, 'HTTP-05: many chunk-size lines deliver the body byte-exact' );
$ok = eval { $xmlfiles->download_xml( identifier => $uuid, auth => Webmania::FileAuth->new( mode => 'company' ) ); 1 };
ok( !$ok && $@->kind eq 'protocol', 'HTTP-05: one oversized chunk-size line is a protocol error' );
my $records = $server->records;
is( scalar @$records, 5, 'each call is one request; nothing replayed' );
ok( !grep( { exists $_->{headers}{'x-consumer-key'} || exists $_->{headers}{authorization} } @$records[ 0 .. 2 ] ),
    'report downloads send no credentials' );
$server->stop;
done_testing;
