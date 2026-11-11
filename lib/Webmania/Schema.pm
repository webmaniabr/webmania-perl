package Webmania::Schema;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use JSON::PP     ();
use Socket       ();
use Webmania::JSON;
our ( %DOC, %OP, %MODEL, %NAMED, %SHAPE );

sub readfile {
    my ($p) = @_;
    open my $f, '<:raw', $p
      or Webmania::Error::throw( 'configuration', 'Pinned contract resource is unavailable.' );
    local $/;
    Webmania::JSON::decode_json( <$f>, { nodes => 1000000 } );
}

sub load {
    my ($dir) = @_;
    my $models = readfile("$dir/models.json");
    %MODEL = %$models;
    my $ops = readfile("$dir/operations.json");
    %OP = %$ops;
    for my $o ( values %OP ) { $DOC{ $o->{module} } //= readfile("$dir/$o->{module}.json") }
    for my $class (
        sort {
            my $left  = defined $MODEL{$b}{primary} ? "$MODEL{$b}{primary}" : '0';
            my $right = defined $MODEL{$a}{primary} ? "$MODEL{$a}{primary}" : '0';
            $left cmp $right || $a cmp $b
        } keys %MODEL
      )
    {
        my $m = $MODEL{$class};
        $NAMED{ $m->{module} }{ Webmania::JSON::encode_json( $m->{schema} ) } //= $class;
        no strict 'refs';
        for my $field ( @{ $m->{fields} } ) {
            next unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
            next if $class->can($field);
            *{"${class}::$field"} = sub {
                my ( $self, @value ) = @_;
                return $self->get($field) unless @value;
                $self->set( $field, $value[0] );
                return $self;
            }
        }
    }
}

sub validate {
    my ( $mod, $schema, $value, $response ) = @_;
    my $nodes = 0;
    my $valid = eval { _valid( $mod, $schema, $value, 0, \$nodes ) };
    Webmania::Error::throw(
        $response ? 'response_schema' : 'validation',
        $response
        ? 'Response does not match the pinned contract.'
        : 'Value does not match the pinned contract.'
    ) unless $valid;
    1;
}

sub valid {
    my ( $m, $s, $v ) = @_;
    my $n  = 0;
    my $ok = eval { _valid( $m, $s, $v, 0, \$n ) };
    $@ ? 0 : $ok;
}

sub _valid {
    my ( $mod, $s, $v, $depth, $nodes ) = @_;
    return 0          if $depth > 96 || ++$$nodes > 300000;
    return $s ? 1 : 0 if JSON::PP::is_bool($s);
    return 0 unless ref $s eq 'HASH';
    if ( exists $s->{'$ref'} ) {
        my $r = $s->{'$ref'};
        return 0
          unless $r =~ m@\A#/components/schemas/([^/]+)\z@ && exists $DOC{$mod}{components}{schemas}{$1};
        return 0 unless _valid( $mod, $DOC{$mod}{components}{schemas}{$1}, $v, $depth + 1, $nodes );
    }
    my $kind = Webmania::JSON::kind($v);
    if ( exists $s->{type} ) {
        my @types = ref( $s->{type} ) eq 'ARRAY' ? @{ $s->{type} } : ( $s->{type} );
        return 0
          unless grep { $_ eq $kind || $_ eq 'integer' && $kind eq 'number' && Webmania::JSON::integer($v) }
          @types;
    }
    if ( exists $s->{const} ) { return 0 unless equal( $v, $s->{const} ) }
    if ( exists $s->{enum} ) {
        return 0 unless grep { equal( $v, $_ ) } @{ $s->{enum} };
    }
    for my $key (qw(allOf anyOf oneOf)) {
        next unless exists $s->{$key};
        my $ok = 0;
        for my $child ( @{ $s->{$key} } ) { $ok++ if _valid( $mod, $child, $v, $depth + 1, $nodes ) }
        return 0
          if $key eq 'allOf' && $ok != @{ $s->{$key} }
          || $key eq 'anyOf' && !$ok
          || $key eq 'oneOf' && $ok != 1;
    }
    return 0 if exists $s->{not} && _valid( $mod, $s->{not}, $v, $depth + 1, $nodes );
    if ( exists $s->{if} ) {
        my $key = _valid( $mod, $s->{if}, $v, $depth + 1, $nodes ) ? 'then' : 'else';
        return 0 if exists $s->{$key} && !_valid( $mod, $s->{$key}, $v, $depth + 1, $nodes );
    }
    if ( $kind eq 'object' ) {
        $v = $v->{values} if blessed $v;
        for my $k ( @{ $s->{required} // [] } ) { return 0 unless exists $v->{$k} }
        my $n = keys %$v;
        return 0
          if exists $s->{minProperties} && $n < 0 + "$s->{minProperties}"
          || exists $s->{maxProperties} && $n > 0 + "$s->{maxProperties}";
        for my $k ( keys %{ $s->{dependentRequired} // {} } ) {
            if ( exists $v->{$k} ) {
                for my $d ( @{ $s->{dependentRequired}{$k} } ) { return 0 unless exists $v->{$d} }
            }
        }
        my $props = $s->{properties} // {};
        for my $k ( keys %$v ) {
            if ( exists $props->{$k} ) {
                return 0 unless _valid( $mod, $s->{properties}{$k}, $v->{$k}, $depth + 1, $nodes );
            }
            elsif ( exists $s->{additionalProperties} ) {
                my $a = $s->{additionalProperties};
                return 0 if JSON::PP::is_bool($a) && !$a;
                return 0 if ref $a eq 'HASH'      && !_valid( $mod, $a, $v->{$k}, $depth + 1, $nodes );
            }
        }
    }
    if ( $kind eq 'array' ) {
        return 0
          if exists $s->{minItems} && @$v < 0 + "$s->{minItems}"
          || exists $s->{maxItems} && @$v > 0 + "$s->{maxItems}";
        if ( exists $s->{items} ) {
            for my $x (@$v) { return 0 unless _valid( $mod, $s->{items}, $x, $depth + 1, $nodes ) }
        }
    }
    if ( $kind eq 'string' ) {
        return 0
          if exists $s->{minLength} && length($v) < 0 + "$s->{minLength}"
          || exists $s->{maxLength} && length($v) > 0 + "$s->{maxLength}";
        if ( exists $s->{pattern} ) { my $p = $s->{pattern}; $p =~ s/\$$/\\z/; return 0 unless $v =~ /$p/a }
        if ( exists $s->{format} )  { return 0 unless _format( $s->{format}, $v ) }
    }
    if ( $kind eq 'number' ) {
        my $n = Webmania::JSON::decimal($v);
        return 0
          if exists $s->{minimum} && $n->bcmp( Webmania::JSON::decimal( $s->{minimum} ) ) < 0
          || exists $s->{maximum} && $n->bcmp( Webmania::JSON::decimal( $s->{maximum} ) ) > 0;
    }
    for my $k (qw(x-sdk-numeric-minimum x-sdk-numeric-maximum)) {
        next unless exists $s->{$k} && ( $kind eq 'number' || $kind eq 'string' );
        my $text = "$v";
        $text =~ tr/,/./;
        return 0
          unless $text =~ /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
          && length($text) <= 512;
        my $n = Math::BigFloat->new( $text,      undef, undef );
        my $b = Math::BigFloat->new( "$s->{$k}", undef, undef );
        return 0
          if $n->is_nan
          || $n->is_inf
          || $k eq 'x-sdk-numeric-minimum' && $n->bcmp($b) < 0
          || $k eq 'x-sdk-numeric-maximum' && $n->bcmp($b) > 0;
    }
    return 1;
}

sub equal {
    my ( $a, $b ) = @_;
    my $ka = Webmania::JSON::kind($a);
    my $kb = Webmania::JSON::kind($b);
    return 0 unless $ka eq $kb;
    return Webmania::JSON::decimal($a)->bcmp( Webmania::JSON::decimal($b) ) == 0 if $ka eq 'number';
    return 1                                                                     if $ka eq 'null';
    return ( $a ? 1 : 0 ) == ( $b ? 1 : 0 )                                      if $ka eq 'boolean';
    return $a eq $b                                                              if $ka eq 'string';
    return 0                                                                     if $ka eq 'invalid';
    $a = $a->{values} if blessed($a);
    $b = $b->{values} if blessed($b);

    if ( $ka eq 'array' ) {
        return 0 unless @$a == @$b;
        for ( 0 .. $#$a ) { return 0 unless equal( $a->[$_], $b->[$_] ) }
        return 1;
    }
    return 0 unless keys(%$a) == keys(%$b);
    for ( keys %$a ) { return 0 unless exists $b->{$_} && equal( $a->{$_}, $b->{$_} ) }
    return 1;
}

sub _format {
    my ( $f, $v ) = @_;
    return $v =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i if $f eq 'uuid';
    if ( $f eq 'date' ) {
        return 0 unless $v =~ /\A([0-9]{4})-(0[1-9]|1[0-2])-([0-9]{2})\z/;
        my ( $y, $m, $d ) = ( $1, 0 + $2, 0 + $3 );
        my @days = (
            0,  31, 28 + ( $y % 4 == 0 && ( $y % 100 != 0 || $y % 400 == 0 ) ),
            31, 30, 31, 30, 31, 31, 30, 31, 30, 31
        );
        return $d >= 1 && $d <= $days[$m];
    }
    return _email($v) if $f eq 'email';
    return _uri($v)   if $f eq 'uri';
    1;
}

# RFC3986 generic URI grammar. URI is ASCII; provider report URLs without a URI
# format assertion remain arbitrary Unicode strings and are preserved as such.
sub _uri {
    my ($value) = @_;
    return 0 unless $value =~ /\A[A-Za-z][A-Za-z0-9+.-]*:([^\x00-\x20\x7f-\x{10ffff}]*)\z/;
    my $rest = $1;
    my $unit = qr/(?:[A-Za-z0-9._~!\$&'()*+,;=:@-]|%[A-Fa-f0-9]{2})/;
    my ( $hierarchy, $fragment ) = split /#/, $rest, 2;
    $hierarchy //= '';
    return 0 if defined($fragment) && $fragment !~ /\A(?:$unit|[\/?])*\z/;
    my ( $path, $query ) = split /\?/, $hierarchy, 2;
    $path //= '';
    return 0 if defined($query) && $query !~ /\A(?:$unit|[\/?])*\z/;

    if ( $path =~ m@\A//@ ) {
        my ( $authority, $remaining ) = split m@/@, substr( $path, 2 ), 2;
        $authority //= '';
        $path = defined($remaining) ? '/' . $remaining : '';
        if ( $authority =~ /@/ ) {
            return 0 unless $authority =~ s/\A(?:[A-Za-z0-9._~!\$&'()*+,;=:-]|%[A-Fa-f0-9]{2})*\@//;
        }
        if ( $authority =~ /\A\[/ ) {
            return 0 unless $authority =~ /\A\[([^\]]+)\](?::[0-9]*)?\z/;
            my $literal = $1;
            return 0
              unless Socket::inet_pton( Socket::AF_INET6(), $literal )
              || $literal =~ /\Av[A-Fa-f0-9]+\.[A-Za-z0-9._~!\$&'()*+,;=:-]+\z/i;
        }
        else {
            return 0 unless $authority =~ /\A(?:[A-Za-z0-9._~!\$&'()*+,;=-]|%[A-Fa-f0-9]{2})*(?::[0-9]*)?\z/;
        }
    }
    return $path =~ /\A(?:$unit|\/)*\z/;
}

# The pinned `email` format uses the ASCII RFC5321 mailbox grammar, including
# quoted local-parts, a single domain label and address literals.
sub _email {
    my ($value) = @_;
    return 0 if length($value) > 254 || $value =~ /[^\x20-\x7e]/;
    return 0
      unless $value =~
/\A((?:[A-Za-z0-9!#\$%&'*+\-\/=?^_`{|}~]+(?:\.[A-Za-z0-9!#\$%&'*+\-\/=?^_`{|}~]+)*|"(?:[\x20-\x21\x23-\x5b\x5d-\x7e]|\\[\x20-\x7e])*"))\@(.+)\z/;
    my ( $local, $domain ) = ( $1, $2 );
    return 0 if length($local) > 64 || length($domain) > 255;
    if ( $domain =~ /\A\[(.*)\]\z/ ) {
        my $literal = $1;
        if ( $literal =~ /\A[0-9]+(?:\.[0-9]+){3}\z/ ) {
            return !grep { length($_) > 3 || $_ > 255 } split /\./, $literal;
        }
        return !!Socket::inet_pton( Socket::AF_INET6(), $1 ) if $literal =~ /\AIPv6:(.+)\z/i;
        return $literal =~ /\A[A-Za-z0-9][A-Za-z0-9-]*:[\x21-\x5a\x5e-\x7e]+\z/;
    }
    for my $label ( split /\./, $domain, -1 ) {
        return 0 unless length($label) <= 63 && $label =~ /\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/;
    }
    return 1;
}

sub properties {
    my ( $m, $s, $seen ) = @_;
    $seen //= {};
    my %p = %{ $s->{properties} // {} };
    if ( my $r = $s->{'$ref'} ) {
        my $key = ( split '/', $r )[-1];
        if ( !$seen->{$key}++ ) {
            %p = ( %{ properties( $m, $DOC{$m}{components}{schemas}{$key}, $seen ) }, %p );
        }
    }
    for my $k (qw(allOf anyOf oneOf)) {
        for my $c ( @{ $s->{$k} // [] } ) { %p = ( %p, %{ properties( $m, $c, {%$seen} ) } ) }
    }
    return \%p;
}

# Projection follows only alternatives that actually accept this value. The
# structural field inventory above deliberately includes all alternatives for
# generated accessors, but a field in a different branch cannot choose its type.
sub effective_properties {
    my ( $mod, $schema, $value, $seen ) = @_;
    $seen //= {};
    my %fields = %{ $schema->{properties} // {} };
    if ( my $ref = $schema->{'$ref'} ) {
        my $name = ( split '/', $ref )[-1];
        unless ( $seen->{$name}++ ) {
            %fields = (
                %{ effective_properties( $mod, $DOC{$mod}{components}{schemas}{$name}, $value, $seen ) },
                %fields
            );
        }
    }
    for my $child ( @{ $schema->{allOf} // [] } ) {
        %fields = ( %fields, %{ effective_properties( $mod, $child, $value, {%$seen} ) } );
    }
    for my $keyword (qw(anyOf oneOf)) {
        my @matching = grep { valid( $mod, $_, $value ) } @{ $schema->{$keyword} // [] };
        @matching =
          sort { scalar( keys %{ properties( $mod, $b ) } ) <=> scalar( keys %{ properties( $mod, $a ) } ) }
          @matching;
        %fields = ( %fields, %{ effective_properties( $mod, $matching[0], $value, {%$seen} ) } ) if @matching;
    }
    return \%fields;
}

sub project {
    my ( $mod, $s, $v, $depth ) = @_;
    $depth //= 0;
    return $v if $depth > 64;
    my $kind = Webmania::JSON::kind($v);
    return $v unless $kind eq 'object' || $kind eq 'array';
    my $refname;
    if ( $s->{'$ref'} ) {
        $refname = ( split '/', $s->{'$ref'} )[-1];
        $s       = $DOC{$mod}{components}{schemas}{$refname};
    }
    for my $k (qw(anyOf oneOf)) {
        if ( $s->{$k} ) {
            my @match = grep { valid( $mod, $_, $v ) } @{ $s->{$k} };
            @match = sort {
                scalar( keys %{ properties( $mod, $b ) } ) <=> scalar( keys %{ properties( $mod, $a ) } )
            } @match;
            return project( $mod, $match[0], $v, $depth + 1 ) if @match && !$s->{properties} && !$s->{allOf};
        }
    }
    if ( $kind eq 'array' ) {
        return [ map { project( $mod, $s->{items} // {}, $_, $depth + 1 ) } @$v ];
    }
    my $p = effective_properties( $mod, $s, $v );
    my %out =
      map { $_ => exists $p->{$_} ? project( $mod, $p->{$_}, $v->{$_}, $depth + 1 ) : $v->{$_} } keys %$v;
    my $class = $NAMED{$mod}{ Webmania::JSON::encode_json($s) };
    return $class && !$MODEL{$class}{scalar} ? bless( { values => \%out }, $class ) : \%out;
}
1;
