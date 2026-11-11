use strict;
use warnings;
use Test::More;
use Webmania;
my $sem = Webmania::Schema::readfile('t/fixtures/semantic_cases.json');
for my $c ( @{ $sem->{cases} } ) {
    is(
        Webmania::Schema::valid( $c->{module}, { '$ref' => '#/components/schemas/' . $c->{schema} },
            $c->{instance} ) ? 1 : 0,
        $c->{valid} ? 1 : 0,
        'schema: ' . ( $c->{name} // $c->{id} )
    );
}
my %mapping = (
    nfe    => [ 'api1_fiscal',         'Nfe55IssueRequest' ],
    nfce   => [ 'api1_fiscal',         'Nfce65IssueRequest' ],
    nfse   => [ 'api2_nfse_issuance',  'EmitterIssueNfsePayload' ],
    cte    => [ 'api2_cte_issuance',   'EmitterIssueCtePayload' ],
    cte_os => [ 'api2_cte_issuance',   'EmitterIssueCtePayload' ],
    mdfe   => [ 'api2_mdfe_issuance',  'EmitterIssueMdfePayload' ],
    nfcom  => [ 'api2_nfcom_issuance', 'EmitterIssueNfcomPayload' ],
    dce    => [ 'api2_dce_issuance',   'EmitterIssueDcePayload' ]
);
for my $model ( sort keys %mapping ) {
    my ( $mod, $schema ) = @{ $mapping{$model} };
    my $v = Webmania::Schema::readfile("t/fixtures/examples/$model.json");
    ok( Webmania::Schema::valid( $mod, { '$ref' => '#/components/schemas/' . $schema }, $v ),
        "$model example matches full pinned schema" );
}
my $import = Webmania::Models::Api2MonitorDocuments::MonitorImportStatus->new(
    uuid        => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    status      => 'invalido',
    processado  => 0,
    importados  => [ { arquivo => 'one.xml', uuid => 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } ],
    descartados => [],
    erro        => 'invalid archive',
    extra       => { n => Webmania::number('9007199254740993') }
);
isa_ok( $import->importados->[0],
    'Webmania::Models::Api2MonitorDocuments::MonitorImportStatusImportadosItem' );
ok( $import->has('erro'), 'terminal invalid result retains declared erro' );
is( $import->as_hash->{extra}{n}->lexical, '9007199254740993', 'additional exact fields preserved' );
done_testing;
