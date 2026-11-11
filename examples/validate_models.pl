use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Webmania;
use File::Basename qw(dirname);
use File::Spec;
my %models = (
    nfe => ['api1_fiscal', 'Nfe55IssueRequest'],
    nfce => ['api1_fiscal', 'Nfce65IssueRequest'],
    nfse => ['api2_nfse_issuance', 'EmitterIssueNfsePayload'],
    cte => ['api2_cte_issuance', 'EmitterIssueCtePayload'],
    cte_os => ['api2_cte_issuance', 'EmitterIssueCtePayload'],
    mdfe => ['api2_mdfe_issuance', 'EmitterIssueMdfePayload'],
    nfcom => ['api2_nfcom_issuance', 'EmitterIssueNfcomPayload'],
    dce => ['api2_dce_issuance', 'EmitterIssueDcePayload'],
);
for my $model (sort keys %models) {
    my ($module, $schema) = @{$models{$model}};
    my $value = Webmania::Schema::readfile(File::Spec->catfile(dirname(__FILE__), "$model.json"));
    Webmania::Schema::validate($module, {'$ref' => '#/components/schemas/'.$schema}, $value);
    print "$model: synthetic request validates against pinned contract\n";
}
