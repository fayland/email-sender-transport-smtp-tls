package Email::Sender::Transport::SMTP::TLS;

# ABSTRACT: Email::Sender with L<Net::SMTP::TLS> (Eg. Gmail)

use Moose 0.90;

use Net::SMTP::TLS::ButMaintained;
use Email::Sender::Failure::Multi;
use Email::Sender::Success::Partial;
use Email::Sender::Util;

has host => (is => 'ro', isa => 'Str', default => 'localhost');
has port => (is => 'ro', isa => 'Int', default => 587 );
has username => (is => 'ro', isa => 'Str', required => 1);
has password => (is => 'ro', isa => 'Str', required => 1);
has allow_partial_success => (is => 'ro', isa => 'Bool', default => 0);
has helo      => (is => 'ro', isa => 'Str'); # default to hostname_long

# From http://search.cpan.org/src/RJBS/Email-Sender-0.000/lib/Email/Sender/Transport/SMTP.pm
## I am basically -sure- that this is wrong, but sending hundreds of millions of
## messages has shown that it is right enough.  I will try to make it textbook
## later. -- rjbs, 2008-12-05
sub _quoteaddr {
    my $addr       = shift;
    my @localparts = split /\@/, $addr;
    my $domain     = pop @localparts;
    my $localpart  = join q{@}, @localparts;

    # this is probably a little too paranoid
    return $addr unless $localpart =~ /[^\w.+-]/ or $localpart =~ /^\./;
    return join q{@}, qq("$localpart"), $domain;
}

sub _smtp_client {
    my ($self) = @_;

    my $smtp;
    eval {
        $smtp = Net::SMTP::TLS::ButMaintained->new(
            $self->host,
            Port => $self->port,
            User => $self->username,
            Password => $self->password,
            $self->helo ? (Hello => $self->helo) : (),
        );
    };

    $self->_throw($@) if $@;
    $self->_throw("unable to establish SMTP connection") unless $smtp;

    return $smtp;
}

sub _throw {
    my ($self, @rest) = @_;
    Email::Sender::Util->_failure(@rest)->throw;
}

sub send_email {
    my ($self, $email, $env) = @_;

    Email::Sender::Failure->throw("no valid addresses in recipient list")
        unless my @to = grep { defined and length } @{ $env->{to} };

    my $smtp = $self->_smtp_client;

    my $FAULT = sub { $self->_throw($_[0], $smtp); };

    eval {
        $smtp->mail(_quoteaddr($env->{from}));
    };
    $FAULT->("$env->{from} failed after MAIL FROM: $@") if $@;

    my @failures;
    my @ok_rcpts;
  
    for my $addr (@to) {
        eval {
            $smtp->to(_quoteaddr($addr));
        };
        unless ( $@ ) {
            push @ok_rcpts, $addr;
        } else {
            # my ($self, $error, $smtp, $error_class, @rest) = @_;
            push @failures, Email::Sender::Util->_failure(
                undef,
                $smtp,
                recipients => [ $addr ],
            );
        }
    }

    if (
        @failures
        and ((@ok_rcpts == 0) or (! $self->allow_partial_success))
    ) {
        $failures[0]->throw if @failures == 1;

        my $message = sprintf '%s recipients were rejected during RCPT',
            @ok_rcpts ? 'some' : 'all';

        Email::Sender::Failure::Multi->throw(
            message  => $message,
            failures => \@failures,
        );
    }

    my $message;
    eval {
        $smtp->data();
        $smtp->datasend( $email->as_string );
        $smtp->dataend;
        $message = $smtp->message;
        $smtp->quit;
    };
    # ignore $@

    # XXX: We must report partial success (failures) if applicable.
    return $self->success({ message => $message }) unless @failures;
    return $self->partial_success({
        message => $message,
        failure => Email::Sender::Failure::Multi->new({
          message  => 'some recipients were rejected during RCPT',
          failures => \@failures
        }),
    });
}

my %SUCCESS_CLASS;
BEGIN {
  $SUCCESS_CLASS{FULL} = Moose::Meta::Class->create_anon_class(
    superclasses => [ 'Email::Sender::Success' ],
    roles        => [ 'Email::Sender::Role::HasMessage' ],
    cache        => 1,
  );
  $SUCCESS_CLASS{PARTIAL} = Moose::Meta::Class->create_anon_class(
    superclasses => [ 'Email::Sender::Success::Partial' ],
    roles        => [ 'Email::Sender::Role::HasMessage' ],
    cache        => 1,
  );
}

sub success {
  my $self = shift;
  my $success = $SUCCESS_CLASS{FULL}->name->new(@_);
}

sub partial_success {
  my ($self, @args) = @_;
  my $obj = $SUCCESS_CLASS{PARTIAL}->name->new(@args);
  return $obj;
}

with 'Email::Sender::Transport';
__PACKAGE__->meta->make_immutable;
no Moose;
1;

__END__

=head1 SYNOPSIS

    use Email::Sender::Simple qw(sendmail);
    use Email::Sender::Transport::SMTP::TLS;
    use Try::Tiny;

    my $transport = Email::Sender::Transport::SMTP::TLS->new(
        host => 'smtp.gmail.com',
        port => 587,
        username => 'username@gmail.com',
        password => 'password',
        helo => 'fayland.org',
    );
    
    # my $message = Mail::Message->read($rfc822)
    #         || Email::Simple->new($rfc822)
    #         || Mail::Internet->new([split /\n/, $rfc822])
    #         || ...
    #         || $rfc822;
    # read L<Email::Abstract> for more details

    use Email::Simple::Creator; # or other Email::
    my $message = Email::Simple->create(
        header => [
            From    => 'username@gmail.com',
            To      => 'to@mail.com',
            Subject => 'Subject title',
        ],
        body => 'Content.',
    );
    
    try {
        sendmail($message, { transport => $transport });
    } catch {
        die "Error sending email: $_";
    };

=head1 DESCRIPTION

L<Email::Sender> replaces the old and sometimes problematic L<Email::Send> library, while this module replaces the L<Email::Send::SMTP::TLS>.

It is still alpha, but it works. use it at your own risk!

=head2 ATTRIBUTES

The following attributes may be passed to the constructor:

=over

=item host - the name of the host to connect to; defaults to localhost

=item port - port to connect to; defaults to 587

=item username - the username to use for auth; required

=item password - the password to use for auth; required

=item helo - what to say when saying HELO; no default

=item allow_partial_success - if true, will send data even if some recipients were rejected

=back

=head2 PARTIAL SUCCESS

If C<allow_partial_success> was set when creating the transport, the transport
may return L<Email::Sender::Success::Partial> objects.  Consult that module's
documentation.
