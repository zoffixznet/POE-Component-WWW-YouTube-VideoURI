package POE::Component::WWW::YouTube::VideoURI;

use warnings;
use strict;

our $VERSION = '0.06';

use WWW::YouTube::VideoURI;
use LWP::UserAgent;
use POE qw( Wheel::Run  Filter::Reference  Filter::Line );
use Carp;

sub spawn {
    my $package = shift;
    croak "Must have an even number of arguments to spawn()"
        if @_ & 1;

    my %params = @_;
    
    $params{ lc $_ } = delete $params{ $_ } for keys %params;
    
    delete $params{options}
        unless ref $params{options} eq 'HASH';

    my $self = bless \%params, $package;
    
    $self->{session_id} = POE::Session->create(
        object_states => [
            $self => {
                get_uri  => '_get_uri',
                store    => '_store',
                shutdown => '_shutdown',
            },
            $self => [
                qw(
                    _child_closed
                    _child_error
                    _child_stderr
                    _child_stdout
                    _store_stdout
                    _sig_chld
                    _start
                )
            ],
        ],
    ( defined $params{options} ? ( options => $params{options} ) : () ),
    )->ID;
    
    return $self;
}

sub _start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $self->{session_id} = $_[SESSION]->ID();
    
    if ( $self->{alias} ) {
        $kernel->alias_set( $self->{alias} );
    }
    else {
        $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
    }
    
    $self->{wheel} = POE::Wheel::Run->new(
        Program     => \&_tube_wheel,
        ErrorEvent  => '_child_error',
        CloseEvent  => '_child_closed',
        StderrEvent => '_child_stderr',
        StdoutEvent => '_child_stdout',
        StdioFilter => POE::Filter::Reference->new,
        StderrFilter => POE::Filter::Line->new,
        ( $^O eq 'MSWin32' ? ( CloseOnCall => 0 ) : ( CloseOnCall => 1 ) ),
    );

    $self->{wheel_store} = POE::Wheel::Run->new(
        Program     => \&_store_wheel,
        ErrorEvent  => '_child_error',
        CloseEvent  => '_child_closed',
        StderrEvent => '_child_stderr',
        StdoutEvent => '_store_stdout',
        StdioFilter => POE::Filter::Reference->new,
        StderrFilter => POE::Filter::Line->new,
        ( $^O eq 'MSWin32' ? ( CloseOnCall => 0 ) : ( CloseOnCall => 1 ) ),
    );
    
    $kernel->yield('shutdown')
        if !$self->{wheel} or !$self->{wheel_store};

    $kernel->sig_child( $self->{wheel      }->PID, '_sig_chld' );
    $kernel->sig_child( $self->{wheel_store}->PID, '_sig_chld' );
    
    undef;
}

sub _sig_chld {
    $poe_kernel->sig_handled;
}

sub session_id {
    return $_[0]->{session_id};
}

sub store {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => store => @_ );
}

sub _store {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my $sender = $_[SENDER]->ID;
    
    return
        if $self->{shutdown};
   my $args;
    
    if ( ref $_[ARG0] eq 'HASH' ) {
        $args = { %{ $_[ARG0] } };
    }
    else {
        warn "First parameter must be a hashref, trying to adjust";
        $args = { @_[ARG0 .. $#_] };
    }
    
    $args->{ lc $_ } = delete $args->{ $_ }
        for grep { !/^_/ } keys %$args;

    unless ( $args->{store_event} ) {
        warn "No `store_event` parameter specified. Aborting...";
        return;
    }

    unless ( $args->{where} ) {
        warn "No `where` parameter specified. Aborting...";
        return;
    }
    
    unless ( $args->{flv_uri} ) {
        warn "No `flv_uri` parameter specified. Aborting...";
        return;
    }
        
    if ( $args->{store_session} ) {
        if ( my $ref = $kernel->alias_resolve( $args->{store_session} ) ) {
            $args->{sender} = $ref->ID;
        }
        else {
            warn "Could not resolve `store_session` parameter to a "
                    . "valid POE session. Aborting...";
            return;
        }
    }
    else {
        $args->{sender} = $sender;
    }
    
    $kernel->refcount_increment( $args->{sender} => __PACKAGE__ )
        unless delete $args->{internal};
        
    $self->{wheel_store}->put( $args );
    
    undef;
}

sub get_uri {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => get_uri => @_ );
}

sub _get_uri {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my $sender = $_[SENDER]->ID;
    
    return
        if $self->{shutdown};

    my $args;
    
    if ( ref $_[ARG0] eq 'HASH' ) {
        $args = { %{ $_[ARG0] } };
    }
    else {
        warn "First parameter must be a hashref, trying to adjust";
        $args = { @_[ARG0 .. $#_] };
    }
    
    $args->{ lc $_ } = delete $args->{ $_ }
        for grep { !/^_/ } keys %$args;

    unless ( $args->{event} ) {
        warn "No `event` parameter specified. Aborting...";
        return;
    }

    unless ( $args->{uri} ) {
        warn "No `uri` parameter specified. Aborting...";
        return;
    }

    unless ( exists $args->{get_title} ) {
        $args->{get_title} = 1;
    }

    if ( $args->{session} ) {
        if ( my $ref = $kernel->alias_resolve( $args->{session} ) ) {
            $args->{sender} = $ref->ID;
        }
        else {
            warn "Could not resolve `session` parameter to a "
                    . "valid POE session. Aborting...";
            return;
        }
    }
    else {
        $args->{sender} = $sender;
    }
    $kernel->refcount_increment( $args->{sender} => __PACKAGE__ );
    $self->{wheel}->put( $args );
    
    undef;
}

sub shutdown {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => 'shutdown' => @_ );
}

sub _shutdown {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $kernel->alarm_remove_all;
    $kernel->alias_remove( $_ ) for $kernel->alias_list;
    $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ )
        unless $self->{alias};

    $self->{shutdown} = 1;
    $self->{wheel}->shutdown_stdin
        if $self->{wheel};
        
    $self->{wheel_store}->shutdown_stdin
        if $self->{wheel_store};
}

sub _child_closed {
    my ( $kernel, $self, $wheel_id ) = @_[ KERNEL, OBJECT, ARG0 ];

    warn "_child_closed called (@_[ARG0..$#_])\n"
        if $self->{debug};

    delete @{ $self }{ qw(wheel wheel_store) };
    $kernel->yield('shutdown')
        unless $self->{shutdown};

    undef;
}

sub _child_error {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    warn "_child_error called (@_[ARG0..$#_])\n"
        if $self->{debug};

    delete @{ $self }{ qw(wheel wheel_store) };
    $kernel->yield('shutdown')
        unless $self->{shutdown};

    undef;
}

sub _child_stderr {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    warn "_child_stderr: $_[ARG0]\n"
        if $self->{debug};

    undef;
}

sub _store_stdout {
    my ( $kernel, $self, $input ) = @_[ KERNEL, OBJECT, ARG0 ];
    
    my $session = delete $input->{sender};
    my $event   = delete $input->{store_event};
    $input->{is_store} = 1;
    $kernel->post( $session, $event, $input );
    $kernel->refcount_decrement( $session => __PACKAGE__ );

    undef;
}

sub _child_stdout {
    my ( $kernel, $self, $input ) = @_[ KERNEL, OBJECT, ARG0 ];
    
    my $session = delete $input->{sender};
    my $event   = delete $input->{event};

    $kernel->post( $session, $event, $input );

    if ( 
        $input->{where}
        and not $input->{error}
    ) {
        my $store_args = { %{ $input } };
        
        $store_args->{store_session} = $session
            unless $store_args->{store_session};

         $kernel->refcount_increment(
             $store_args->{store_session} => __PACKAGE__
         );
         $store_args->{internal} = 1;

        $store_args->{store_event}
            = exists $store_args->{store_event}
            ? $store_args->{store_event}
            : $event;

        $store_args->{flv_uri} = delete $store_args->{out};

        $kernel->post( $self->{session_id} => store => $store_args );
    }
    $kernel->refcount_decrement( $session => __PACKAGE__ );
    
    undef;
}

sub _tube_wheel {
    if ( $^O eq 'MSWin32' ) {
        binmode STDIN;
        binmode STDOUT;
    }
    
    my $raw;
    my $size = 4096;
    my $filter = POE::Filter::Reference->new;
    
    my $tube = WWW::YouTube::VideoURI->new;
    
    while ( sysread STDIN, $raw, $size ) {
        my $requests = $filter->get( [ $raw ] );
        foreach my $req ( @$requests ) {
            eval {
                $req->{out} = $tube->get_video_uri( $req->{uri} );
            };
            if ( $@ ) {
                @{ $req }{ qw( error out ) } = ( $@, undef );
            }
            
            $req->{title} = _get_video_title( $req->{uri} )
                if $req->{get_title};
            
            my $response = $filter->put( [ $req ] );
            print STDOUT @$response;
        }
    }
}

sub _get_video_title {
    my $uri = shift;
    my $ua = LWP::UserAgent->new(timeout => 30);
    my $response = $ua->get( $uri );
    if ( $response->is_success ) {
        return _parse_title( $response->content );
    }
    
    return 'ERROR';
}

sub _parse_title {
    my $content = shift;
    
    # bad bad, HTML with regexes, oh my >_<
    my ( $title )
     = $content =~ m#<title>YouTube \s+ - \s+ (.+?) </title>#six;
    
    $title =~ s/\s+/ /;
    require HTML::Entities;
    HTML::Entities::decode_entities( $title );

    return 'N/A'
        unless defined $title;

    return $title;
}

sub _store_wheel {
    if ( $^O eq 'MSWin32' ) {
        binmode STDIN;
        binmode STDOUT;
    }
    
    my $raw;
    my $size = 4096;
    my $filter = POE::Filter::Reference->new;

    while ( sysread STDIN, $raw, $size ) {
        my $requests = $filter->get( [ $raw ] );
        foreach my $req ( @$requests ) {
        
            my $ua = LWP::UserAgent->new(
                %{
                    $req->{lwp_options}
                    || {
                        agent => 'Mozilla/4.0 '
                                . '(compatible; MSIE 6.0; Windows 98)',
                        timeout => 120,
                    }
                }
            );

            $req->{response}
                    = $ua->mirror( $req->{flv_uri}, $req->{where} );

            unless ( $req->{response}->is_success ) {
                $req->{store_error} = $req->{response}->status_line;
            }

            my $response = $filter->put( [ $req ] );
            print STDOUT @$response;
        }
    }
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

POE::Component::WWW::YouTube::VideoURI - Non-blocking L<POE> wrapper around
WWW::YouTube::VideoURI with download abilities.

=head1 SYNOPSIS

    use strict;
    use warnings;

    use POE qw(Component::WWW::YouTube::VideoURI);
    
    POE::Component::WWW::YouTube::VideoURI->spawn( alias => 'tube' );
    
    my $poco
        = POE::Component::WWW::YouTube::VideoURI->spawn;
    
    POE::Session->create(
        package_states => [
            main => [ qw( _start  got_link  downloaded ) ]
        ],
    );

    POE::Session->create(
        inline_states => {
            _start => sub { $_[KERNEL]->alias_set->('secondary'); },
            tube_link => \&got_link,
        }
    );
    
    $poe_kernel->run;
    
    sub _start {
        $poe_kernel->post( tube => get_uri => {
                uri => 'http://www.youtube.com/watch?v=dcmRImiffVM',
                event => 'got_link',
                _shtuf => 'foos',
            }
        );
        
        $poco->get_uri( {
                uri     => 'http://www.youtube.com/watch?v=dcmRImiffVM',
                event   => 'tube_link',
                session => 'secondary',
                _rand   => 'something',
            }
        );
    }
    
    sub got_link {
        my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];
        
        unless ( defined $input->{out} ) {
            print "ZOMG!! Error: $input->{error}\n";
        }
        else {
            print "Got FLV URI: $input->{out}\n";
            print "Title is: $input->{title}\n";
            print "Starting download!\n";
            
            $kernel->post( tube => store => { 
                    flv_uri => $input->{out},
                    where   => '/home/zoffix/Desktop/Apex_Twin-Live.flv',
                    store_event   => 'downloaded',
                }
            );
        }
        
        print "Oh, and BTW: $input->{_shtuf}\n";
    }
    
    sub downloaded {
        my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];
        
        if ( $input->{store_error} ) {
            print "Flailed :( $input->{store_error}\n";
        }
        else {
            print "Success!! We saved $input->{flv_uri} to $input->{where}\n";
        }
        
        $poe_kernel->post( tube => 'shutdown' );
    }

=head1 DESCRIPTION

The module is a simple non-blocking wrapper around 
L<WWW::YouTube::VideoURI> with an additional feature of non-blocking
downloads of C<.flv> files.

=head1 CONSTRUCTOR

    POE::Component::WWW::YouTube::VideoURI->spawn( alias => 'tube' );
    
    POE::Component::WWW::YouTube::VideoURI->spawn(
        alias => 'tube',
        debug => 1,
    );
    
    my $poco
        = POE::Component::WWW::YouTube::VideoURI->spawn;

Returns a PoCo object. Takes three I<optional> arguments:

=head2 alias

    POE::Component::WWW::YouTube::VideoURI->spawn( alias => 'tube' );

Specifies a POE Kernel alias for the component.

=head2 options

    POE::Component::WWW::YouTube::VideoURI->spawn(
        options => {
            trace => 1,
            default => 1,
        },
    );

A hashref of POE Session options to pass to the component's session.

=head2 debug

    POE::Component::WWW::YouTube::VideoURI->spawn( debug => 1 );

When set to a true value turns on output of debug messages.

=head1 METHODS

These are the object-oriented methods of the component.

=head2 get_uri

    $poco->get_uri( {
            event         => 'got_link',
            uri           => 'http://www.youtube.com/watch?v=dcmRImiffVM',
            session       => 'foos',
            where         => '/tmp/foo.flv',
            store_session => 'bars',
            store_event   => 'stored',
            lwp_options   => {
                agent   => 'Tuber',
                timeout => 20,
            },
            _user_var     => 'something',
        }
    );

Method posts a request to get a URI to C<.flv> file. See C<get_uri> event
for detailed description.

=head2 store

    $poco->store( {
            store_event => 'bars',
            where       => '/tmp/bars.flv',
            flv_uri     => 'http://www.youtube.com/get_video.php?video_id='
                          .'dcmRImiffVM&t=OEgsToPDskKZP4XrMtwMd3xwQol1LUWX',
            store_session => 'other_session',
            lwp_options => {
                agent   => 'Tuber',
                timeout => 20,
            },
            _user_var   => 'something',
        }
    );

Method posts a request to download a certain movie. See C<store> event
for detailed description.

=head2 session_id

    my $tube_id = $poco->session_id;

Takes no arguments. Returns POE Session ID of the component.

=head2 shutdown

    $poco->shutdown;

Takes no arguments. Shuts the component down.

=head1 ACCEPTED EVENTS

=head2 get_uri

    $poe_kernel->post( tube => get_uri => {
            event         => 'got_link',
            uri           => 'http://www.youtube.com/watch?v=dcmRImiffVM',
            session       => 'foos',
            where         => '/tmp/foo.flv',
            get_title     => 0,
            store_session => 'bars',
            store_event   => 'stored',
            lwp_options   => {
                agent   => 'Tuber',
                timeout => 20,
            },
            _user_var     => 'something',
        }
    );

Tells the component to resolve YouTube.com link to a link to the actual
C<.flv> movie with an option to also download it.
Takes one argument which is a hashref. The C<event> and C<uri>
keys of that hashref are B<mandatory> the rest of them are optional.
The keys are as follows:

=head3 event

    { event => 'got_link' }

B<Mandatory>. Specifies the event name to which the result should be sent to.

=head3 uri

    { uri => 'http://www.youtube.com/watch?v=dcmRImiffVM' }

B<Mandatory>. Specifies a YouTube.com link from which to get the link
to the C<.flv> file. (this is the link you'd see in the location bar of
your browser when you are watching a movie).

=head3 session

    { session => 'other_session_alias' }

    { session => $other_session_ID }
    
    { session => $other_session_ref }

B<Optional>. Specifies an alternative POE Session to send the output to.
Accepts either session alias, session ID or session reference. Defaults
to the current session.

=head3 get_title

    { get_title => 0 }

B<Optional>. Component is able to retrieve the title of the video.
This functionality is enabled by default, however it requires an extra
HTTP request to be issued which might slow things down. Thus is title
of the video is not important to you, you may wish to set C<get_title>
option to a false value. Defaults to C<1>.

=head3 user defined arguments

    {
        _user_var    => 'foos',
        _another_one => 'bars',
        _some_other  => 'beers',
    }

B<Optional>. Any keys beginning with the C<_> (underscore) will be present
in the output intact. If C<where> option (see below) is specified, any
arguments will also be present in the result of "finished downloading"
event.

=head3 where

    { where => '/tmp/movie.flv' }

B<Optional>. I<If this key is present it will instruct the component to
download the movie after getting a link for it>. Specifies the filename
where to download the movie.
B<Note:> the component B<mirrors> the movie. If the file specified by
the filename doesn't exist it will be created. If it exists and has an
older modification date than the movie to be downloaded it B<will be
overwritten>. If it exists and is B<NOT> older than the movie then the
movie will B<NOT> be downloaded and you will get C<304 Not Modified> error
message in the return's C<store_error> key.

=head3 store_session

    { store_session => 'other_session' }

B<Optional>. Same as C<session> option except it specifies an alternative
session for the C<store> event. In other words by specifying this parameter
you may recieve the "resolved URI" event in one session and the "finished
downloading" in another. B<Note:> if you specified the C<session> parameter
by did not specify the C<store_session> parameter the "finished downloading"
event will be sent to the session specified with the C<session> parameter.
If you wish to recieve the "resolved URI" event in "some other session" but
the "finished downloading" event in the current session you should explicitly specify that.
If C<where> option is not specified, specifying C<store_session> has no effect, B<however> it (C<store_session>) key will be present in the result!

=head3 store_event

    { store_event => 'finished_downloading' }

B<Optional>. Specifies an event that will recieve the results when the download is finished. If not specified it will default to whatever the
C<event> parameter is set to. If C<where> option is not specified, specifying C<store_session> has no effect, B<however>, it (C<store_session>) key will be present in the result!

=head3 lwp_options

    {
        lwp_options   => {
            agent   => 'Tuber',
            timeout => 20,
        }
    }

B<Optional>. Takes a hashref of arguments to pass to L<LWP::UserAgent>
constructor
for downloading of your movie. See L<LWP::UserAgent>'s C<new()> method
for the description of options. If not specified defaults to:

    {
        agent => 'Mozilla/4.0 (compatible; MSIE 6.0; Windows 98)',
        timeout => 120,
    }

B<Note:> if C<where> parameter is not specified, specifying C<lwp_options>
will have no effect, B<however>, it (C<lwp_options>) will be present in the result.

=head2 store

    $poe_kernel->post( tube => store => {
            flv_uri       => 'http://www.youtube.com/' . 
                                'get_video.php?video_id=blah',
            where         => '/tmp/foo.flv',
            store_event   => 'stored',
            store_session => 'bars',
            lwp_options   => {
                agent   => 'Tuber',
                timeout => 20,
            },
            _user_var     => 'something',
        }
    );

Instructs the component to download a certain movie. Takes one argument
in the form of a hashref. Note that it does NOT do any check on the URI
specified via C<flv_uri> option, thus you can possibly download any file.
The hashref keys specify different parameters (listed below) out of which
the C<flv_uri>, C<where>, and C<store_event> are B<mandatory>. Note: you
can automatically download the movies via C<get_uri> event/method. The keys
are as follows:

=head3 flv_uri

    { flv_uri => 'http://www.youtube.com/get_video.php?video_id=blah' }

B<Mandatory>. Specifies the link to C<.flv> movie. No checking on the form of the URI is done, so you can possibly download any file.

=head3 where

    { where => '/tmp/movie.flv' }

B<Mandatory>. Specifies the filename to which download the movie.
B<Note:> the component B<mirrors> the movie. If the file specified by
the filename doesn't exist it will be created. If it exists and has an
older modification date than the movie to be downloaded it B<will be
overwritten>. If it exists and is B<NOT> older than the movie then the
movie will B<NOT> be downloaded and you will get C<304 Not Modified> error
message in the return's C<store_error> key.

=head3 store_event

    { store_event => 'download_is_done' }

B<Mandatory>. Specifies an event to send the message about finished
download.

=head3 store_session

    { store_session => 'some_other_session' }

B<Optional>. Specifies an alternative POE Session to which the output
will be sent.

=head3 lwp_options

    {
        lwp_options   => {
            agent   => 'Tuber',
            timeout => 20,
        }
    }

B<Optional>. Takes a hashref of arguments to pass to L<LWP::UserAgent>'s
constructor for downloading of your movie. See L<LWP::UserAgent>'s
C<new()> method for the description of options. If not specified defaults
to:

    {
        agent => 'Mozilla/4.0 (compatible; MSIE 6.0; Windows 98)',
        timeout => 120,
    }

=head2 shutdown

    $poe_kernel->post( tube => 'shutdown' );

Takes no arguments. Tells the component to shut itself down.

=head1 OUTPUT

The output from the component is recieved via events for both the OO and
event based interface.

=head2 output from get_uri

    $VAR1 = {
          'out' => 'http://www.youtube.com/get_video.php?video_id=blah',
          'uri' => 'http://www.youtube.com/watch?v=dcmRImiffVM',
          'get_title' => 1,
          'title' => 'Some title',
          '_shtuf' => 'foos'
        };

    $VAR1 = {
          'out' => undef,
          'error' => '404 Not Found at lib/POE/Component/WWW/YouTube/VideoURI.pm line 345',
          'uri' => 'http://www.youtube.com/watch?v=blahblah',
          'get_title' => 0,
          '_shtuf' => 'foos'
    };

The event specified in the C<event> parameter of the C<get_uri> method/event
(and optionally the session specified in the C<session> parameter) will
receive the results in C<ARG0> in the form of a hashref.

B<Note:> if the C<where> parameter is specified to the C<get_uri>
method/event it will also be present in the return. You can use it to
make decisions on whether or not to send C<store> event for the flv uri
in the result. B<However>, if an error occured the C<store> event will
B<NOT> be autosent.

The keys of the
result are as follows:

=head3 out

    { 'out' => 'http://www.youtube.com/get_video.php?video_id=blah', }

This key will contain a direct link to the C<.flv> movie (note that URI
doesn't actually end in C<.flv>). It will be C<undef> in case of an error
and C<error> key (see below) will be present.

=head3 uri

    { 'uri' => 'http://www.youtube.com/watch?v=dcmRImiffVM' }

This will be identical to whatever you've set in the C<uri> key in the
C<get_uri> method/event. Using this key you can find out what belongs
where when you are sending multiple requests.

=head3 title

    { 'title' => 'Some title' }

This will contain the title of the video unless C<get_title> option
to the C<get_uri> event/method was set to a false value.

=head3 user defined variables

    { '_shtuf' => 'foos' }

Any keys beginning with the C<_> (underscore) set in the C<get_uri>
method/event will be present intact in the result.

=head3 error

    { 'error' => '404 Not Found at ../../VideoURI.pm line 345' }

In case of an error the C<out> key will be set to C<undef> and C<error>
key will contain the reason... with garbage from croak() appended
(don't blame me for that, see L<WWW::YouTube::VideoLink>)

=head3 where

    { where => '/tmp/movie.flv' }

(Optional). If C<where> parameter was specified to the C<get_uri>
method/event this key will be present intact.

=head2 output from store

    $VAR1 = {
            'flv_uri' => 'http://www.youtube.com/get_video.php?video_id=blah',
            'is_store' => 1,
            'response' => bless( blah blah, 'HTTP::Response' ),
            'store_error' => '304 Not Modified',
            'where' => '/home/zoffix/Desktop/apex.flv',
            '_shtuf' => 'foos'
            };

The event specified in the C<store_event> parameter of the
C<store> method/event
(and optionally the session specified in the
C<store_session> parameter) will
receive the results in C<ARG0> in the form of a hashref.

The keys of the result hashref are as follows:

=head3 flv_uri

    { 'flv_uri' => 'http://www.youtube.com/get_video.php?video_id=blah' }

This will contain the link to the C<.flv> file that we mirrored.

=head3 response

    { 'response' => bless( blah blah, 'HTTP::Response' ) }

This will contain the L<HTTP::Response> object from our mirroring in case
you'd want to inspect it.

=head3 where

    { 'where' => '/home/zoffix/Desktop/apex.flv' }

This key will contain the location of the mirrored movie, it will be
the C<where> parameter you've specified to either C<store> or C<get_uri>
methods/events.

=head3 store_error

    { 'store_error' => '304 Not Modified' }

In case of an error this key will be present and will contain the
explanation of why we failed. (Note: read the C<store> event's
description if you don't understand why we'd get the 304 error).

=head3 is_store

    { is_store => 1 }

This key will be present if the event came from the C<store> event/method
(I<including> the autostore from C<get_uri> event/method). This is
generally a key you'd check on if you decide to send both "resolved uri"
 and "completed download" events to the same event handler

=head3 user defined arguments

    { '_shtuf' => 'foos' }

Any keys beginning with C<_> (underscore) specified to the C<store>
(or C<get_uri> if you also specified C<where> to that method/event) will
be present in the result intact.

=head3 A note on get_uri optional store call

If C<where> argument to the C<get_uri> method/event was specified you will recieve the
output from the C<store> as a second event followed by the "output from
C<get_uri>" event, also, read the description of the C<get_uri> event
to know where to expect the event to arrive.

The keys will also contain the user specified arguments (the ones
beginning with C<_> (underscore) as well as C<uri> key (the original
movie URI).

The C<store> results will also contain C<title> if you are storing by
a single C<get_uri> method/event call.

=head1 PREREQUISITES

This module requires L<POE>, L<POE:Wheel::Run>, L<POE::Filter::Reference>,
L<POE::Filter::Line>, L<WWW::YouTube::VideoURI>, L<HTML::Entities> 
and L<LWP::UserAgent>

=head1 SEE ALSO

L<POE>, L<WWW::YouTube::VideoURI>

=head1 AUTHOR

Zoffix Znet, C<< <zoffix at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-poe-component-www-youtube-videouri at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-WWW-YouTube-VideoURI>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::WWW::YouTube::VideoURI

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-WWW-YouTube-VideoURI>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Component-WWW-YouTube-VideoURI>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Component-WWW-YouTube-VideoURI>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Component-WWW-YouTube-VideoURI>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2008 Zoffix Znet, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
