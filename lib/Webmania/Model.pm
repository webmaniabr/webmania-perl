package Webmania::Model;
use strict;
use warnings;
use overload '""' => sub { ref( $_[0] ) . ' [private fiscal fields]' }, fallback => 1;
use Scalar::Util ();

sub new {
    my ( $class, %values ) = @_;
    my $m = $Webmania::Schema::MODEL{$class};
    Webmania::Error::throw( 'configuration', 'Unknown generated model.' ) unless $m;
    my $v = Webmania::JSON::snapshot( \%values );
    Webmania::Schema::validate( $m->{module}, $m->{schema}, $v );
    my $projected = Webmania::Schema::project( $m->{module}, $m->{schema}, $v );
    bless { values => ref($projected) eq 'HASH' ? $projected : $projected->{values} }, $class;
}
sub has { exists $_[0]{values}{ $_[1] } }
# Composite values are returned as independent copies: changes go through set/remove and validation.
sub get { _copy( $_[0]{values}{ $_[1] } ) }

sub _copy {
    my ($v) = @_;
    my $r = ref $v;
    return $v unless $r;
    return [ map { _copy($_) } @$v ] if $r eq 'ARRAY';
    return { map { $_ => _copy( $v->{$_} ) } keys %$v } if $r eq 'HASH';
    return bless { values => _copy( $v->{values} ) }, $r if Scalar::Util::blessed($v) && $v->isa('Webmania::Model');
    $v;
}

sub set {
    my ( $s, $k, $v ) = @_;
    my $m    = $Webmania::Schema::MODEL{ ref $s };
    my $p    = Webmania::Schema::properties( $m->{module}, $m->{schema} );
    my $snap = Webmania::JSON::snapshot($v);
    Webmania::Schema::validate( $m->{module}, $p->{$k}, $snap ) if exists $p->{$k};
    my %next = ( %{ $s->{values} }, $k => $snap );
    Webmania::Schema::validate( $m->{module}, $m->{schema}, \%next );
    $s->{values}{$k} = exists $p->{$k} ? Webmania::Schema::project( $m->{module}, $p->{$k}, $snap ) : $snap;
    $s;
}

sub remove {
    my ( $s, $k ) = @_;
    my %next = %{ $s->{values} };
    delete $next{$k};
    my $m = $Webmania::Schema::MODEL{ ref $s };
    Webmania::Schema::validate( $m->{module}, $m->{schema}, \%next );
    delete $s->{values}{$k};
    $s;
}
sub as_hash { Webmania::JSON::snapshot( $_[0] ) }
sub TO_JSON { '[private fiscal fields]' }

package Webmania::Scalar;
use strict;
use warnings;

sub new {
    my ( $class, $v ) = @_;
    my $m = $Webmania::Schema::MODEL{$class};
    my $s = Webmania::JSON::snapshot($v);
    Webmania::Schema::validate( $m->{module}, $m->{schema}, $s );
    $s;
}
1;
