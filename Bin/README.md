Building binaries for Spotty notes
==================================

Spotty on Pi1
-------------

Needs to be linked against gnueabihf. musleabi wouldn't work.

Spotty on ARMv5 (eg. Synology)
------------------------------

The following procedure was successfully tested on Ubuntu-20.04, even within WSL 2 on Windows.

Install latest Rust using rustup with the default settings:

	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

Update environment:

	source $HOME/.cargo/env

Add armv5te target to rust:

	rustup target add armv5te-unknown-linux-musleabi

Install gcc for arm:

	sudo apt install gcc-arm-linux-gnueabi

Put the following in ~/.cargo/config:

	[target.armv5te-unknown-linux-musleabi]
	linker = "arm-linux-gnueabi-gcc"

Build:

	cargo build --target=armv5te-unknown-linux-musleabi --release

Done!

Thanks a lot [jr01](https://github.com/jr01) for this super simplified procedure.

Spotty on macOS 10.9 and older
------------------------------
needs to be built using lewton, but doesn't work with --disable-discovery?

According to the [Rust Platform Support document](https://forge.rust-lang.org/platform-support.html)
only macOS 10.7+ (Lion+) is supported by Rust.

Spotty on Windows
-----------------
Requires MS VC 2015 runtime v14, 32-bit(!)

