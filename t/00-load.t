#!/usr/bin/env/perl

use Test::More tests => 18;


diag( "Testing POE::Component::WWW::YouTube::VideoURI $POE::Component::WWW::YouTube::VideoURI::VERSION, Perl $], $^X" );


my $tube_link = 'http://www.youtube.com/watch?v=dcmRImiffVM';
my $requests_done = 0;

use lib '../lib';

BEGIN {
    use_ok('LWP::UserAgent');
    use_ok('WWW::YouTube::VideoURI');
    use_ok('POE');
    use_ok('POE::Wheel::Run');
    use_ok('POE::Filter::Reference');
    use_ok('POE::Filter::Line');
    use_ok('Carp');
    use_ok('HTML::Entities');
    use_ok('POE::Component::WWW::YouTube::VideoURI');
};

use POE qw(Component::WWW::YouTube::VideoURI);

my $poco = POE::Component::WWW::YouTube::VideoURI->spawn( alias => 'tube');

isa_ok( $poco, "POE::Component::WWW::YouTube::VideoURI");
can_ok( $poco, qw(shutdown get_uri store session_id) );

POE::Session->create(
    package_states => [
        main => [ qw( _start  got_link ) ]
    ],
);

POE::Session->create(
    inline_states => {
        _start => sub {
            $poe_kernel->alias_set('secondary_session')
        },
        inter_session_link => \&inter_session_link,
    }
);

$poe_kernel->run;

sub _start {
    print  <<'NOTE_END';

####
####  Note that we won't be testing the 'store' event
####  Also, note that the video to which the test link
####  refers to might have been deleted in which case
####  the 'get_uri' event should be reporting the fetching
####  errors, such as 404
####

NOTE_END
    $poe_kernel->post( tube => get_uri => {
            uri => $tube_link,
            event => 'got_link',
            _shtuf => 'foos',
        }
    );
    
    $poco->get_uri( {
            uri => $tube_link,
            event => 'inter_session_link',
            session => 'secondary_session',
            _shtuf => 'bars',
        }
    );
}

sub got_link {
    my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];
    
    if ( $input->{error} ) {
        is(
            $input->{out},
            undef,
            "Got error, {out} should be undef (error was: $input->{error})"
        );
    }
    else {
        like(
            $input->{out},
            qr#^\Qhttp://www.youtube.com/get_video.php?video_id=#,
            "checking that FLV URI matches what expected."
        );
    }
    
    ok(
        length $input->{title},
        "We have movie title ($input->{title})",
    );
    
    is( $input->{_shtuf}, 'foos', "user defined arguments" );
    
    $poco->shutdown if ++$requests_done > 1;
}

sub inter_session_link {
    my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];

    is( ref $input, 'HASH', "result should be a hashref");
    
    if ( $input->{error} ) {
        is(
            $input->{out},
            undef,
            "Got error, {out} should be undef (error was: $input->{error})"
        );
    }
    else {
        like(
            $input->{out},
            qr#^\Qhttp://www.youtube.com/get_video.php?video_id=#,
            "checking that FLV URI matches what expected."
        );
    }
    
    ok(
        length $input->{title},
        "We have movie title ($input->{title})",
    );
    
    is( $input->{_shtuf}, 'bars', "user defined arguments" );
    
    $poco->shutdown if ++$requests_done > 1;
}


