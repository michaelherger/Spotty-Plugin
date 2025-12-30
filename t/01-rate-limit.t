use strict;
use warnings;
use lib 't/libs';
use Test::More tests => 6;

# Minimal test-time replacements are provided in t/libs and enabled via use lib

# Provide main::INFOLOG and main::DEBUGLOG subs expected by the module
package main;
sub INFOLOG { 1 }
sub DEBUGLOG { 1 }
package main;

# Load the module under test
require "./API/RateLimit.pm";

ok(!Plugins::Spotty::API::RateLimit->isRateLimited(), 'Not rate limited initially');

# Set a short rate limit and check
Plugins::Spotty::API::RateLimit->setRateLimit(2);
ok(Plugins::Spotty::API::RateLimit->isRateLimited(), 'Rate limited after set');

my $remaining = Plugins::Spotty::API::RateLimit->getRemainingSeconds();
ok($remaining > 0 && $remaining <= 3, "Remaining seconds reasonable: $remaining");

# Test queueing and processing
my $ran = 0;
Plugins::Spotty::API::RateLimit->queueRequest(sub { $ran = 1 });
ok(1, 'Queued a request');

Plugins::Spotty::API::RateLimit->processQueueAfterRateLimit();
ok($ran == 1, 'Queued request executed');

# Clear and verify
Plugins::Spotty::API::RateLimit->clearRateLimit();
ok(!Plugins::Spotty::API::RateLimit->isRateLimited(), 'Rate limit cleared');

DONE:;
