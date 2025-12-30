package Slim::Utils::Cache;
use strict;
use warnings;

my %STORE;

sub new { bless {}, shift }

sub set {
    my ($self, $k, $v, $ttl) = @_;
    $ttl ||= 0;
    $STORE{$k} = { v => $v, exp => $ttl ? time() + $ttl : 0 };
    return 1;
}

sub get {
    my ($self, $k) = @_;
    return unless exists $STORE{$k};
    my $rec = $STORE{$k};
    if ($rec->{exp} && time() > $rec->{exp}) { delete $STORE{$k}; return undef }
    return $rec->{v};
}

sub remove { my ($self, $k) = @_; delete $STORE{$k}; return 1 }

1;
