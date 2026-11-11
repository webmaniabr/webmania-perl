#!/usr/bin/env perl
# Exemplo neutro de homologação (ambiente 2) com o SDK Perl.
# Lê a configuração somente de variáveis WEBMANIA_*, imprime uma linha JSON mascarada por passo
# e nunca repete uma mutação. Sem WEBMANIA_LIVE=1 não faz nenhuma requisição (saída 77). Os escopos
# nfe, nfse e all exigem WEBMANIA_LIVE_LEDGER gravável; sem ele também sai com 77 antes de qualquer requisição.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);

my $JSON   = JSON::PP->new->canonical->utf8;
my $failed = 0;
my ( $ATTEMPTS, $INTERVAL ) = ( 24, 5 );

sub ref12 { my ($v) = @_; defined $v && length $v ? substr( sha256_hex($v), 0, 12 ) : undef }

sub emit {
    my ( $step, $operation, $ok, %extra ) = @_;
    $failed++ unless $ok;
    print $JSON->encode( { step => $step, operation => $operation, ok => $ok ? JSON::PP::true : JSON::PP::false,
        http_status => undef, outcome => undef, kind => undef, ref => undef, %extra } ), "\n";
}

sub ledger {
    my ( $model, $id, $status, $operation ) = @_;
    my $path = $ENV{WEBMANIA_LIVE_LEDGER};
    return unless $path && defined $id && length $id;
    my $line = $JSON->encode( { model => $model, identifier => "$id", status => $status, operation => $operation } ) . "\n";
    # A record that cannot be written fails the run; the cycle goes on so an approved document is still cancelled.
    my $written = open( my $f, '>>', $path );
    $written &&= ( print {$f} $line ) && close($f);
    emit( 'ledger', $operation, 0, kind => 'ledger_unwritable', ref => ref12($id) ) unless $written;
}

sub plain {
    my ($v) = @_;
    $v = $v->as_hash if blessed($v) && $v->can('as_hash');
    $v = $v->[0] if ref $v eq 'ARRAY';
    ref $v eq 'HASH' ? $v : {};
}

sub file_summary {
    my ($r) = @_;
    return { redirect => JSON::PP::true } if blessed($r) && $r->isa('Webmania::FileRedirect');
    my $b = $r->bytes;
    my $format = substr( $b, 0, 5 ) eq '%PDF-' ? 'pdf' : substr( $b, 0, 2 ) eq 'PK' ? 'zip' : $b =~ /\A(?:\xEF\xBB\xBF)?\s*</ ? 'xml' : 'other';
    { size => length $b, sha256 => sha256_hex($b), format => $format };
}

# Runs one step; a sent mutation whose outcome is unknown stops the whole run.
sub call {
    my ( $step, $operation, $fn, %o ) = @_;
    my $r;
    my $ok = eval { $r = $fn->(); 1 };
    unless ($ok) {
        my $e = $@;
        my $sdk = blessed($e) && $e->isa('Webmania::Error');
        my $unknown = $sdk && ( $e->outcome // '' ) eq 'unknown';
        emit( $step, $operation, 0, http_status => $sdk ? $e->status : undef, outcome => $unknown ? 'unknown' : undef,
            kind => $sdk ? $e->kind : 'error', ref => ref12( $o{ref} ) );
        die { unknown => $step } if $o{mutation} && $unknown;
        return undef;
    }
    emit( $step, $operation, 1, http_status => 200, ref => ref12( $o{ref} ), $o{file} ? ( file => file_summary($r) ) : () );
    $r;
}

sub poll {
    my ( $step, $operation, $fetch, $done, $ref ) = @_;
    my $last = {};
    for my $attempt ( 1 .. $ATTEMPTS ) {
        my $r = call( $step, $operation, $fetch, ref => $ref );
        if ( defined $r ) {
            $last = plain($r);
            return $last if $done->( $last->{status} // '' );
        }
        sleep $INTERVAL if $attempt < $ATTEMPTS;
    }
    $last;
}

sub payload {
    my ($name) = @_;
    my $path = $ENV{$name} or return undef;
    open my $f, '<:raw', $path or return undef;
    # Exact JSON numbers are preserved for the SDK, which validates the payload before sending it.
    my $v = eval { Webmania::JSON::decode_json( do { local $/; <$f> } ) };
    return undef unless ref $v eq 'HASH';
    # Top-level `ambiente` must be the JSON integer 2: a decoded number, never the text "2".
    my $ambiente = $v->{ambiente};
    blessed($ambiente) && $ambiente->isa('Webmania::Number') && $ambiente->lexical eq '2' ? $v : undef;
}

sub blocked { print $JSON->encode( { result => 'blocked', reason => $_[0] } ), "\n"; 77 }

sub issue {
    my ( $step, $operation, $fn, $model, $doc ) = @_;
    my $r = eval { call( $step, $operation, $fn, mutation => 1, ref => $doc->{ID} ) };
    if ( my $e = $@ ) { ledger( $model, $doc->{ID} // 'unidentified', 'unknown', $operation ); die $e }
    $r;
}

sub nfe_cycle {
    my ( $nfe, $files, $doc ) = @_;
    my $issued = plain( issue( 'nfe.issue', 'nfeIssueDocument', sub { $nfe->issue_document( body => $doc ) }, 'nfe', $doc ) );
    my $uuid = $issued->{uuid} or return;
    ledger( 'nfe', $uuid, $issued->{status} // 'processando', 'nfeIssueDocument' );
    my $consult = sub { $nfe->get_document( query => { uuid => $uuid } ) };
    my $current = poll( 'nfe.consult', 'nfeGetDocument', $consult, sub { $_[0] =~ /\A(?:aprovado|reprovado|denegado|cancelado)\z/ }, $uuid );
    if ( ( $current->{status} // '' ) ne 'aprovado' ) { ledger( 'nfe', $uuid, $current->{status} // 'unknown', 'nfeGetDocument' ); return }
    my $auth = Webmania::FileAuth->new( mode => 'company' );
    eval {
        call( 'nfe.query', 'nfeQueryDocument', sub { $nfe->query_document( body => { uuid => $uuid } ) }, ref => $uuid );
        call( 'nfe.danfe', 'nfeDownloadDanfe', sub { $files->download_danfe( identifier => $uuid, auth => $auth ) }, ref => $uuid, file => 1 );
        call( 'nfe.danfe_simple', 'nfeDownloadSimpleDanfe', sub { $files->download_simple_danfe( identifier => $uuid, auth => $auth ) }, ref => $uuid, file => 1 );
        call( 'nfe.xml', 'nfeDownloadXml', sub { $files->download_xml( identifier => $uuid, auth => $auth ) }, ref => $uuid, file => 1 );
        1;
    };
    # An approved document is always cancelled, even after a failed step above.
    my $cancelled = eval { call( 'nfe.cancel', 'nfeCancelDocument',
        sub { $nfe->cancel_document( body => { uuid => $uuid, motivo => 'Cancelamento de teste em homologacao.' } ) }, mutation => 1, ref => $uuid ) };
    if ( my $e = $@ ) { ledger( 'nfe', $uuid, 'unknown', 'nfeCancelDocument' ); die $e }
    unless ( defined $cancelled ) { ledger( 'nfe', $uuid, 'aprovado', 'nfeCancelDocument' ); return }
    my $final = poll( 'nfe.consult_cancelled', 'nfeGetDocument', $consult, sub { $_[0] eq 'cancelado' }, $uuid );
    my $status = $final->{status} // 'unknown';
    ledger( 'nfe', $uuid, $status, 'nfeCancelDocument' );
    # Only a consult that shows the cancellation counts as success.
    return emit( 'nfe.consult_cancelled', 'nfeGetDocument', 0, kind => 'not_cancelled', ref => ref12($uuid) ) unless $status eq 'cancelado';
    call( 'nfe.cancellation_xml', 'nfeDownloadCancellationXml', sub { $files->download_cancellation_xml( identifier => $uuid, auth => $auth ) },
        ref => $uuid, file => 1 );
}

sub nfse_cycle {
    my ( $emitter, $files, $doc ) = @_;
    my $issued = plain( issue( 'nfse.issue', 'emitterIssueNfse', sub { $emitter->issue_nfse( body => $doc ) }, 'nfse', $doc ) );
    my $uuid = $issued->{uuid} // ( ref $issued->{info_nfse} eq 'ARRAY' ? plain( $issued->{info_nfse} )->{uuid} : undef ) or return;
    ledger( 'nfse', $uuid, $issued->{status} // 'processando', 'emitterIssueNfse' );
    my $consult = sub { $emitter->get_nfse( identifier => $uuid ) };
    my $current = poll( 'nfse.consult', 'emitterGetNfse', $consult, sub { $_[0] ne '' && $_[0] !~ /\A(?:processando|pendente)\z/ }, $uuid );
    if ( ( $current->{status} // '' ) ne 'aprovado' ) { ledger( 'nfse', $uuid, $current->{status} // 'unknown', 'emitterGetNfse' ); return }
    my $auth = Webmania::FileAuth->new( mode => 'issuer' );
    eval {
        call( 'nfse.xml', 'fileGetNfseXml', sub { $files->get_nfse_xml( identifier => $uuid, auth => $auth ) }, ref => $uuid, file => 1 );
        for my $f ( [ 'nfse.pdf', 'fileGetNfsePdf', 'pdf_nfse', 'get_nfse_pdf' ], [ 'nfse.rps_pdf', 'fileGetNfseRpsPdf', 'pdf_rps', 'get_nfse_rps_pdf' ] ) {
            my ( $step, $operation, $field, $method ) = @$f;
            if   ( $current->{$field} ) { call( $step, $operation, sub { $files->$method( identifier => $uuid, auth => $auth ) }, ref => $uuid, file => 1 ) }
            else                        { emit( $step, $operation, 1, kind => 'not_offered', ref => ref12($uuid) ) }
        }
        1;
    };
    my $cancelled = eval { call( 'nfse.cancel', 'emitterCancelNfse',
        sub { $emitter->cancel_nfse( body => { uuid => $uuid, motivo => '1', justificativa => 'Cancelamento de teste em homologacao.' } ) },
        mutation => 1, ref => $uuid ) };
    if ( my $e = $@ ) { ledger( 'nfse', $uuid, 'unknown', 'emitterCancelNfse' ); die $e }
    unless ( defined $cancelled ) { ledger( 'nfse', $uuid, 'aprovado', 'emitterCancelNfse' ); return }
    my $final = poll( 'nfse.consult_cancelled', 'emitterGetNfse', $consult, sub { $_[0] eq 'cancelado' }, $uuid );
    my $status = $final->{status} // 'unknown';
    ledger( 'nfse', $uuid, $status, 'emitterCancelNfse' );
    emit( 'nfse.consult_cancelled', 'emitterGetNfse', 0, kind => 'not_cancelled', ref => ref12($uuid) ) unless $status eq 'cancelado';
}

sub origin { my ($u) = @_; $u =~ m{\A(https?://[^/?#]+)} ? $1 : $u }

sub main {
    unless ( ( $ENV{WEBMANIA_LIVE} // '' ) eq '1' ) { print qq({"result":"blocked"}\n); return 77 }
    require Webmania;
    my $api1  = $ENV{WEBMANIA_API1_BASE_URL}  || 'https://webmania.com.br/api';
    my $filesb = $ENV{WEBMANIA_FILES_BASE_URL} || 'https://nfe.webmania.com.br';
    my $api2  = $ENV{WEBMANIA_API2_BASE_URL}  || 'https://api.webmania.com.br';
    my $scope = $ENV{WEBMANIA_LIVE_SCOPE}     || 'readonly';
    return blocked('scope') unless $scope =~ /\A(?:readonly|nfe|nfse|all)\z/;
    # The allow list is required: without it no origin is trusted (fail closed, before any credential).
    my %allowed = map { lc($_) => 1 } grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $ENV{WEBMANIA_LIVE_ALLOWED_HOSTS} // '';
    return blocked('allowed_hosts') unless %allowed;
    for my $u ( $api1, $filesb, $api2 ) {
        my ($host) = $u =~ m{\Ahttps?://(?:[^@/]*@)?(\[[^\]]+\]|[^:/?#]+)};
        return blocked('origin_not_allowed') unless defined $host && $allowed{ lc $host };
    }
    for (qw(WEBMANIA_CONSUMER_KEY WEBMANIA_CONSUMER_SECRET WEBMANIA_ACCESS_TOKEN WEBMANIA_ACCESS_TOKEN_SECRET WEBMANIA_ISSUER_TOKEN)) {
        return blocked('credentials') unless length( $ENV{$_} // '' );
    }
    my $nfe_doc  = $scope =~ /\A(?:nfe|all)\z/  ? payload('WEBMANIA_LIVE_NFE_PAYLOAD')  : undef;
    my $nfse_doc = $scope =~ /\A(?:nfse|all)\z/ ? payload('WEBMANIA_LIVE_NFSE_PAYLOAD') : undef;
    return blocked('payload') if ( $scope =~ /\A(?:nfe|all)\z/ && !$nfe_doc ) || ( $scope =~ /\A(?:nfse|all)\z/ && !$nfse_doc );
    if ( $nfe_doc || $nfse_doc ) {
        # An unknown outcome is recorded only in the ledger: it must be writable before any mutation.
        my $ledger = $ENV{WEBMANIA_LIVE_LEDGER} // '';
        return blocked('ledger') unless length $ledger;
        my $mask   = umask 077;
        my $opened = open( my $f, '>>', $ledger );
        umask $mask;
        return blocked('ledger') unless $opened && close($f);
    }
    my %ca = $ENV{WEBMANIA_CA_FILE} ? ( ca_file => $ENV{WEBMANIA_CA_FILE} ) : ();
    my $rc = eval {
        my $company = Webmania::CompanyCredentials->new(
            consumer_key => $ENV{WEBMANIA_CONSUMER_KEY}, consumer_secret => $ENV{WEBMANIA_CONSUMER_SECRET},
            access_token => $ENV{WEBMANIA_ACCESS_TOKEN}, access_token_secret => $ENV{WEBMANIA_ACCESS_TOKEN_SECRET}
        );
        my $nfe     = Webmania::NfeClient->new( credentials => $company, base_url => $api1, %ca );
        my $emitter = Webmania::EmitterClient->new( issuer_token => $ENV{WEBMANIA_ISSUER_TOKEN}, base_url => $api2, %ca );
        my $nfe_files = Webmania::NfeFilesClient->new( credentials => $company, base_url => $filesb, trusted_origins => [ origin($filesb) ], %ca );
        my $emitter_files = Webmania::EmitterFilesClient->new( issuer_token => $ENV{WEBMANIA_ISSUER_TOKEN}, base_url => $api2, trusted_origins => [ origin($api2) ], %ca );
        call( 'readonly.sefaz', 'nfeGetSefazStatus', sub { $nfe->get_sefaz_status } );
        call( 'readonly.certificate', 'nfeGetCertificateValidity', sub { $nfe->get_certificate_validity } );
        call( 'readonly.tax_classes', 'nfeListTaxClasses', sub { $nfe->list_tax_classes } );
        call( 'readonly.nfse_provider', 'emitterGetNfseProviderStatus', sub { $emitter->get_nfse_provider_status } );
        nfe_cycle( $nfe, $nfe_files, $nfe_doc ) if $nfe_doc;
        nfse_cycle( $emitter, $emitter_files, $nfse_doc ) if $nfse_doc;
        1;
    };
    unless ($rc) {
        my $e = $@;
        return 1 if ref $e eq 'HASH' && $e->{unknown};
        emit( 'configuration', undef, 0, kind => blessed($e) && $e->isa('Webmania::Error') ? $e->kind : 'error' );
        return 1;
    }
    $failed ? 1 : 0;
}

exit main();
