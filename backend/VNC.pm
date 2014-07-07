package backend::VNC;
use strict;
use warnings;
use base qw(Class::Accessor::Fast);
use Crypt::DES;
use IO::Socket::INET;
use bytes;
use bmwqemu qw(diag);

__PACKAGE__->mk_accessors(
    qw(hostname port username password socket name width height depth save_bandwidth
      server_endian  _pixinfo _colourmap _framebuffer _rfb_version
      _bpp _true_colour _big_endian
      )
);
our $VERSION = '0.40';

my $MAX_PROTOCOL_VERSION = 'RFB 003.008' . chr(0x0a);  # Max version supported

# This line comes from perlport.pod
my $AM_BIG_ENDIAN = unpack( 'h*', pack( 's', 1 ) ) =~ /01/ ? 1 : 0;

# The numbers in the hashes below were acquired from the VNC source code
my %supported_depths = (
    '24' => {
        bpp         => 32,
        true_colour => 1,
        red_max     => 255,
        green_max   => 255,
        blue_max    => 255,
        red_shift   => 16,
        green_shift => 8,
        blue_shift  => 0,
    },
);

my @encodings = (

    # These ones are defined in rfbproto.pdf
    {
        num       => 0,
        name      => 'Raw',
        supported => 1,
    },
    {
        num       => -223,
        name      => 'DesktopSize',
        supported => 1,
    }
);

sub list_encodings {
    my $pkg_or_self = shift;

    my %encmap = map { $_->{num} => $_->{name} } @encodings;
    return %encmap;
}

sub login {
    my $self     = shift;
    my $hostname = $self->hostname;
    my $port     = $self->port;
    my $socket   = IO::Socket::INET->new(
        PeerAddr => $hostname || 'localhost',
        PeerPort => $port     || '5900',
        Proto    => 'tcp',
    ) || die "Error connecting to $hostname: $@";
    $socket->timeout(15);
    $self->socket($socket);

    eval {
        $self->_handshake_protocol_version();
        $self->_handshake_security();
        $self->_client_initialization();
        $self->_server_initialization();
    };
    my $error = $@;    # store so it doesn't get overwritten
    if ($error) {

        # clean up so socket can be garbage collected
        $self->socket(undef);
        die $error;
    }
}

sub _handshake_protocol_version {
    my $self = shift;

    my $socket = $self->socket;
    $socket->read( my $protocol_version, 12 ) || die 'unexpected end of data';

    bmwqemu::diag "prot: $protocol_version";

    my $protocol_pattern = qr/\A RFB [ ] (\d{3}\.\d{3}) \s* \z/xms;
    if ( $protocol_version !~ m/$protocol_pattern/xms ) {
        die 'Malformed RFB protocol: ' . $protocol_version;
    }
    $self->_rfb_version($1);

    if ( $protocol_version gt $MAX_PROTOCOL_VERSION ) {
        $protocol_version = $MAX_PROTOCOL_VERSION;

        # Repeat with the changed version
        if ( $protocol_version !~ m/$protocol_pattern/xms ) {
            die 'Malformed RFB protocol';
        }
        $self->_rfb_version($1);
    }

    if ( $self->_rfb_version lt '003.003' ) {
        die 'RFB protocols earlier than v3.3 are not supported';
    }

    # let's use the same version of the protocol, or the max, whichever's lower
    $socket->print($protocol_version);
}

sub _handshake_security {
    my $self = shift;

    my $socket = $self->socket;

    # Retrieve list of security options
    my $security_type;
    if ( $self->_rfb_version ge '003.007' ) {
        $socket->read( my $number_of_security_types, 1 )
          || die 'unexpected end of data';
        $number_of_security_types = unpack( 'C', $number_of_security_types );

        #bmwqemu::diag "types: $number_of_security_types";

        if ( $number_of_security_types == 0 ) {
            die 'Error authenticating';
        }

        my @security_types;
        foreach ( 1 .. $number_of_security_types ) {
            $socket->read( my $security_type, 1 )
              || die 'unexpected end of data';
            $security_type = unpack( 'C', $security_type );

            #        bmwqemu::diag "sec: $security_type";
            push @security_types, $security_type;
        }

        my @pref_types = ( 1, 2 );
        @pref_types = ( 30, 1, 2 ) if $self->username;

        for my $preferred_type (@pref_types) {
            if ( 0 < grep { $_ == $preferred_type } @security_types ) {
                $security_type = $preferred_type;
                last;
            }
        }
    }
    else {

        # In RFB 3.3, the server dictates the security type
        $socket->read( $security_type, 4 ) || die 'unexpected end of data';
        $security_type = unpack( 'N', $security_type );
    }

    if ( $security_type == 1 ) {

        # No authorization needed!
        if ( $self->_rfb_version ge '003.007' ) {
            $socket->print( pack( 'C', 1 ) );
        }

    } else {
      die 'qemu wants security, but we have no password';
    }

    # the RFB protocol always returns a result for type 2,
    # but type 1, only for 003.008 and up
    if ( ( $self->_rfb_version ge '003.008' && $security_type == 1 )
        || $security_type == 2 )
    {
        $socket->read( my $security_result, 4 )
          || die 'unexpected end of data';
        $security_result = unpack( 'I', $security_result );

        #    bmwqemu::diag $security_result;
        die 'login failed' if $security_result;
    }
    elsif ( !$socket->connected ) {
        die 'login failed';
    }
}

sub _bin_int {
    my ( $self, $s ) = @_;
    my @a = unpack( "C*", $s );
    my $r = 0;
    for ( my $i = 0; $i < @a; $i++ ) {
        $r = 256 * $r;
        $r += $a[$i];
    }
    return $r;
}

sub _client_initialization {
    my $self = shift;

    my $socket = $self->socket;

    $socket->print( pack( 'C', 1 ) );    # share
}

sub _server_initialization {
    my $self = shift;

    my $socket = $self->socket;
    $socket->read( my $server_init, 24 ) || die 'unexpected end of data';

    my ( $framebuffer_width, $framebuffer_height, $bits_per_pixel, $depth,$big_endian_flag, $true_colour_flag, %pixinfo, $name_length );
    # the following line is due to tidy ;(
    ( $framebuffer_width,$framebuffer_height,$bits_per_pixel,$depth,$big_endian_flag,$true_colour_flag,$pixinfo{red_max},$pixinfo{green_max},$pixinfo{blue_max},$pixinfo{red_shift},$pixinfo{green_shift},$pixinfo{blue_shift},$name_length) = unpack 'nnCCCCnnnCCCxxxN', $server_init;

    #bmwqemu::diag "FW $framebuffer_width x $framebuffer_height";

    #bmwqemu::diag "$bits_per_pixel bpp / depth $depth / $big_endian_flag be / $true_colour_flag tc / $pixinfo{red_max},$pixinfo{green_max},$pixinfo{blue_max} / $pixinfo{red_shift},$pixinfo{green_shift},$pixinfo{blue_shift}";

    #bmwqemu::diag $name_length;

    if ( !$self->depth ) {

        # client did not express a depth preference, so check if the server's preference is OK
        if ( !$supported_depths{$depth} ) {
            die 'Unsupported depth ' . $depth;
        }
        if ( $bits_per_pixel != $supported_depths{$depth}->{bpp} ) {
            die 'Unsupported bits-per-pixel value ' . $bits_per_pixel;
        }
        if (
            $true_colour_flag
            ? !$supported_depths{$depth}->{true_colour}
            : $supported_depths{$depth}->{true_colour}
          )
        {
            die 'Unsupported true colour flag';
        }
        $self->depth($depth);

        # Use server's values for *_max and *_shift

    }
    elsif ( $depth != $self->depth ) {
        for my $key (qw(red_max green_max blue_max red_shift green_shift blue_shift)){
            $pixinfo{$key} = $supported_depths{ $self->depth }->{$key};
        }
    }

    if ( !$self->width ) {
        $self->width($framebuffer_width);
    }
    if ( !$self->height ) {
        $self->height($framebuffer_height);
    }
    $self->_pixinfo( \%pixinfo );
    $self->_bpp( $supported_depths{ $self->depth }->{bpp} );
    $self->_true_colour( $supported_depths{ $self->depth }->{true_colour} );
    $self->_big_endian($self->server_endian ? $big_endian_flag : $AM_BIG_ENDIAN );

    $socket->read( my $name_string, $name_length )
      || die 'unexpected end of data';
    $self->name($name_string);

    #    warn $name_string;

    # setpixelformat
    $socket->print(
        pack(
            'CCCCCCCCnnnCCCCCC',
            0,    # message_type
            0,    # padding
            0,    # padding
            0,    # padding
            $self->_bpp,
            $self->depth,
            $self->_big_endian,
            $self->_true_colour,
            $pixinfo{red_max},
            $pixinfo{green_max},
            $pixinfo{blue_max},
            $pixinfo{red_shift},
            $pixinfo{green_shift},
            $pixinfo{blue_shift},
            0,    # padding
            0,    # padding
            0,    # padding
        )
    );

    # set encodings

    my @encs = grep { $_->{supported} } @encodings;

    # Prefer the higher-numbered encodings
    @encs = reverse sort { $a->{num} <=> $b->{num} } @encs;

    if ( !$self->save_bandwidth ) {
        @encs = grep { !$_->{bandwidth} } @encs;
    }
    $socket->print(
        pack(
            'CCn',
            2,               # message_type
            0,               # padding
            scalar @encs,    # number_of_encodings
        )
    );
    for my $enc (@encs) {

        # Make a big-endian, signed 32-bit value
        # method:
        #   pack as own-endian, signed      e.g. -239
        #   unpack as own-endian, unsigned  e.g. 4294967057
        #   pack as big-endian
        my $num = pack 'N', unpack 'L', pack 'l', $enc->{num};
        $socket->print($num);
    }
}

sub capture {
    my $self   = shift;
    my $socket = $self->socket;

    $self->_send_update_request();
    while ( 1 ) {
      my $message_type = $self->_receive_message();
      last unless defined $message_type;
    }

    return $self->_framebuffer;
}

sub _send_key_event {
    my ( $self, $down_flag, $key ) = @_;

    # A key press or release. Down-flag is non-zero (true) if the key is now pressed, zero
    # (false) if it is now released. The key itself is specified using the “keysym” values
    # defined by the X Window System.

    my $socket = $self->socket;
    $socket->print(
        pack(
            'CCnN',
            4,             # message_type
            $down_flag,    # down-flag
            0,             # padding
            $key,          # key
        )
    );
}

sub send_key_event_down {
    my ( $self, $key ) = @_;
    $self->_send_key_event( 1, $key );
}

sub send_key_event_up {
    my ( $self, $key ) = @_;
    $self->_send_key_event( 0, $key );
}

sub send_key_event {
    my ( $self, $key ) = @_;
    $self->send_key_event_down($key);
    $self->send_key_event_up($key);
}

sub send_key_event_string {
    my ( $self, $string ) = @_;
    foreach my $key ( map {ord} split //, $string ) {
        warn $key;
        $self->send_key_event($key);
    }
}

sub send_pointer_event {
    my ( $self, $button_mask, $x, $y ) = @_;

    $self->socket->print(
        pack(
            'CCnn',
            5,               # message type
            $button_mask,    # button-mask
            $x,              # x-position
            $y,              # y-position
        )
    );
}

sub _send_update_request {
    my $self = shift;

    # frame buffer update request
    my $socket = $self->socket;
    my $incremental = $self->_framebuffer ? 1 : 0;
    $socket->print(
        pack(
            'CCnnnn',
            3,               # message_type
            $incremental,    # incremental
            0,               # x
            0,               # y
            $self->width,
            $self->height,
        )
    );
}

sub _receive_message {
    my $self = shift;

    my $socket = $self->socket;

    my $s = IO::Select->new();
    $s->add($socket);

    return undef unless ($s->can_read(0.1));

    $socket->read( my $message_type, 1 ) || die 'unexpected end of data';
    $message_type = unpack( 'C', $message_type );

    #bmwqemu::diag("RM $message_type");

    # This result is unused.  It's meaning is different for the different methods
    my $result=
        !defined $message_type ? die 'bad message type received'
      : $message_type == 0     ? $self->_receive_update()
      : $message_type == 1     ? $self->_receive_colour_map()
      : $message_type == 2     ? $self->_receive_bell()
      : $message_type == 3     ? $self->_receive_cut_text()
      :                          die 'unsupported message type received';

    return $message_type;
}

sub _receive_update {
    my $self = shift;

    my $image = $self->_framebuffer;
    if ( !$image ) {
        $image = tinycv::new( $self->width, $self->height );
        $self->_framebuffer($image);

        # We're going to be splatting pixels, so make sure every pixel is opaque
        #$image->set_colour( 0, 0, 0, 255 );
        #$image->fill_rectangle( 0, 0, $self->width, $self->height );
    }

    my $socket = $self->socket;
    my $hlen = $socket->read( my $header, 3 ) || die 'unexpected end of data';
    my $number_of_rectangles = unpack( 'xn', $header );

    #bmwqemu::diag "NOR $hlen - $number_of_rectangles";

    my $depth = $self->depth;

    my $big_endian = $self->_big_endian;

    foreach ( 1 .. $number_of_rectangles ) {
        $socket->read( my $data, 12 ) || die 'unexpected end of data';
        my ( $x, $y, $w, $h, $encoding_type ) = unpack 'nnnnN', $data;

        # unsigned -> signed conversion
        $encoding_type = unpack 'l', pack 'L', $encoding_type;

        #bmwqemu::diag "$x,$y $w x $h $encoding_type";

        ### Raw encoding ###
        if ( $encoding_type == 0 ) {

	  # Performance boost: splat raw pixels into the image
	  $socket->read( my $data, $w * $h * 4 );

	  my $img = tinycv::new($w, $h);
	  $img->map_raw_data($data);
	  $image->blend($img, $x, $y);
        }
        elsif ( $encoding_type == -223 ) {
	  $self->width($w);
	  $self->height($h);
	  $image = tinycv::new( $self->width, $self->height );
	  $self->_framebuffer($image);
        }
        else {
            die 'unsupported update encoding ' . $encoding_type;
        }
    }

    return $number_of_rectangles;
}

sub _receive_colour_map {
    my $self = shift;

    die 'we do not support color maps';

    return 1;
}

sub _receive_bell {
    my $self = shift;

    # And discard it...

    return 1;
}

sub _receive_cut_text {
    my $self = shift;

    my $socket = $self->socket;
    $socket->read( my $cut_msg, 7 ) || die 'unexpected end of data';
    my $cut_length = unpack 'xxxN', $cut_msg;
    $socket->read( my $cut_string, $cut_length )
      || die 'unexpected end of data';

    # And discard it...

    return 1;
}

sub mouse_move_to {
    my ( $self, $x, $y ) = @_;
    $self->send_pointer_event( 0, $x, $y );
}

sub mouse_click {
    my ($self, $x, $y ) = @_;

    $self->send_pointer_event( 1, $x, $y );
    $self->send_pointer_event( 0, $x, $y );
}

sub mouse_right_click {
    my ($self, $x, $y ) = @_;

    $self->send_pointer_event( 4, $x, $y );
    $self->send_pointer_event( 0, $x, $y );
}

1;

__END__

=head1 NAME

Net::VNC - A simple VNC client

=head1 SYNOPSIS
    
  use Net::VNC;

  my $vnc = Net::VNC->new({hostname => $hostname, password => $password});
  $vnc->depth(24);
  $vnc->login;

  print $vnc->name . ": " . $vnc->width . ' x ' . $vnc->height . "\n";

  my $image = $vnc->capture;
  $image->save("out.png");

=head1 DESCRIPTION

Virtual Network Computing (VNC) is a desktop sharing system which uses
the RFB (Remote FrameBuffer) protocol to remotely control another
computer. This module acts as a VNC client and communicates to a VNC
server using the RFB protocol, allowing you to capture the screen of
the remote computer.

This module dies upon connection errors (with a timeout of 15 seconds)
and protocol errors.

This implementation is based largely on the RFB Protocol
Specification, L<http://www.realvnc.com/docs/rfbproto.pdf>.  That
document has an error in the DES encryption description, which is
clarified via L<http://www.vidarholen.net/contents/junk/vnc.html>.

=head1 METHODS

=head2 new

The constructor. Given a hostname and a password returns a L<Net::VNC> object:

  my $vnc = Net::VNC->new({hostname => $hostname, password => $password});

Optionally, you can also specify a port, which defaults to 5900. For ARD
(Apple Remote Desktop) authentication you must also specify a username.
You must also install Crypt::GCrypt::MPI and Crypt::Random.

=head2 login

Logs into the remote computer:

  $vnc->login;

=head2 name

Returns the name of the remote computer:

  print $vnc->name . ": " . $vnc->width . ' x ' . $vnc->height . "\n";

=head2 width

Returns the width of the remote screen:

  print $vnc->name . ": " . $vnc->width . ' x ' . $vnc->height . "\n";

=head2 height

Returns the height of the remote screen:

  print $vnc->name . ": " . $vnc->width . ' x ' . $vnc->height . "\n";

=head2 capture

Captures the screen of the remote computer, returning an L<Image::Imlib2> object:

  my $image = $vnc->capture;
  $image->save("out.png");

You may call capture() multiple times.  Each time, the C<$image>
buffer is overwritten with the updated screen.  So, to create a
series of ten screen shots:

  for my $n (1..10) {
    my $filename = sprintf 'snapshot%02d.png', $n++;
    $vnc->capture()->save($filename);
    print "Wrote $filename\n";
  }

=head2 depth

Specify the bit depth for the screen.  The supported choices are 24,
16 or 8.  If unspecified, the server's default value is used.  This
property should be set before the call to login().

=head2 save_bandwidth

Accepts a boolean, defaults to false.  Specifies whether to use more
CPU-intensive algorithms to compress the VNC datastream.  LAN or
localhost connections may prefer to leave this false.  This property
should be set before the call to login().

=head2 list_encodings

Returns a list of encoding number/encoding name pairs.  This can be used as a class method like so:

   my %encodings = Net::VNC->list_encodings();

=head2 send_key_event_down

Send a key down event. The keys are the same as the
corresponding ASCII value. Other common keys:

  BackSpace 0xff08
  Tab 0xff09
  Return or Enter 0xff0d
  Escape 0xff1b
  Insert 0xff63
  Delete 0xffff
  Home 0xff50
  End 0xff57
  Page Up 0xff55
  Page Down 0xff56
  Left 0xff51
  Up 0xff52
  Right 0xff53
  Down 0xff54
  F1 0xffbe
  F2 0xffbf
  F3 0xffc0
  F4 0xffc1
  ... ...
  F12 0xffc9
  Shift (left) 0xffe1
  Shift (right) 0xffe2
  Control (left) 0xffe3
  Control (right) 0xffe4
  Meta (left) 0xffe7
  Meta (right) 0xffe8
  Alt (left) 0xffe9
  Alt (right) 0xffea

  $vnc->send_key_event_down('A');

=head2 send_key_event_up

Send a key up event:

  $vnc->send_key_event_up('A');

=head2 send_key_event

Send a key down event followed by a key up event:

  $vnc->send_key_event('A');

=head2 send_key_event_string

Send key events for every character in a string:

  $vnc->send_key_event_string('Hello');

=head2 send_pointer_event( $button_mask, $x, $y )

Send pointer event (usually a mouse). This is used to move the pointer or
make clicks or drags.

It is easier to call the C<mouse_move> or <mouse_click> methods instead.

=head2 mouse_move_to($x, $y)

Send the pointer to the given position. The cursor instantly jumps there
instead of smoothly moving to there.

=head2 mouse_click

Click on current pointer position.

=head2 mouse_right_click

Right-click on current pointer position.

=head1 BUGS AND LIMITATIONS

=head2 Bit depth

We do not yet support 8-bit true-colour mode, which is commonly
supported by servers but is rarely employed by clients.

=head2 Byte order

We have currently tested this package against servers with the same
byte order as the client.  This might break with a little-endian
server/big-endian client or vice versa.  We're working on tests for
those latter cases.  Testing and patching help would be appreciated.

=head2 Efficiency

We've implemented a subset of the data compression algorithms
supported by most VNC servers.  We hope to add more of the
high-compression transfer encodings in the future.

=head1 AUTHORS

Leon Brocard acme@astray.com

Chris Dolan clotho@cpan.org

Apple Remote Desktop authentication based on LibVNCServer

Maurice Castro maurice@ipexchange.com.au

Many thanks for Foxtons Ltd for giving Leon the opportunity to write
the original version of this module.

Copyright (C) 2006, Leon Brocard

This module is free software; you can redistribute it or modify it
under the same terms as Perl itself.
 
