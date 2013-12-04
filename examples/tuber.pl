#!/usr/bin/env perl

use strict;
use warnings;

my $Store_Dir = shift || './';

use lib '../lib';

use POE qw(Component::WWW::YouTube::VideoURI);

require File::Spec;

POE::Component::WWW::YouTube::VideoURI->spawn( alias => 'tube' );

POE::Session->create(
    package_states => [
        main => [ qw( _start  got_link  downloaded ) ]
    ],
);

$poe_kernel->run;

sub _start {
    
    print <<"END_INTRO_TEXT";

############################

YouTube Video Downloader

We are going to use `$Store_Dir` to store our videos in

############################

END_INTRO_TEXT

    print "Enter link to the video (or type 'quit' to quit): ";
    chomp( my $link = <STDIN> );
        
    if ( $link =~ /^ (?: q (?:uit)? | e (?:xit)? )/xi ) {
        print "\nAbout to quit....\n";
        $poe_kernel->post( tube => 'shutdown' );
        last;
    }
    
    print "Sending a request...\n";
    $poe_kernel->post( tube => get_uri => {
            uri => $link,
            event => 'got_link',
        }
    );
}

sub got_link {
    my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];
    
    unless ( defined $input->{out} ) {
        print "URI resolver error: $input->{error}\n";
    }
    else {
        my $where = File::Spec->catfile(
            $Store_Dir,
            $input->{title} . '.flv'
        );
        print "Got FLV URI: $input->{out}\n";
        print "Starting download: $input->{title}\n";
        print "Will save it as: $where\n";
        
        $kernel->post( tube => store => { 
                flv_uri => $input->{out},
                where   => $where,
                store_event   => 'downloaded',
                _title  => $input->{title},
            }
        );
    }
}

sub downloaded {
    my ( $kernel, $input ) = @_[ KERNEL, ARG0 ];
    
    if ( $input->{store_error} ) {
        print "Could not save video $input->{_title}: "
                . "$input->{store_error}\n";
    }
    else {
        print "Saved $input->{flv_uri} to $input->{where}\n";
    }
    
    print "\nAbout to quit....\n";
    $poe_kernel->post( tube => 'shutdown' );
}

=pod

Usage: perl tuber.pl <optional_store_dir>

=cut

