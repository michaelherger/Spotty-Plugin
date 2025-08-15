The Spotty Spotify implementation for Lyrion Music Server
=====

Spotty is a somewhat spotty implementation of Spotify for the [Squeezebox](https://lms-community.github.io/players-and-controllers/) and [other compatible](https://www.picoreplayer.org) [music players](https://www.max2play.com) running [Squeezelite](https://github.com/ralph-irving/squeezelite) or [Squeezeplay](https://github.com/ralph-irving/squeezeplay) connecting to a [Lyrion Music Server](https://lms-community.github.io/getting-started/).

You can use any Squeezebox Controller, compatible mobile app or the Lyrion Music Server web interface to play music from Spotify.

The Spotty plugin is known to run fine on recent Windows, macOS, and Linux on x86_64, and many ARM platforms (including Raspberry Pi, many NAS devices, rock64). Some platforms which are not supported out of the box can probably be supported by compiling the [spotty helper application](https://github.com/michaelherger/librespot) yourself - or some [friendly community member](http://www.neversimple.eu/spotty-for-freebsd.html). It's based on the great [librespot project](https://github.com/librespot-org/librespot).

Configuration
---

Most aspects of the Spotty configuration can be configured in LMS directly, in Settings/Advanced/Spotty.

IMPORTANT: on some systems you might need to tweak a firewall, or configure your container to make things work. Please make sure you allow Spotty, and in particular its helper application which you can find in its `Bin` folder, to reach the internet on ports `80`, `443`, and `4070`!

Disclaimer
---

Using the spotty helper and the librespot code to connect to Spotify's API is probably forbidden by them. Use at your own risk.

