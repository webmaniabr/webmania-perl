package Webmania::BaseClient;
use strict;
use warnings;
use Time::HiRes qw(sleep);

sub _bounded_int {
    my ( $v, $max ) = @_;
    return unless defined $v && Webmania::JSON::integer($v);
    my $n = Webmania::JSON::decimal($v);
    return if $n->bcmp(1) < 0 || $n->bcmp($max) > 0;
    0 + ( $n->bstr );
}

sub _helper_limits {
    my ( $self, $a ) = @_;
    my $options =
      exists $a->{options} ? Webmania::Transport::options( delete $a->{options} ) : { %{ $self->{options} } };
    my $deadline = delete $a->{deadline} // 120;
    Webmania::Error::throw( 'configuration', 'Helper deadline must be finite and in (0, 3600].' )
      unless !ref($deadline)
      && $deadline =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
      && $deadline > 0
      && $deadline <= 3600;
    ( $options, $deadline );
}

sub _pages {
    my ( $self, $method, $paths, %a ) = @_;
    my ( $options, $deadline ) = $self->_helper_limits( \%a );
    my $max_pages = delete $a{max_pages} // 100;
    my $max_items = delete $a{max_items} // 10000;
    Webmania::Error::throw( 'configuration', 'Pagination limits must be positive bounded integers.' )
      unless _bounded_int( $max_pages, 10000 ) && _bounded_int( $max_items, 1000000 );
    my $q = Webmania::JSON::snapshot( delete $a{query} // {} );
    Webmania::Error::throw( 'configuration', 'Unknown pagination option.' ) if keys %a;
    my $page = exists $q->{page}     ? _bounded_int( $q->{page},     1000000000 ) : 1;
    my $size = exists $q->{per_page} ? _bounded_int( $q->{per_page}, 1000000 )    : undef;
    Webmania::Error::throw( 'validation', 'Expected positive exact pagination values.' )
      unless $page && ( !exists $q->{per_page} || $size );
    Webmania::PageStream->new(
        client    => $self,
        method    => $method,
        paths     => $paths,
        query     => $q,
        page      => $page,
        page_size => $size,
        max_pages => $max_pages,
        max_items => $max_items,
        ending    => Webmania::Transport::now() + $deadline,
        options   => $options
    );
}

sub _poll {
    my ( $self, $method, $call, $report, %a ) = @_;
    my ( $options, $deadline ) = $self->_helper_limits( \%a );
    my $attempts = delete $a{max_attempts} // 20;
    my $interval = delete $a{interval}     // 5;
    Webmania::Error::throw( 'configuration',
        'Polling requires bounded attempts and an interval of at least five seconds.' )
      unless _bounded_int( $attempts, 1000 )
      && !ref $interval
      && $interval =~ /\A[0-9]+(?:\.[0-9]+)?\z/
      && $interval >= 5
      && $interval <= 3600;
    Webmania::Error::throw( 'configuration', 'Unknown polling option.' ) if keys %a;
    my $ending   = Webmania::Transport::now() + $deadline;
    my $workflow = { literal => [], uuids => [] };

    for my $i ( 1 .. $attempts ) {
        Webmania::Error::throw( 'cancelled', 'Polling cancelled.' )
          if $options->{cancel} && $options->{cancel}->cancelled;
        my $left = $ending - Webmania::Transport::now();
        Webmania::Error::throw( 'polling_timeout', 'Polling deadline expired.' ) if $left <= 0;
        my %o    = ( %$options, timeout => $left < $options->{timeout} ? $left : $options->{timeout} );
        my %args = ( %$call,    options => \%o );
        $args{_workflow} = $workflow if $report;
        my $r      = $self->$method(%args);
        my $v      = ref($r) eq 'HASH' ? $r : $r->as_hash;
        my $status = $v->{status};
        return $r
          if defined $status
          && !ref $status
          && ( $report ? $status eq 'concluido' : $status eq 'concluido' || $status eq 'invalido' );
        last if $i == $attempts;
        my $resume = Webmania::Transport::now() + $interval;

        while ( Webmania::Transport::now() < $resume ) {
            Webmania::Error::throw( 'cancelled', 'Polling cancelled.' )
              if $options->{cancel} && $options->{cancel}->cancelled;
            Webmania::Error::throw( 'polling_timeout', 'Polling deadline expired.' )
              if Webmania::Transport::now() >= $ending;
            sleep(.02);
        }
    }
    Webmania::Error::throw( 'polling_timeout', 'Polling attempt limit reached.' );
}

package Webmania::MonitorClient;
sub each_company { my ( $s, %a ) = @_; $s->_pages( 'list_companies', {}, %a ) }
sub each_report  { my ( $s, %a ) = @_; $s->_pages( 'list_reports',   {}, %a ) }

sub each_company_municipality {
    my ( $s, %a ) = @_;
    my $company = delete $a{company};
    $s->_pages( 'list_company_municipalities', { company => $company }, %a );
}

sub wait_import {
    my ( $s, %a ) = @_;
    my $uuid = delete $a{uuid};
    $s->_poll( 'get_import_status', { uuid => $uuid }, 0, %a );
}

package Webmania::NfeClient;

sub wait_report {
    my ( $s, %a ) = @_;
    my $body = Webmania::JSON::snapshot( delete $a{body} );
    $s->_poll( 'create_or_poll_report', { body => $body }, 1, %a );
}

package Webmania::PageStream;
use strict;
use warnings;
use overload '""' => sub { 'Webmania::PageStream [private query]' }, fallback => 1;

sub new {
    my ( $c, %a ) = @_;
    bless { %a, buffer => [], pages => 0, count => 0, finished => 0, continuation => undef }, $c;
}
sub continuation { defined $_[0]{continuation} ? { %{ $_[0]{continuation} } } : undef }

sub _check {
    my $s = shift;
    Webmania::Error::throw( 'cancelled', 'Pagination cancelled.' )
      if $s->{options}{cancel} && $s->{options}{cancel}->cancelled;
    Webmania::Error::throw( 'timeout', 'Pagination deadline expired.' )
      if Webmania::Transport::now() >= $s->{ending};
}

sub next {
    my $s = shift;
    $s->_check;
    return if $s->{finished};
    if ( !@{ $s->{buffer} } ) {
        if ( $s->{page_done} ) { $s->{page}++; $s->{page_done} = 0 }
        Webmania::Error::throw( 'pagination', 'Pagination page limit reached.' )
          if $s->{pages} >= $s->{max_pages};
        my %q    = ( %{ $s->{query} }, page => $s->{page} );
        my $left = $s->{ending} - Webmania::Transport::now();
        my %o =
          ( %{ $s->{options} }, timeout => $left < $s->{options}{timeout} ? $left : $s->{options}{timeout} );
        my $m    = $s->{method};
        my $r    = $s->{client}->$m( %{ $s->{paths} }, query => \%q, options => \%o );
        my $data = ref($r) eq 'HASH' ? $r->{data} : $r->get('data');
        my $meta = ref($r) eq 'HASH' ? $r->{meta} : $r->get('meta');
        $meta = $meta->as_hash if Scalar::Util::blessed($meta) && $meta->isa('Webmania::Model');
        Webmania::Error::throw( 'pagination', 'Expected offset pagination metadata.' )
          unless ref $data eq 'ARRAY' && ref $meta eq 'HASH';
        my $page = Webmania::BaseClient::_bounded_int( $meta->{current_page}, 1000000000 );
        my $last;

        if ( Webmania::JSON::integer( $meta->{last_page} ) ) {
            my $n = Webmania::JSON::decimal( $meta->{last_page} );
            $last = 0 + $n->bstr if $n->bcmp(0) >= 0 && $n->bcmp(1000000000) <= 0;
        }
        my $size = Webmania::BaseClient::_bounded_int( $meta->{per_page}, 1000000 );
        Webmania::Error::throw( 'pagination', 'Invalid pagination metadata.' )
          unless defined $page
          && $page == $s->{page}
          && defined $last
          && $last >= 0
          && $last <= 1000000000
          && $size
          && @$data <= $size;
        $s->{page_size} //= $size;
        Webmania::Error::throw( 'pagination', 'Pagination page size changed.' )
          unless $size == $s->{page_size};

        if ( $page > $last ) {
            Webmania::Error::throw( 'pagination', 'Nonempty out-of-range page.' ) if @$data;
            $s->{finished}     = 1;
            $s->{continuation} = undef;
            return;
        }
        Webmania::Error::throw( 'pagination', 'Nonfinal page is empty.' ) if !@$data && $page < $last;
        $s->{buffer} = $data;
        $s->{pages}++;
        $s->{index}     = 0;
        $s->{last_page} = $last;
        if ( !@$data ) { $s->{finished} = 1; $s->{continuation} = undef; return }
    }
    $s->_check;
    my $item = shift @{ $s->{buffer} };
    $s->{index}++;
    $s->{count}++;
    $s->{continuation} = { page => $s->{page}, index => $s->{index}, per_page => $s->{page_size} };
    if ( !@{ $s->{buffer} } ) {
        if ( $s->{page} >= $s->{last_page} ) { $s->{finished} = 1; $s->{continuation} = undef }
        else                                 { $s->{page_done} = 1 }
    }
    $s->{finished} = 1 if $s->{count} >= $s->{max_items};
    return $item;
}

sub each {
    my ( $s, $callback ) = @_;
    Webmania::Error::throw( 'configuration', 'Expected an item callback.' ) unless ref $callback eq 'CODE';
    while ( defined( my $item = $s->next ) ) { $callback->($item) }
    $s;
}
1;
