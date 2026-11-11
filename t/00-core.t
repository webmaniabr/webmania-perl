use strict;
use warnings;
use Test::More;
use Webmania;

sub fails {
    my ( $code, $kind, $name ) = @_;
    my $ok = eval { $code->(); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq $kind, $name ) or diag("$@");
}
is( $Webmania::VERSION,                   '0.1.0_03', 'alpha version' );
is( scalar( keys %Webmania::Schema::OP ), 103,        'all pinned operations' );
my $n = Webmania::number('9007199254740993.1234567890123456789');
is(
    Webmania::JSON::encode_json( { n => $n } ),
    ' {"n":9007199254740993.1234567890123456789}' =~ s/^ //r,
    'exact number emits lexically'
);
my $v = Webmania::JSON::decode_json('{"n":9007199254740993.1234567890123456789}');
is( $v->{n}->lexical, $n->lexical, 'exact number parses lexically' );
fails( sub { Webmania::JSON::decode_json('{"x":1,"x":2}') }, 'protocol',   'duplicate keys rejected' );
fails( sub { Webmania::JSON::decode_json('[NaN]') },         'protocol',   'nonfinite rejected' );
fails( sub { Webmania::JSON::encode_json(0.1) },             'validation', 'native float rejected' );
my $cycle = {};
$cycle->{self} = $cycle;
fails( sub { Webmania::JSON::encode_json($cycle) }, 'validation', 'cycle bounded' );
fails( sub { Webmania::JSON::decode_json( ( '[' x 66 ) . '0' . ( ']' x 66 ) ) },
    'protocol', 'deep JSON bounded' );
my $c = Webmania::CompanyCredentials->new(
    consumer_key        => 'ck',
    consumer_secret     => 'cs',
    access_token        => 'at',
    access_token_secret => 'as'
);
fails( sub { Webmania::ResellerClient->new( credentials => $c ) },
    'configuration', 'credential scopes enforced' );
my $client = Webmania::NfeClient->new( credentials => $c );
like( "$client", qr/private/, 'client default display private' );
fails(
    sub {
        Webmania::NfeFilesClient->new( trusted_origins => ['https://nfe.webmania.com.br'] )
          ->download_ibs_cbs_event_xml( uuid => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' );
    },
    'capability',
    'blocked before arguments/network'
);
my $m = Webmania::Models::Api2MonitorDocuments::MonitorImportStatus->new(
    uuid        => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    status      => 'invalido',
    erro        => 'bad',
    processado  => 0,
    importados  => [],
    descartados => []
);
ok( $m->has('erro'), 'typed field presence' );
is( $m->status, 'invalido', 'typed accessor' );
fails( sub { $m->processado( Webmania::number('-1') ) }, 'validation', 'typed setter validates' );
fails(
    sub {
        Webmania::Models::Api2MonitorDocuments::MonitorImportStatus->new( status => Webmania::number('1') );
    },
    'validation',
    'typed constructor rejects mismatch'
);
my $r = Webmania::Redactor->new( [ 'abcdefgh', 'defghijk' ] );
is( $r->text('abcdefghijk'), '[redacted]', 'overlapping literals fully merged' );
my $short = Webmania::Redactor->new( ['abc'] );
is( $short->text('alphabetabc abc'), 'alphabetabc [redacted]', 'short literals use word boundaries' );
done_testing;
