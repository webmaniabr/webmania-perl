use strict;
use warnings;
use Test::More;
use Webmania;
my $cases = Webmania::Schema::readfile('t/fixtures/semantic_cases.json')->{cases};
my $count = 0;
for my $c (@$cases) {
    next unless $c->{valid};
    my $s         = { '$ref' => '#/components/schemas/' . $c->{schema} };
    my $v         = $c->{instance};
    my $projected = Webmania::Schema::project( $c->{module}, $s, $v );
    is(
        Webmania::JSON::encode_json($projected),
        Webmania::JSON::encode_json($v),
        'projection semantics: ' . ( $c->{name} // $c->{id} )
    );
    $count++;
}
cmp_ok( $count, '>', 70, 'projection corpus covers valid full schema cases' );
my $v = Webmania::JSON::decode_json(
'{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"invalido","processado":1.0,"importados":[],"descartados":[]}'
);
Webmania::Schema::validate( 'api2_monitor_documents',
    { '$ref' => '#/components/schemas/MonitorImportStatus' }, $v );
my $p = Webmania::Schema::project( 'api2_monitor_documents',
    { '$ref' => '#/components/schemas/MonitorImportStatus' }, $v );
isa_ok( $p, 'Webmania::Models::Api2MonitorDocuments::MonitorImportStatus' );
is( $p->processado->lexical, '1.0',
    'semantic integer retains original lexical decimal through typed access' );
done_testing;
