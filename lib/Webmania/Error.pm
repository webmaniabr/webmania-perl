package Webmania::Error;
use strict;
use warnings;
use overload '""' => sub { $_[0]{kind} . ': ' . $_[0]{message} }, fallback => 1;

sub new {
    my ( $class, $kind, $message, %context ) = @_;
    bless { kind => $kind, message => $message, %context }, $class;
}
sub throw { die __PACKAGE__->new(@_) }
for my $name (qw(kind message status outcome recovery location correlation_id details operation request_id)) {
    no strict 'refs';
    *{$name} = sub { $_[0]{$name} };
}

sub TO_JSON {
    my ($s) = @_;
    +{ map { $_ => $s->{$_} } qw(kind message status outcome operation request_id) };
}

package Webmania::Protected;
use overload '""' => sub { '[protected]' }, fallback => 1;
sub new     { bless { value => $_[1] }, $_[0] }
sub value   { $_[0]{value} }
sub TO_JSON { '[protected]' }

package Webmania::Cancel;
sub new       { bless { cancelled => 0 }, $_[0] }
sub cancel    { $_[0]{cancelled} = 1 }
sub cancelled { $_[0]{cancelled} }
1;
