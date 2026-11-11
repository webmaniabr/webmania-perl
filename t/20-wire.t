use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
my $corpus = Webmania::Schema::readfile('t/fixtures/operations.json');
my @cases  = @{ $corpus->{cases} };
my $xml    = '<?xml version="1.0"?><nfeProc><NFe/></nfeProc>';
open my $pdf_handle, '<:raw', 't/fixtures/catalog49/canonical-plain.pdf' or die $!;
my $pdf = do { local $/; <$pdf_handle> }; close $pdf_handle;
my $zip    = "PK\x05\x06" . ( "\0" x 18 );
my @responses;

for my $c (@cases) {
    next unless $c->{enabled};
    push @responses,
      TestServer::response(
        $c->{binary}
        ? ( $c->{media_type} eq 'application/pdf' ? $pdf : $c->{media_type} =~ /xml/ ? $xml : $zip )
        : $c->{response},
        "$c->{status}", $c->{media_type}
      );
}
my $server = TestServer->new( \@responses );
my $pool   = $server->pool;
my $count  = 0;
for my $c (@cases) {
    my $client = $pool->{ $c->{client} };
    my $m      = $c->{method};
    my %a      = ( %{ $c->{path_params} }, query => $c->{query} );
    $a{body} = $c->{request} if $c->{has_request};
    $a{auth} = Webmania::FileAuth->new(
          mode => $c->{operation} eq 'fiscalDownloadReport' ? 'capability'
        : $c->{client} eq 'NfeFiles' ? 'company'
        :                              'issuer'
    ) if $c->{client} =~ /Files\z/;
    my $r;
    my $ok = eval { $r = $client->$m(%a); 1 };
    if ( !$c->{enabled} ) {
        ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'capability',
            "$c->{operation} blocked pre-I/O" );
        next;
    }
    ok( $ok, "$c->{operation} succeeds" ) or BAIL_OUT("$@");
    $count++;
    my $records = $server->records;
    is( scalar @$records, $count, 'exactly one native TLS request' );
    my $wire = $records->[-1];
    is( $wire->{method}, $c->{http_method}, 'HTTP verb' );
    my $expected = $c->{path};
    $expected =~ s/\{([^}]+)\}/$c->{path_params}{$1}/ge;
    is( ( split /\?/, $wire->{path}, 2 )[0], $expected, 'exact path' );
    is(
        Webmania::JSON::encode_json( Webmania::JSON::decode_json( $wire->{body} ) ),
        Webmania::JSON::encode_json( $c->{request} ),
        'exact request body'
    ) if $c->{has_request};

    if ( $c->{operation} eq 'fiscalDownloadReport' ) {
        ok( !exists $wire->{headers}{authorization} && !exists $wire->{headers}{'x-consumer-key'},
            'capability never receives service auth' );
    }
    elsif ( $c->{client} =~ /\A(?:Nfe|NfeFiles|Reseller)\z/ ) {
        is(
            $wire->{headers}{'x-consumer-key'},
            $c->{client} eq 'Reseller' ? 'synthetic-reseller-key' : 'synthetic-company-key',
            'company/reseller auth scope'
        );
        ok( !exists $wire->{headers}{authorization}, 'no bearer mixed with company auth' );
    }
    else {
        my %token = (
            Monitor      => 'synthetic-monitor',
            Emitter      => 'synthetic-issuer',
            EmitterFiles => 'synthetic-issuer-files'
        );
        is( $wire->{headers}{authorization}, 'Bearer ' . $token{ $c->{client} }, 'isolated bearer scope' );
        ok( !exists $wire->{headers}{'x-consumer-key'}, 'no company auth mixed with bearer' );
    }
    if ( $c->{binary} ) {
        isa_ok( $r, 'Webmania::FileResponse' );
        is(
            $r->bytes,
            $c->{media_type} eq 'application/pdf' ? $pdf : $c->{media_type} =~ /xml/ ? $xml : $zip,
            'binary byte identity'
        );
    }
    else {
        my $v = Webmania::JSON::snapshot($r);
        is(
            Webmania::JSON::encode_json($v),
            Webmania::JSON::encode_json( $c->{response} ),
            'complete response semantics preserved'
        );
        ok( ref($r) ne 'HASH' || !keys( %{ $c->{response} } ), 'object response projects to generated model' )
          if ref( $c->{response} ) eq 'HASH';
    }
}
is( $count, 101, '101 enabled operations transferred exactly once' );
$server->stop;
done_testing;
