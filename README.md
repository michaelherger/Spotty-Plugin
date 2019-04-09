The Spotty Spotify implementation for Logitech Media Server
=====

Spotty is a somewhat spotty implementation of Spotify Connect for the [Squeezebox](http://wiki.slimdevices.com/index.php/Squeezebox_Family_Overview) and [other compatible](https://www.picoreplayer.org) [music players](https://www.max2play.com) running [Squeezelite](https://github.com/ralph-irving/squeezelite) or [Squeezeplay](https://github.com/ralph-irving/squeezeplay) connecting to a [Logitech Media Server](https://github.com/Logitech/slimserver/).

Spotty exposes your Squeezebox as a Squeezebox Connect client. Alternatively you can use any Squeezebox Controller, compatible mobile app or the Logitech Media Server web interface to play music from Spotify.

The Spotty plugin is known to run fine on recent Windows, macOS, and Linux on x86_64, many ARM platforms (including Raspberry Pi, many NAS devices, rock64). Some platforms which are not supported out of the box can probably be supported by compiling the [spotty helper application](https://github.com/michaelherger/spotty) yourself - or some [friendly community member](http://www.neversimple.eu/spotty-for-freebsd.html). It's based on the great [librespot project](https://github.com/librespot-org/librespot).

Disclaimer
---

Using the spotty helper and the librespot code to connect to Spotify's API is probably forbidden by them. Use at your own risk.

