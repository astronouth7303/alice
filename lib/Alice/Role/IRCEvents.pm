package Alice::Role::IRCEvents;

use AnyEvent;
use Any::Moose 'Role';
use IRC::Formatting::HTML qw/irc_to_html/;
use AnyEvent::IRC::Util qw/split_prefix/;
use List::Util qw/min/;
use Try::Tiny;
use Class::Throwable qw/InvalidNetwork DisconnectError ConnectError/;

our %EVENTS;

sub build_events {
  my ($self, $irc) = @_;

  return +{
    map {
      my $event = $_;
      $event => sub {
        my ($cl, @args) = @_;

        if (!$irc->cl or $cl != $irc->cl) {
          AE::log warn => "$event event on rogue AE::IRC::Client!";
          $cl->remove_all_callbacks;
          $cl->disconnect();
          return;
        }

        AE::log trace => "$event event for " . $irc->name;

        try {
          $EVENTS{$event}->($self, $irc, @args);
        }
        catch {
          AE::log debug => "Error in $event: $_";
          $self->send_info("Please report this bug! $_");
        }
      }
    } keys %EVENTS
  }
}

sub irc_event {
  my ($name, $code) = @_;

  if ($code) {
    if (ref $name eq 'ARRAY') {
      irc_event($_, $code) for @$name;
      return;
    }

    $name = "irc_$name" if $name =~ /^\d+$/;
  }

  $EVENTS{$name} = $code;
}

irc_event connect => sub {
  my ($self, $irc, $err) = @_;
  $irc->is_connecting(0);

  if ($irc->cl->{socket}) {
    $irc->cl->{socket}->rbuf_max(1024 * 10); # 10K max read buffer
  }

  if (defined $err) {
    $self->send_info($irc->name, "connect error: $err");
    $self->reconnect_irc($irc->name);
    return;
  }

  $self->send_info($irc->name, "connected");
  $irc->connect_time(time);

  $self->broadcast({
    type => "action",
    event => "connect",
    network => $irc->name,
  });

};

irc_event registered => sub {
  my ($self, $irc) = @_;
  my $config = $self->config->servers->{$irc->name};

  $irc->reset_reconnect_count;
  $irc->cl->{connected} = 1; # AE::IRC seems broken here...

  my @commands = ();

  push @commands, map {
    my $command = $_;
    sub {
      $self->send_info($irc->name, "sending $command");
      $irc->send_raw($command);
    }
  } @{$config->{on_connect}};

  push @commands, map {
    my $channel = $_;
    sub {
      $self->send_info($irc->name, "joining $channel");
      $irc->send_srv("JOIN", split /\s+/, $channel);
    }
  } @{$config->{channels}};
    
  my $t; $t = AE::timer 1, 0.5, sub {
    if (my $command = shift @commands) {
      $command->();
    }
    else {
      undef $t;
    }
  };

  my $name = $irc->name;
  $irc->cl->enable_ping(300 => sub { $self->reconnect_irc($name) });
};

irc_event disconnect => sub {
  my ($self, $irc, $reason) = @_;

  $self->broadcast({
    type => "action",
    event => "disconnect",
    network => $irc->name,
  });

  $reason = "" unless $reason;
  return if $reason eq "reconnect requested.";
  $self->send_info($irc->name, "disconnected: $reason");
  
  if ($irc->cl) {
    # TODO - Object::Event bug that prevents object from getting destroyed
    delete $irc->cl->{change_nick_cb_guard};
    $irc->cl->remove_all_callbacks;
    $irc->cl(undef);
  }

  $self->reconnect_irc($irc->name, 0) unless $irc->disabled;

  if ($irc->removed) {
    $self->remove_irc($irc->name);
  }
};

irc_event publicmsg => sub {
  my ($self, $irc, $channel, $msg) = @_;

  if (my $window = $self->find_window($channel, $irc)) {
    my ($nick) = split_prefix($msg->{prefix});
    my $text = $msg->{params}[1];

    return if $self->is_ignore(msg => $nick);

    $self->send_message($window, $nick, $text); 
  }
};

irc_event privatemsg => sub {
  my ($self, $irc, $nick, $msg) = @_;

  my $text = $msg->{params}[1];
  my ($from) = split_prefix($msg->{prefix});

  if ($msg->{command} eq "PRIVMSG") {
    return if $self->is_ignore(msg => $from);

    my $window = $self->find_or_create_window($from, $irc);
    $self->send_message($window, $from, $text); 
    $irc->send_srv(WHO => $from) unless $irc->nick_avatar($from);
  }
  elsif ($msg->{command} eq "NOTICE") {
    $self->send_info($from, $text);
  }
};

irc_event ctcp_action => sub {
  my ($self, $irc, $nick, $channel, $msg, $type) = @_;
  return unless $msg;
  return if $self->is_ignore(msg => $nick);

  my $dest = ($channel eq $irc->nick ? $nick : $channel);

  if (my $window = $self->find_or_create_window($dest, $irc)) {
    my $text = "\x{2022} $msg";
    $self->send_message($window, $nick, $text);
  }
};

irc_event nick_change => sub {
  my ($self, $irc, $old_nick, $new_nick, $is_self) = @_;

  my @channels = $irc->nick_channels($new_nick);

  $self->broadcast(
    grep {$_}
    map  {
      if (my $window = $self->find_window($_, $irc)) {
        $window->nicks_action($irc->channel_nicks($window->title)),
        $self->is_ignore(nick => $_) ? ()
          : $window->format_event("nick", $old_nick, $new_nick)
      }
    } @channels
  );

  if ($irc->avatars->{$old_nick}) {
    $irc->avatars->{$new_nick} = delete $irc->avatars->{$old_nick};
  }
};

irc_event 301 => sub {
  my ($self, $irc, $msg) = @_;

  my (undef, $from, $awaymsg) = @{$msg->{params}};

  if (my $window = $self->find_window($from, $irc)) {
    $awaymsg = "$from is away ($awaymsg)";
    $self->announce($awaymsg);
  }
};

irc_event 319 => sub {
  my ($self, $irc, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $irc->nick;

  my ($nick, $channels) = @{$msg->{params}};

  if (my $whois = $irc->whois->{lc $nick}) {
    $whois->{info} .= "\nchannels: " .
    join " ", map {
      my $modes = $irc->cl->nick_modes($nick, $_);
      $irc->prefix_from_modes($nick, $modes) . $_;
    } split /\s+/, $channels;
  }
};

irc_event 352 => sub {
  my ($self, $irc, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $irc->nick;
  
  my (undef, undef, undef, undef, $nick, undef, @real) = @{$msg->{params}};
  my $real = join "", @real;
  $real =~ s/^[0-9*] //;
  if (my $avatar = $irc->realname_avatar($real)) {
    $irc->avatars->{$nick} = $avatar;
  }
};

irc_event 311 => sub {
  my ($self, $irc, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $irc->nick;

  # hector adds an extra nick param or something
  shift @{$msg->{params}} if scalar @{$msg->{params}} > 5;

  my ($nick, $user, $address, undef, $real) = @{$msg->{params}};

  if (my $avatar = $irc->realname_avatar($real)) {
    $irc->avatars->{$nick} = $avatar;
  }

  if (my $whois = $irc->whois->{lc $nick}) {
    $whois->{info} .= "nick: $nick"
                    .  "\nuser: $user"
                    .  "\nreal: $real"
                    .  "\nIP: $address";
  }
};

irc_event 312 => sub {
  my ($self, $irc, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $irc->nick;

  my ($nick, $server) = @{$msg->{params}};

  if (my $whois = $irc->whois->{lc $nick}) {
    $whois->{info} .= "\nserver: $server";
  }
};

irc_event 318 => sub {
  my ($self, $irc, $msg) = @_;

  # ignore the first param if it is our own nick, some servers include it
  shift @{$msg->{params}} if $msg->{params}[0] eq $irc->nick;

  my $nick = $msg->{params}[0];

  if (my $whois = $irc->whois->{lc $nick}) {
    $whois->{cb}->($whois->{info});
    delete $irc->whois->{lc $nick};
  }
};

irc_event 366 => sub {
  my ($self, $irc, $msg) = @_;
  my $channel = $msg->{params}[1];
  if (my $window = $self->find_window($channel, $irc)) {
    $self->broadcast(
      $window->nicks_action($irc->channel_nicks($channel))
    );
  }
};

irc_event 401 => sub {
  my ($self, $irc, $msg) = @_;

  my $nick = $msg->{params}[1];

  if (my $window = $self->find_window($nick, $irc)) {
    $self->announce("No such nick.");
  }
  
  if ($irc->whois->{$nick}) {
    $self->whois->{$nick}{cb}->();
    delete $self->whois->{$nick};
  }
};

irc_event join => sub {
  my ($self, $irc, $nick, $channel, $is_self) = @_;

  if ($is_self) {
    my $window = $self->find_or_create_window($channel, $irc);
    $self->broadcast(
      $window->format_event("join", "you"),
      $window->join_action,
      $window->nicks_action($irc->channel_nicks($channel)),
    );
    $irc->send_srv("WHO" => $channel) if $irc->cl->isupport("UHNAMES");
  }
  else {
    my $window = $self->find_window($channel, $irc);
    $self->queue_event({
      irc    => $irc,
      window => $window,
      event  => "join",
      nick   => $nick,
    });
  }
};

irc_event part => sub {
  my ($self, $irc, $nick, $channel, $is_self, $msg) = @_;

  if ($is_self and my $window = $self->find_window($channel, $irc)) {
    $self->send_info($irc->name, "leaving $channel");
    $self->close_window($window);
  }
};

irc_event channel_remove => sub {
  my ($self, $irc, $msg, $channel, $nick) = @_;

  my $event = lc $msg->{command};
  my $reason = $event eq "quit" ? $msg->{params}[-1] : "";
  my $window = $self->find_window($channel, $irc);

  $self->queue_event({
    irc    => $irc,
    window => $window,
    event  => $event,
    nick   => $nick,
    args   => $reason,
  });
};

irc_event channel_topic => sub {
  my ($self, $irc, $channel, $topic, $nick) = @_;
  if (my $window = $self->find_window($channel, $irc)) {
    $topic = irc_to_html($topic, classes => 1, invert => "italic");
    $window->topic({string => $topic, author => $nick});
    $self->broadcast($window->format_event("topic", $nick, $topic));
  }
};

irc_event irc_invite => sub {
  my ($self, $irc, $msg) = @_;

  my (undef, $channel) = @{$msg->{params}};
  my ($from) = split_prefix($msg->{prefix});

  my $message = "$from has invited you to $channel on ".$irc->name;
  $self->announce($message);
};

irc_event [qw/001 305 306 401 462 464 465 471 473 474 475 477 485 432 433/] => sub {
  my ($self, $irc, $msg) = @_;
  $self->send_info($irc->name, $msg->{params}[-1]);
};

irc_event 375 => sub {
  my ($self, $irc, $msg) = @_;
  $irc->{motd_buffer} = [];
};

irc_event [qw/372 377 378/] => sub {
  my ($self, $irc, $msg) = @_;
  push @{$irc->{motd_buffer}}, $msg->{params}[-1];
  if (@{$irc->{motd_buffer}} > 20) {
    my $lines = delete $irc->{motd_buffer};
    $self->send_info($irc->name, join("\n", @$lines), mono => 1, multiline => 1);
  }
};

irc_event 376 => sub {
  my ($self, $irc, $msg) = @_;
  my $lines = delete $irc->{motd_buffer};
  $self->send_info($irc->name, join("\n", @$lines), mono => 1, multiline => 1);
};

sub reconnect_irc {
  my ($self, $name, $time) = @_;
  my $irc = $self->get_irc($name);
  throw InvalidNetwork "$name isn't one of your networks" unless $irc;

  my $interval = time - $irc->connect_time;

  if ($interval < 15) {
    $time = 15 - $interval;
    $self->send_info($irc->name, "last attempt was within 15 seconds, delaying $time seconds")
  }

  if (!defined $time) {
    # increase timer by 15 seconds each time, until it hits 5 minutes
    $time = min 60 * 5, 15 * $irc->reconnect_count;
  }

  $self->send_info($irc->name, "reconnecting in $time seconds");
  $irc->reconnect_timer(AE::timer $time, 0, sub {$self->connect_irc($name)});
}

sub disconnect_irc {
  my ($self, $name, $msg) = @_;
  my $irc = $self->get_irc($name);
  throw InvalidNetwork "$name isn't one of your networks" unless $irc;

  if ($irc->reconnect_timer) {
    $self->cancel_reconnect($name);
    return;
  }

  throw DisconnectError "$name is already disconnected" if $irc->is_disconnected;

  $self->send_info($irc->name, "disconnecting: $msg") if $msg;
  $irc->is_connecting(0);
  $irc->disabled(1);
  $msg ||= $self->config->quitmsg;
  $irc->send_srv(QUIT => $msg);

  my $cl = $irc->cl;
  my $t; $t = AE::timer 2, 0, sub {
    undef $t;
    if ($cl and $cl->is_connected) {
      $cl->remove_all_callbacks;
      $cl->disconnect;
    }
  };
}

sub cancel_reconnect {
  my ($self, $name) = @_;
  my $irc = $self->get_irc($name);
  throw InvalidNetwork "$name isn't one of your networks" unless $irc;

  $self->send_info($irc->name, "canceled reconnect");
  $self->broadcast({
    type => "action",
    event => "disconnect",
    network => $irc->name,
    windows => [], #shouldn't be any windows if we're not connected.
  });
  $irc->reconnect_timer(undef);
  $irc->reset_reconnect_count;
}

sub connect_irc {
  my ($self, $name) = @_;
  my $irc = $self->get_irc($name);

  throw InvalidNetwork "$name isn't one of your networks" unless $irc;
  throw ConnectError "$name is already connected" if $irc->is_connected;
  throw ConnectError "$name is already connecting" if $irc->is_connecting;

  $irc->reconnect_timer(undef);
  my $config = $self->config->servers->{$irc->name};
 
  # some people don't set these, wtf
  if (!$config->{host} or !$config->{port}) {
    $self->send_info($irc->name, "can't connect: missing either host or port");
    return;
  }

  my $events = $self->build_events($irc);
  $irc->new_client($events, $config);
  $irc->disabled(0);
  $irc->increase_reconnect_count;
   
  $self->send_info($irc->name, "connecting (attempt " . $irc->reconnect_count .")");
  
  $irc->is_connecting(1);
  $irc->cl->connect($config->{host}, $config->{port}, {
    nick => $config->{nick},
    user => $config->{user},
    real => $config->{ircname},
    password => $config->{password},
  });
}

sub queue_event {
  my ($self, $event) = @_;

  my $window = $event->{window};
  my $irc    = $event->{irc};

  push @{$window->{event_queue}}, [$event->{event}, $event->{nick}, $event->{args} || ""];

  $window->{event_timer} ||= AE::timer 1, 0, sub {
    delete $window->{event_timer};
    $self->send_nicks($window);

    my $queue = delete $window->{event_queue};
    my $current = shift @$queue;

    my $idle_w; $idle_w = AE::idle sub {
      if (!$current) {
        undef $idle_w;
        return;
      }

      my $next = shift @$queue;
      return if $self->is_ignore($current->[0] => $window->title);

      if (!$next or $current->[0] ne $next->[0] or $current->[2] ne $next->[2]) {
        $self->broadcast($window->format_event(@$current));
        $current = $next;
      }
      else {
        $current->[1] .= ", $next->[1]";
      }
    };
  };
}

1;
