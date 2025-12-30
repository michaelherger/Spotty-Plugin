package Slim::Utils::Log;
use strict;
use warnings;

sub import {
    my $pkg = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}

sub logger { bless {}, 'Slim::Utils::Log::Obj' }

package Slim::Utils::Log::Obj;
sub is_info { 1 }
sub is_debug { 1 }
sub info { return 1 }
sub debug { return 1 }
sub warn { return 1 }
sub error { return 1 }

1;
