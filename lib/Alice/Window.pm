package Alice::Window;

use strict;
use warnings;

use Text::MicroTemplate qw/encoded_string/;
use IRC::Formatting::HTML qw/irc_to_html/;
use Plack::Util::Accessor qw/title type id network previous_nick disabled topic/;

sub new {
  my ($class, %args) = @_;
  for (qw/title type id network render/) {
    die "$_ is required" unless defined $args{$_};
  }

  $args{topic} = {
    string => "no topic set",
    author => "",
  };

  $args{disbled} = 0;
  $args{previous_nick} = "";

  $args{event_queue} = [];
  $args{event_timer} = ();

  bless \%args, __PACKAGE__;
}

sub sort_name {
  my $name = lc $_[0]->{title};
  $name =~ s/^[^\w\d]+//;
  $name;
}

sub pretty_name {
  my $self = shift;
  if ($self->{type} eq "channel") {
    return substr $self->{title}, 1;
  }
  return $self->{title};
}

sub hashtag {
  my $self = shift;

  my $name = $self->title;
  $name =~ s/[#&~@]//g;
  my $path = $self->type eq "privmsg" ? "users" : "channels";
  
  return "/" . $self->{network} . "/$path/" . $name;
}

sub is_channel {
  $_[0]->{type} eq "channel"
}

sub topic_string {
  my $self = shift;
  if ($self->{type} eq "channel") {
    return ($self->{topic}{string} or "$self->{title}: no topic set");
  }
  return $self->{title};
}

sub serialized {
  my ($self) = @_;

  return {
    is_channel => $self->is_channel,
    hashtag    => $self->hashtag,
    topic      => $self->topic_string,
    map {$_ => $self->{$_}} qw/id network title type/
  };
}

sub format_event {
  my ($self, $msgid, $event, $nick, $body) = @_;
  my $message = {
    msgid     => $msgid,
    type      => "message",
    event     => $event,
    nick      => $nick,
    window    => $self->serialized,
    body      => $body,
    timestamp => time,
  };

  $self->{previous_nick} = "";
  $message->{html} = $self->{render}->("event", $message);
  return $message;
}

sub format_message {
  my ($self, $msgid, $nick, $body, %options) = @_;
  my $html = irc_to_html($body, classes => 1, ($options{monospaced} ? () : (invert => "italic")));
  my $message = {
    msgid     => $msgid,
    type      => "message",
    event     => "say",
    nick      => $nick,
    window    => $self->serialized,
    html      => encoded_string($html),
    timestamp => time,
    consecutive => $nick eq $self->{previous_nick},
    %options,
  };

  $self->{previous_nick} = $nick;
  $message->{html} = $self->{render}->("message", $message);
  return $message;
}

sub join_action {
  my $self = shift;
  return {
    type      => "action",
    event     => "join",
    window    => $self->serialized,
    html => {
      window  => $self->{render}->("window", $self),
      tab     => $self->{render}->("tab", $self),
    },
  };
}

sub nicks_action {
  my ($self, @nicks) = @_;
  return {
    type      => "action",
    event     => "nicks",
    nicks     => \@nicks,
    window_id => $self->id,
  };
}

sub clear_action {
  my $self = shift;
  return {
    type      => "action",
    event     => "clear",
    window_id => $self->id,
  };
}


sub close_action {
  my $self = shift;
  return +{
    type      => "action",
    event     => "part",
    window_id => $self->id,
  };
}

sub trim_action {
  my ($self, $lines) = @_;
  return +{
    type      => "action",
    event     => "trim",
    lines     => $lines,
    window_id => $self->id,
  };
}

1;
