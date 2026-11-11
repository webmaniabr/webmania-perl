package Webmania;
use 5.036;
use strict;
use warnings;
our $VERSION = '0.1.0_03';
use Webmania::Error;
use Webmania::JSON;
use Webmania::Schema;
use Webmania::Model;
use Webmania::Redactor;
use Webmania::Transport;
use Webmania::Files;
use Webmania::Client;
use Webmania::Generated;
use Webmania::Helpers;
use File::Basename qw(dirname);
use File::Spec;
Webmania::Schema::load( File::Spec->catdir( dirname(__FILE__), 'Webmania', 'contracts' ) );
Webmania::Redactor::init_public();
sub number { Webmania::Number->new( $_[0] ) }
sub true   { JSON::PP::true() }
sub false  { JSON::PP::false() }
1;
