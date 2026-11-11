package Webmania::CompanyCredentials;
use strict;
use warnings;
use overload '""' => sub { '[private company credentials]' }, fallback => 1;

sub new {
    my ( $c, %a ) = @_;
    my @keys = qw(consumer_key consumer_secret access_token access_token_secret);
    Webmania::Error::throw( 'configuration', 'Expected all four scoped credential fields.' )
      if keys(%a) != 4 || grep { !exists $a{$_} } @keys;
    Webmania::Auth::credential($_) for values %a;
    bless \%a, $c;
}
sub TO_JSON { '[private credentials]' }

package Webmania::ResellerCredentials;
our @ISA = ('Webmania::CompanyCredentials');

package Webmania::FileAuth;
use overload '""' => sub { '[private file access mode]' }, fallback => 1;

sub new {
    my ( $c, %a ) = @_;
    Webmania::Error::throw( 'configuration', 'Choose one explicit file access mode.' )
      unless defined $a{mode}
      && $a{mode} =~ /\A(?:company|issuer|document_token|capability|anonymous)\z/
      && keys(%a) == ( exists $a{token} ? 2 : 1 );
    if    ( $a{mode} eq 'document_token' ) { Webmania::Auth::credential( $a{token} ) }
    elsif ( exists $a{token} ) {
        Webmania::Error::throw( 'configuration', 'This file mode does not accept a token.' );
    }
    bless \%a, $c;
}
sub mode    { $_[0]{mode} }
sub TO_JSON { '[private file access mode]' }

package Webmania::Auth;

sub credential {
    Webmania::Error::throw( 'configuration',
        'Expected a nonempty bounded credential without whitespace or control characters.' )
      unless defined $_[0] && !ref $_[0] && length( $_[0] ) <= 8192 && $_[0] =~ /\A[\x21-\x7e]+\z/;
}

sub company {
    my ( $cred, $type ) = @_;
    Webmania::Error::throw( 'configuration', 'Credential scope does not match this service.' )
      unless ref($cred) eq $type;
    my %map = (
        consumer_key        => 'X-Consumer-Key',
        consumer_secret     => 'X-Consumer-Secret',
        access_token        => 'X-Access-Token',
        access_token_secret => 'X-Access-Token-Secret'
    );
    +{ map { $map{$_} => $cred->{$_} } keys %map };
}
sub bearer { credential( $_[0] ); +{ Authorization => 'Bearer ' . $_[0] } }

package Webmania::BaseClient;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Encode       qw(encode);
use JSON::PP     ();
use overload '""' => sub { ref( $_[0] ) . ' [private service configuration]' }, fallback => 1;

sub _new {
    my ( $class, $scope, $headers, $base, %a ) = @_;
    my %known = map { $_ => 1 } qw(base_url ca_file options trusted_origins);
    Webmania::Error::throw( 'configuration', 'Unknown client configuration.' )
      if grep { !$known{$_} } keys %a;
    my $transport = Webmania::Transport->new( base_url => $a{base_url} // $base, ca_file => $a{ca_file} );
    my $o         = Webmania::Transport::options( $a{options} );
    my @secrets   = map { ( $_, s/^Bearer //r ) } values %$headers;
    bless {
        scope     => $scope,
        headers   => $headers,
        transport => $transport,
        options   => $o,
        secrets   => \@secrets
    }, $class;
}
sub close   { $_[0]{transport}->close }
sub TO_JSON { '[private service configuration]' }

sub _escape {
    my ($s) = @_;
    $s = encode( 'UTF-8', "$s" );
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X',ord$1)/ge;
    $s;
}

sub _id {
    open my $f, '<:raw', '/dev/urandom'
      or Webmania::Error::throw( 'configuration', 'Secure request identity is unavailable.' );
    read( $f, my $b, 16 ) == 16
      or Webmania::Error::throw( 'configuration', 'Secure request identity is unavailable.' );
    my @v = unpack 'C16', $b;
    $v[6] = ( $v[6] & 15 ) | 64;
    $v[8] = ( $v[8] & 63 ) | 128;
    my $h = unpack 'H*', pack 'C16', @v;
    join '-', substr( $h, 0, 8 ), substr( $h, 8, 4 ), substr( $h, 12, 4 ), substr( $h, 16, 4 ),
      substr( $h, 20 );
}

sub _file_auth {
    my ( $self, $spec, $auth, $query ) = @_;
    Webmania::Error::throw( 'configuration', 'Choose one explicit FileAuth mode.' )
      unless ref($auth) eq 'Webmania::FileAuth';
    my $policies = $spec->{security} // [];
    my $mode     = $auth->{mode};
    my $has      = sub {
        my $key = shift;
        scalar grep { exists $_->{$key} } @$policies;
    };
    my $headers = $self->{headers};
    if ( $mode eq 'company' && $self->{scope} =~ /\A(?:NfeFiles|ReportFiles)\z/ && $has->('ConsumerKey') && keys %$headers ) {
        return ( {%$headers}, [] );
    }
    if (   $mode eq 'issuer'
        && $self->{scope} eq 'EmitterFiles'
        && $has->('FiscalFileCompanyBearer')
        && keys %$headers )
    {
        return ( {%$headers}, [] );
    }
    if ( $mode eq 'document_token' && ( $has->('DocumentToken') || $has->('FiscalDocumentLinkToken') ) ) {
        $query->{token} = $auth->{token};
        return ( {}, [ $auth->{token} ] );
    }
    if ( $mode eq 'anonymous' && grep { !keys %$_ } @$policies ) {
        return ( {}, [] );
    }
    if ( $mode eq 'capability' && !@$policies ) { return ( {}, [] ) }
    Webmania::Error::throw( 'capability', 'Explicit file mode is not supported for this operation.' );
}

sub _execute {
    my ( $self, $oid, $args ) = @_;
    my $r = $Webmania::Schema::OP{$oid};
    Webmania::Error::throw( 'configuration', 'Operation belongs to a different service scope.' )
      unless $r && $r->{scope} eq $self->{scope};
    my $spec = $r->{spec};
    Webmania::Error::throw( 'capability', 'This operation is not available in this SDK release; no request was sent.' )
      if exists $spec->{'x-sdk-generation-enabled'} && !$spec->{'x-sdk-generation-enabled'};
    my %allowed = map { $_ => 1 } (
        'body', 'query', 'options', 'auth', '_workflow',
        map { $_->{name} } grep { $_->{in} eq 'path' } @{ $r->{parameters} }
    );
    Webmania::Error::throw( 'validation', 'Unknown named operation argument.' )
      if grep { !$allowed{$_} } keys %$args;
    my $options =
      exists $args->{options} ? Webmania::Transport::options( $args->{options} ) : { %{ $self->{options} } };
    my $query = Webmania::JSON::snapshot( $args->{query} // {} );
    Webmania::Schema::validate( $r->{module}, $r->{query_schema},                                    $query );
    Webmania::Schema::validate( $r->{module}, { '$ref' => '#/components/schemas/NfeLookupRequest' }, $query )
      if $oid eq 'nfeGetDocument';
    Webmania::Error::throw( 'validation', 'Download statistics require paired year and month.' )
      if $oid eq 'monitorGetDownloadStatistics' && exists( $query->{ano} ) != exists( $query->{mes} );
    my $route = $r->{path};
    my %paths;

    for my $p ( grep { $_->{in} eq 'path' } @{ $r->{parameters} } ) {
        my $key = $p->{name};
        Webmania::Error::throw( 'validation', 'Missing path parameter.' ) unless exists $args->{$key};
        my $v = Webmania::JSON::snapshot( $args->{$key} );
        Webmania::Schema::validate( $r->{module}, $p->{schema}, $v );
        Webmania::Error::throw( 'validation', 'Unsafe path identifier.' )
          if Webmania::JSON::kind($v) eq 'string'
          && ( $v eq '.' || $v eq '..' || $v =~ /[\x00-\x20\x7f\/\\%?#]/ );
        my $encoded = _escape($v);
        $route =~ s/\{\Q$key\E\}/$encoded/g;
        $paths{$key} = $v;
    }
    my $schema = $spec->{requestBody}{content}{'application/json'}{schema};
    my ( $body, $snapshot );
    if ($schema) {
        Webmania::Error::throw( 'validation', 'Missing JSON body.' ) unless exists $args->{body};
        $body     = Webmania::JSON::encode_json( $args->{body} );
        $snapshot = Webmania::JSON::decode_json($body);
        Webmania::Schema::validate( $r->{module}, $schema, $snapshot );
    }
    elsif ( exists $args->{body} ) {
        Webmania::Error::throw( 'validation', 'Operation does not accept a JSON body.' );
    }
    my ( $headers, $additional ) = ( { %{ $self->{headers} } }, [] );
    if ( $self->{scope} =~ /Files\z/ ) {
        ( $headers, $additional ) = $self->_file_auth( $spec, $args->{auth}, $query );
    }
    elsif ( exists $args->{auth} ) {
        Webmania::Error::throw( 'configuration', 'File authorization does not apply to this service.' );
    }
    my $binary = grep {
        my $code = $_;
        $code =~ /^2/ && grep { ( $_->{schema}{format} // '' ) eq 'binary' }
          values %{ $spec->{responses}{$code}{content} // {} }
    } keys %{ $spec->{responses} };
    $headers->{'User-Agent'}      = 'Webmania-Perl/' . $Webmania::VERSION;
    $headers->{'Accept-Encoding'} = 'identity';
    $headers->{Accept}            = 'application/json';
    if ($binary) {
        my %media;
        for my $code ( grep { /^2/ } keys %{ $spec->{responses} } ) {
            $media{$_} = 1 for grep { $_ ne 'text/html' } keys %{ $spec->{responses}{$code}{content} // {} };
        }
        $headers->{Accept} = join ', ', sort keys %media;
    }
    $headers->{'Content-Type'} = 'application/json' if defined $body;
    my $path = $self->{transport}{base}{path} . $route;
    $path .= '?' . join(
        '&',
        map {
            _escape($_) . '='
              . _escape(
                JSON::PP::is_bool( $query->{$_} ) ? ( $query->{$_} ? 'true' : 'false' ) : $query->{$_} )
        } sort keys %$query
    ) if keys %$query;
    my $workflow = $args->{_workflow};
    my @secrets  = ( @{ $self->{secrets} }, @$additional, $workflow ? @{ $workflow->{literal} } : () );
    my $redactor =
      Webmania::Redactor->new( [ @secrets, values %paths ], { body => $snapshot, query => $query } );
    my $guard = Webmania::Redactor->new( \@secrets );
    for my $v ( values %paths ) { $redactor->uuid($v) unless ref $v }
    if ($workflow) { $redactor->uuid($_), $guard->uuid($_) for @{ $workflow->{uuids} } }
    if ( $workflow && $workflow->{limited} ) { $redactor->{limited} = 1; $guard->{limited} = 1; }
    my $c = {
        redactor         => $redactor,
        guard            => $guard,
        options          => $options,
        sent             => 0,
        headers_complete => 0,
        headers          => {}
    };
    my $effect   = $spec->{'x-operation-effects'}{business_mutation};
    my $mutation = defined $effect ? ( $effect ? 1 : 0 ) : $r->{verb} !~ /\A(?:GET|HEAD)\z/;

    # Pinned api1/files GET /relatorio/{uuid}/ x-retry-policy.reason:
    # this public one-export capability consumes quota even though it is GET.
    $mutation = 1 if $oid eq 'fiscalDownloadReport';
    if ( $oid eq 'monitorGetDocument' ) {
        $mutation = exists $query->{atualizar_status}
          && (
              JSON::PP::is_bool( $query->{atualizar_status} ) ? $query->{atualizar_status}
            : Webmania::JSON::is_number( $query->{atualizar_status} )
            ? Webmania::JSON::decimal( $query->{atualizar_status} )
              ->bcmp( Math::BigFloat->new( '1', undef, undef ) ) == 0
            : $query->{atualizar_status} eq '1'
          );
    }
    if ( $oid eq 'monitorSearchDocuments' ) {
        $mutation = exists $snapshot->{relatorio} if ref $snapshot eq 'HASH';
    }
    my $reference;
    for my $key (qw(uuid ID id chave fd company)) {
        my $v = $paths{$key} // ( ref($snapshot) eq 'HASH' ? $snapshot->{$key} : undef );
        if ( defined $v && Webmania::JSON::kind($v) eq 'string' && length $v ) {
            $reference = [ $key, $v ];
            last;
        }
    }
    my $capability = $args->{auth} && $args->{auth}{mode} =~ /\A(?:capability|document_token|anonymous)\z/;
    my $request_id = _id();
    my ( $result, $pending );
    eval { $result = $self->{transport}->exchange( $r->{verb}, $path, $body, $headers, $c ); 1 }
      or $pending = blessed($@)
      && $@->isa('Webmania::Error') ? $@ : Webmania::Error->new( 'network', 'HTTP exchange failed.' );
    my $failure = sub {
        my ( $kind, $message, $details, $location ) = @_;
        my $unknown =
             $mutation
          && $c->{sent}
          && ( $pending
            || ( $c->{status} // 0 ) >= 500
            || $kind =~ /\A(?:protocol|response_schema|business|redirect|protected_file|cancelled|timeout)\z/ );
        my $incomplete = $c->{trailers_incomplete}
          || !$c->{headers_complete}
          && ( $c->{headers_started} || $kind =~ /\A(?:protocol|headers_limit)\z/ );
        my $recovery =
          $unknown && $reference && !$capability && !$incomplete && !$guard->protected( $reference->[1] )
          ? Webmania::Protected->new( { $reference->[0] => $reference->[1] } )
          : undef;
        my $corr;
        unless ($incomplete) {
            for my $key (qw(x-correlation-id x-request-id request-id)) {
                if ( $c->{headers}{$key} ) { $corr = $redactor->text( $c->{headers}{$key}[0] ); last }
            }
        }
        Webmania::Error->new(
            $kind, $message,
            status         => $c->{status},
            outcome        => $unknown ? 'unknown' : undef,
            recovery       => $recovery,
            location       => $location,
            correlation_id => $corr,
            details        => $redactor->clean($details),
            operation      => $oid,
            request_id     => $request_id
        );
    };
    die $failure->( $pending->kind, $pending->message ) if $pending;
    my ( $status, $h, $bytes ) = @$result;
    if ( $status >= 300 && $status < 400 ) {
        my $location;
        eval { $location = Webmania::Redactor::location( $h->{location}[0] ) if $h->{location}; 1 }
          or die $failure->( 'protocol', 'Invalid redirect Location.' );
        if ( $binary && $status == 302 && $spec->{responses}{302}{headers}{Location}{required} ) {
            die $failure->( 'protocol', 'Documented redirect requires a Location.' ) unless $location;
            return Webmania::FileRedirect->new($location);
        }
        die $failure->( 'redirect', 'Unexpected redirect refused.', undef, $location );
    }
    my $media = lc( ( $h->{'content-type'}[0] // '' ) =~ s/;.*//r );
    $media =~ s/^\s+|\s+$//g;
    my ( $value, $parse_failed );
    if ( $media eq 'application/json' || $media =~ /\+json\z/ ) {
        $bytes =~ s/^\xef\xbb\xbf//;
        eval { $value = Webmania::JSON::decode_json($bytes); 1 } or $parse_failed = 1;
    }
    die $failure->( 'http', 'HTTP request failed.', $value ) unless $status >= 200 && $status < 300;
    my $declared = $spec->{responses}{$status};
    my $typed_import =
         ref($value) eq 'HASH'
      && $declared
      && Webmania::Schema::valid( $r->{module}, { '$ref' => '#/components/schemas/MonitorImportStatus' },
        $value )
      && $r->{module} eq 'api2_monitor_documents'
      && $oid =~ /Import/;
    if (
        ref($value) eq 'HASH' && (
               exists $value->{error}
            || exists $value->{success} && JSON::PP::is_bool( $value->{success} ) && !$value->{success}
            || grep {
                my $key = $_;
                !( $key eq 'erro' && $typed_import )
                && exists $value->{$key}
                  && defined $value->{$key}
                  && !( JSON::PP::is_bool( $value->{$key} )                && !$value->{$key} )
                  && !( ref( $value->{$key} ) eq 'ARRAY'                   && !@{ $value->{$key} } )
                  && !( ref( $value->{$key} ) eq 'HASH'                    && !keys %{ $value->{$key} } )
                  && !( Webmania::JSON::kind( $value->{$key} ) eq 'string' && $value->{$key} eq '' )
            } qw(erro errors)
        )
      )
    {
        die $failure->( 'business', 'Provider returned a functional error.', $value );
    }
    die $failure->( 'protocol', 'Unexpected successful HTTP status.' ) unless $declared;
    if ($binary) {
        die $failure->( 'business', 'Provider returned JSON instead of a fiscal file.', $value )
          if defined $value;
        my @allowed = grep { ( $declared->{content}{$_}{schema}{format} // '' ) eq 'binary' }
          keys %{ $declared->{content} // {} };
        my $file;
        eval {
            $file =
              $oid =~ /\AfiscalDownloadReport(?:V2)?\z/
              ? Webmania::Files::report( $status, $media, $bytes, \@allowed, $c, $oid eq 'fiscalDownloadReport' )
              : Webmania::Files::result( $status, $media, $bytes, \@allowed, $c );
            1;
        }
          or do {
            my $e = $@;
            die $failure->( $e->kind, $e->message )
              if blessed($e) && $e->isa('Webmania::Error') && $e->kind =~ /\A(?:cancelled|timeout)\z/;
            die $failure->( 'protocol', 'Invalid or incomplete fiscal file.' );
          };
        return $file;
    }
    die $failure->( 'protocol', 'Expected finite JSON with unique keys.' )
      if $parse_failed || !defined $value;
    my $response_schema = $declared->{content}{'application/json'}{schema};
    die $failure->( 'protocol', 'Unexpected successful representation.' ) unless $response_schema;
    die $failure->( 'response_schema', 'Response does not match the pinned contract.', $value )
      unless Webmania::Schema::valid( $r->{module}, $response_schema, $value );
    if ( $workflow && ref $value eq 'HASH' ) {
        my $protector = Webmania::Redactor->new( $workflow->{literal} );
        $protector->uuid($_) for @{ $workflow->{uuids} };
        for my $key (qw(uuid url token)) {
            $protector->add( $value->{$key} ) if defined $value->{$key} && !ref $value->{$key};
        }
        if ( defined $value->{uuid} && !ref $value->{uuid} ) { $protector->uuid( $value->{uuid} ); }
        if ( defined $value->{url}  && !ref $value->{url} ) {
            $protector->observe_location( $value->{url} );
        }
        $workflow->{literal} = [ keys %{ $protector->{literal} } ];
        $workflow->{uuids}   = [ keys %{ $protector->{uuids} } ];
        $workflow->{limited} ||= $protector->{limited};
    }
    return Webmania::Schema::project( $r->{module}, $response_schema, $value );
}

package Webmania::NfeClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $cred = delete $a{credentials};
    $c->_new( 'Nfe', Webmania::Auth::company( $cred, 'Webmania::CompanyCredentials' ),
        'https://webmania.com.br/api', %a );
}

sub issue_nfe {
    my ( $s, %a ) = @_;
    Webmania::Schema::validate(
        'api1_fiscal',
        { '$ref' => '#/components/schemas/Nfe55IssueRequest' },
        Webmania::JSON::snapshot( $a{body} )
    );
    $s->issue_document(%a);
}

sub issue_nfce {
    my ( $s, %a ) = @_;
    Webmania::Schema::validate(
        'api1_fiscal',
        { '$ref' => '#/components/schemas/Nfce65IssueRequest' },
        Webmania::JSON::snapshot( $a{body} )
    );
    $s->issue_document(%a);
}

package Webmania::ResellerClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $cred = delete $a{credentials};
    $c->_new( 'Reseller', Webmania::Auth::company( $cred, 'Webmania::ResellerCredentials' ),
        'https://webmania.com.br', %a );
}

package Webmania::EmitterClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $token = delete $a{issuer_token};
    $c->_new( 'Emitter', Webmania::Auth::bearer($token), 'https://api.webmania.com.br', %a );
}

package Webmania::MonitorClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $token = delete $a{monitor_token};
    $c->_new( 'Monitor', Webmania::Auth::bearer($token), 'https://api.webmania.com.br', %a );
}

package Webmania::NfeFilesClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $cred    = delete $a{credentials};
    my $headers = defined $cred ? Webmania::Auth::company( $cred, 'Webmania::CompanyCredentials' ) : {};
    Webmania::FilesClient::new_client( $c, 'NfeFiles', $headers, 'https://nfe.webmania.com.br', \%a );
}

package Webmania::EmitterFilesClient;
our @ISA = ('Webmania::BaseClient');

sub new {
    my ( $c, %a ) = @_;
    my $token   = delete $a{issuer_token};
    my $headers = defined $token ? Webmania::Auth::bearer($token) : {};
    Webmania::FilesClient::new_client( $c, 'EmitterFiles', $headers, 'https://api.webmania.com.br', \%a );
}

package Webmania::ReportFilesClient;
our @ISA = ('Webmania::BaseClient');

# Current report exports (fiscalDownloadReportV2) on one explicitly trusted API2 origin. The report
# UUID from the url returned by create_or_poll_report is a sensitive capability: use
# FileAuth 'anonymous' for it, or 'company' with optional company credentials.
sub new {
    my ( $c, %a ) = @_;
    my $cred    = delete $a{credentials};
    my $headers = defined $cred ? Webmania::Auth::company( $cred, 'Webmania::CompanyCredentials' ) : {};
    Webmania::FilesClient::new_client( $c, 'ReportFiles', $headers, 'https://api.webmania.com.br', \%a );
}

package Webmania::FilesClient;

sub new_client {
    my ( $c, $scope, $headers, $base, $a ) = @_;
    my $b       = Webmania::Transport::checked_url( $a->{base_url} // $base );
    my $origins = delete $a->{trusted_origins};
    Webmania::Error::throw( 'configuration', 'File origin requires explicit trusted_origins.' )
      unless ref $origins eq 'ARRAY'
      && grep { Webmania::Transport::checked_url( $_, 1 )->{origin} eq $b->{origin} } @$origins;
    $c->_new( $scope, $headers, $base, %$a );
}
1;
