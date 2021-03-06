package CanIt::API::Client;
use strict;
use warnings;
use Carp;

use vars qw( $VERSION );
$VERSION = '10.2.5';

use JSON::Any;
use HTTP::Request::Common ( );
use HTTP::Response;
use HTTP::Status;
use URI;
use LWP::UserAgent;

sub new
{
	my($class, $args) = @_;

	if( !defined $args ) {
		$args = {}
	}

	my $self = bless {%$args}, $class; ## no critic (ProhibitDoubleSigils)

	if( $self->{version} ) {
		# Remove trailing slashes from base
		$self->{base} =~ s|/+$||;

		# Append version to base URI
		$self->{base} = join(q{/}, $self->{base}, $self->{version});

		# Make sure it DOES NOT end with a slash
		$self->{base} =~ s|/+$||;
	} else {
		# Remove trailing slashes from base
		$self->{base} =~ s|/+$||;
	}

	if (! exists($self->{autologout})) {
		$self->{autologout} = 1;
	}

	$self->{ua} = LWP::UserAgent->new(
		agent                 => "CanIt::API::Client/$VERSION",
		cookie_jar            => {}, # Want cookies
		requests_redirectable => [ 'GET', 'HEAD', 'POST' ],
	);

	$self->{ua}->default_headers()->header('Accept', 'application/json');
	$self->{ua}->timeout(3600);

	$self->{logged_in} = 0;
	return $self;
}

my %possible_http_responses = (
	RC_UNAUTHORIZED, q{Authentication Required},
	RC_FORBIDDEN,    q{Incorrect user or password provided},
	RC_NOT_FOUND,    q{Base URI not found on server},
);

sub get_base
{
	return $_[0]->{base}
}

sub get_version
{
	return $_[0]->{version}
}

sub set_base
{
	$_[0]->{base} = $_[1];
}

sub set_version
{
	$_[0]->{version} = $_[1];
}

sub get_last_result
{
	my ($self) = @_;
	return $self->{_last_result};
}

sub get_last_value
{
	my ($self) = @_;
	my $res = $self->{_last_result};
	return undef unless defined ($res);
	return undef unless HTTP::Status::is_success($res->code);
	my $ans;
	if (lc($res->header('Content-Type') eq 'message/rfc822')) {
		return { message => $res->content };
	}

	eval { $ans = JSON::Any->Load($res->content) };
	return $ans;
}

sub get_last_error
{
	my ($self) = @_;
	if( ! defined $self->{_last_result} ) {
		return undef;
	}

	# If last result returned JSON and has an
	# error element, use that
	my $result = undef;
	if ($self->{_last_result}->content) {
		eval { $result = JSON::Any->Load($self->{_last_result}->content); };
		if ($result &&
		    ref($result) eq 'HASH' &&
		    exists($result->{error}) &&
		    defined($result->{error})) {
			return $result->{error};
		}
	}

	my $code = $self->{_last_result}->code();
	if( exists $possible_http_responses{ $code } ) {
		return $possible_http_responses{ $code };
	}

	return $self->{_last_result}->status_line;
}

sub login ## no critic ( ProhibitBuiltinHomonyms )
{
	my ($self, $user, $password) = @_;

	# Should give us a cookie
	$self->{_last_result} = $self->POST_request( 'login', { user => $user, password => $password } );

	if (HTTP::Status::is_success($self->{_last_result}->code)) {
		$self->{logged_in} = 1;
	}
	return HTTP::Status::is_success($self->{_last_result}->code);
}

sub get_canit_cookie
{
	my ($self) = @_;
	my $str = '';
	$self->{ua}->cookie_jar()->scan(sub {
		if ($_[1] eq 'CANIT') {
			$str = (
				($_[0] || 0) . ',' .
				($_[1] || '') . ',' .
				($_[2] || '') . ',' .
				($_[3] || '') . ',' .
				($_[4] || '') . ',' .
				($_[5] || '') . ',' .
				($_[6] || '') . ',' .
				($_[7] || '') . ',' .
				($_[8] || '') . ',' .
				($_[9] || '') . ',' .
				($_[10] || ''));
		}
				     });
	return $str;
}

sub set_canit_cookie
{
	my ($self, $str) = @_;
	my($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, $hash) = (split(/,/, $str));
	$port = undef unless defined($port) && ($port =~ /\d+/);
	$secure = undef if defined($secure) && $secure eq '';
	$expires = undef if defined($expires) && $expires eq '';
	$discard = undef if defined($discard) && $discard eq '';
	$self->{ua}->cookie_jar()->set_cookie($version, $key, $val, $path, $domain, $port, $path_spec, $secure, $expires, $discard, undef);
	$self->{logged_in} = 1;
}

sub get_raw_canit_cookie
{
	my ($self) = @_;
	my $str = '';
	$self->{ua}->cookie_jar()->scan(sub {
		if ($_[1] eq 'CANIT') {
			$str = ($_[2] || '');
		}
					});
	return $str;
}

sub logout
{
	my ($self) = @_;
	return 1 unless $self->{logged_in};

	$self->{_last_result} = $self->POST_request( 'logout', { } );

	$self->{logged_in} = 0;

	return HTTP::Status::is_success($self->{_last_result}->code);
}

sub DESTROY
{
	my ($self) = @_;
	if ($self->{autologout} && $self->{logged_in}) {
		eval {
			$self->logout();
		};
	}
}

sub do_get
{
	my ($self, $partial_uri, $content_ref) = @_;
	my $result = $self->GET_request($partial_uri, $content_ref);
	if (!HTTP::Status::is_success($result->code)) {
		return undef;
	}

	# Handle message/rfc822 responses from archiver specially!
	if (lc($result->header('Content-Type') eq 'message/rfc822')) {
		return { message => $result->content };
	}

	my $ans;
	eval { $ans = JSON::Any->Load($result->content) };
	if ($@) {
		$self->{_last_result} = HTTP::Response->new(600, "Could not parse JSON: $@: " . $result->content);
		return undef;
	}
	return $ans;
}

sub GET_request
{
	my ($self, $partial_uri, $query_ref, $header_ref) = @_;

	my $uri = $self->_mk_uri_object( $partial_uri );

	if( defined $query_ref ) {
		$uri->query_form( $query_ref );
	}

	my $req = HTTP::Request->new( 'GET', $uri, $header_ref );

	$self->{_last_result} = $self->{ua}->request( $req );

	return $self->{_last_result};
}

sub do_delete
{
	my ($self, $partial_uri) = @_;

	my $result = $self->DELETE_request($partial_uri);
	return HTTP::Status::is_success($result->code);
}

sub DELETE_request
{
	my ($self, $partial_uri, $header_ref) = @_;

	my $uri = $self->_mk_uri_object( $partial_uri );

	my $req = HTTP::Request->new( 'DELETE', $uri, $header_ref );

	$self->{_last_result} = $self->{ua}->request( $req );
	return $self->{_last_result};
}

sub do_post
{
	my ($self, $partial_uri, $content_ref) = @_;
	my $result = $self->POST_request($partial_uri, $content_ref);
	return HTTP::Status::is_success($result->code);
}

sub POST_request
{
	my ($self, $partial_uri, $content_ref, $header_ref) = @_;

	my $uri = $self->_mk_uri_object( $partial_uri );

	my %headers;
	if( defined $header_ref ) {
		%headers = %{ $header_ref };
	}

	my $req = HTTP::Request::Common::POST($uri, $content_ref, %headers);

	$self->{_last_result} = $self->{ua}->request( $req );
	return $self->{_last_result};
}

sub do_put
{
	my ($self, $partial_uri, $content_ref) = @_;

	my $result = $self->PUT_request($partial_uri, $content_ref);
	return HTTP::Status::is_success($result->code);
}

sub PUT_request
{
	my ($self, $partial_uri, $content_ref, $header_ref) = @_;

	my $uri = $self->_mk_uri_object( $partial_uri );

	my $content = JSON::Any->Dump( $content_ref );
	my %headers;
	if( defined $header_ref ) {
		%headers = %{ $header_ref };
	}

	my $req = HTTP::Request::Common::PUT($uri,
		%headers,
		'Content-type' => 'application/json',
		'Content-length' => length $content,
		Content => $content
	);

	$self->{_last_result} = $self->{ua}->request( $req );
	return $self->{_last_result};
}

# Ensure that the URI is a URI object
sub _mk_uri_object
{
	my ($self, $relative_uri) = @_;

	my $uri_str = $self->get_base();
	$uri_str .= '/' unless (substr($uri_str, -1) eq '/' || substr($relative_uri, 0, 1) eq '/');
	$uri_str .= $relative_uri;

	return URI->new( $uri_str )->canonical;
}


1;
__END__

=head1 NAME

CanIt::API::Client - Simple client for CanIt REST API

=head1 SYNOPSIS

    use CanIt::API::Client;

    my $api = CanIt::API::Client->new({
	base     => 'http://canit.example.com/api',
	version  => '2.0',
    });

    $api->login($user, $pass);

    my $incident = $api->do_get( '/incident/1234' );
    if( $incident ) {
	$api->do_post( '/incident/1234', { status => spam, resolution => discard });
    }

=head1 DESCRIPTION

This is a fairly thin wrapper around CanIt's REST API (version 2.0 as
of this writing) to facilitate scripting in Perl.

=head1 CLASS METHODS

=head2 new ( $args )

This method constructs a new C<CanIt::API::Client> object and returns it.
A hashref containing key-value pair arguments should be provided to set
the initial state.  The following are the available keys:

   KEY            USAGE                             DEFAULT
   ------------   -----------------------           -------
   base           Base URI for API server           undef
   version        Version of API to use             undef
   autologout     Log out when we go out of scope   1

Normally, when a CanIt::API::Client object goes out of scope, the
perl DESTROY method destroys the session by calling logout().  If you do
not want this to happen, use autologout => 0 in the new({}) call.

=head1 INSTANCE METHODS

=head2 login ( $username, $password )

Connects to the API server and logs in.  On successful login, a cookie
will be retrieved from the API server and stored internally for subsequent
API calls.

The method returns true on successful login; false otherwise.

=head2 logout ( )

Calls the API '/logout' method to invalidate the session cookie, and
destroys the client session.

Should be invoked as the last action when done with API commands.

=head2 do_get ( $uri_fragment, $content_ref )

Perform a GET with the given URI fragment.  If an error occurs,
returns undef.  Otherwise, returns a Perl data structure (either
an array of hashes or a single hash, depending on the query) containing
the data returned by the API server.

If $content_ref is supplied, it should be a reference to a hash.
The hash is URL-encoded and appended to the URL as a query string.

=head2 do_delete ( $uri_fragment )

Perform a DELETE with the given URI fragment.  Returns true if the
DELETE was successful, false otherwise.

=head2 do_post ( $uri_fragment, $content_ref)

Peform a POST to the object at the given URI fragment.  $content_ref
is a reference to a hash containing key/value pairs to be used
for the POST request.  It is automatically converted to a proper
C<application/x-www-form-urlencoded> content type.

The method returns true if the POST was successful; false otherwise.

=head2 do_put ( $uri_fragment, $content_ref)

Peform a PUT to the object at the given URI fragment.  $content_ref
is a reference to a hash containing key/value pairs to be used
for the PUT request.  It is automatically converted to a proper
serialized data stream for the API server.

The method returns true if the PUT was successful; false otherwise.

=head2 GET_request ( $uri_fragment, $query_ref, $header_ref )

NOTE: This is a lower-level method than do_get.  You should normally
call do_get rather than GET_request.

Perform a GET for the given URI fragment from the API server.

$query_ref is an optional hash reference containing key-value pairs to
be used as query parameters.

$header_ref is an optional hash reference containing key-value pairs to
be used as additional HTTP headers.

Returns an HTTP::Response object.

=head2 DELETE_request ( $uri_fragment, $header_ref )

NOTE: This is a lower-level method than do_delete.  You should normally
call do_delete rather than DELETE_request.

Perform a DELETE of the object at the given URI fragment from the API
server.

$header_ref is an optional hash reference containing key-value pairs to
be used as additional HTTP headers.

Returns an HTTP::Response object.

=head2 POST_request ( $uri_fragment, $content_ref, $header_ref )

NOTE: This is a lower-level method than do_post.  You should normally
call do_post rather than POST_request.

Perform a POST to the object at the given URI fragment on the API
server.

$content_ref is a reference to an array or hash reference to be used
for the POST request.  It is automatically converted to key-value
submissions encoded in the C<application/x-www-form-urlencoded>
content type.

$header_ref is an optional hash reference containing key-value pairs to
be used as additional HTTP headers.

Returns an HTTP::Response object.

=head2 PUT_request ( $uri_fragment, $content_ref, $header_ref )

NOTE: This is a lower-level method than do_put.  You should normally
call do_put rather than PUT_request.

Perform a PUT to the object at the given URI fragment on the API
server.

$content_ref is a reference to the content to be sent as the PUT body.
It will be automatically serialized as JSON and submitted under the
C<application/json> content-type.

$header_ref is an optional hash reference containing key-value pairs to
be used as additional HTTP headers.

Returns an HTTP::Response object.

=head2 get_last_result ( )

Returns the HTTP::Response object from the most recent GET, PUT, POST or
DELETE operation.  Returns undef if there was no operation performed yet.

See the HTTP::Response documentation for details about methods you can
call on the result.

=head2 get_last_value ( )

Returns the Perl data structure that was deserialized from the result
of the most recent GET, PUT or POST operation.  Do not call this method
unless the most recent do_get, do_put or do_post operation returned success.

=head2 get_last_error ( )

Attempts to return a useful textual error message from the last API
request made, by overriding some of the default messages.

=head2 get_base ( )

Retrieve base URI

=head2 get_version ( )

Retrieve API version

=head2 set_base ( $string )

Set the base URI

=head2 set_version ( $string )

Set the API version

=head2 get_canit_cookie ( )

Returns a string that is suitable for use in a set_canit_cookie call.
Note that get_canit_cookie only returns a meaningful result afer
a successful call to $api->login().

=head2 set_canit_cookie ( $str )

Given a string returned by get_canit_cookie(), set the cookie.  This
eliminates the need to call login() (assuming the cookie is still valid.)

=head2 get_raw_canit_cookie ( )

Returns a string that contains only the cookie value.  This string may
not be used by set_canit_cookie, but can be passed to other software
to continue using the session.  The other software should simply pass
a cookie called CANIT with the value returned by get_raw_canit_cookie()
to the CanIt server.  You most likely want to construct your $api object
with autologout set to 0 in this case.

Note that get_raw_canit_cookie only returns a meaningful result after
a successful call to $api->login().

=head1 DEPENDENCIES

L<HTTP::Request>
L<HTTP::Response>
L<HTTP::Status>
L<LWP::UserAgent>
L<URI>
L<JSON::Any>

=head1 INCOMPATIBILITIES

There are no known incompatibilities with this module.

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.
Please report any problems to Roaring Penguin.

=head1 AUTHOR

Dave O'Neill (dmo@roaringpenguin.com)

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007-2009 Roaring Penguin Software, Inc.  All rights reserved.
