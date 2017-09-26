Building binaries for Spotty notes
==================================

Build pv for ARMv5
------------------

Using a [Synology toolchain](https://sourceforge.net/projects/dsgpl/files/), [88f62x (DSM 6.1)](https://sourceforge.net/projects/dsgpl/files/DSM%206.1%20Tool%20Chains/Marvell%2088F628x%20Linux%202.6.32/6281-gcc464_glibc215_88f6281-GPL.txz/download)

    git clone https://github.com/icetee/pv
    cd pv
    export HOST=x86_64-unknown-linux-gnu
    export TARGET=armv5te-rcross-linux-gnueabi
    export CC=/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-gcc
    export AR=/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-ar
    export LD=/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-ld
    export CFLAGS="-Wall -Os -fPIC -D__arm__ -mfloat-abi=soft"
    ./configure --HOST=$HOST --TARGET=$TARGET
    make

    
Spotty on Pi1
-------------

Needs to be linked against gnueabihf. musleabi wouldn't work.

Spotty on ARMv5 (Synology)
--------------------------

Based on [https://github.com/joerg-krause/rust-cross-libs](https://github.com/joerg-krause/rust-cross-libs/issues/5):

My host is Ubuntu 17.04 x86_64. Needs i386 support (maybe using i386 to start with would be easier?...)
    `$ sudo apt-get install libc6:i386 libncurses5:i386 libstdc++6:i386`

My target is a synology DS212 running DSM 6.1 which according to [What_kind_of_CPU_does_my_NAS_have](https://www.synology.com/en-global/knowledgebase/DSM/tutorial/General/What_kind_of_CPU_does_my_NAS_have) has a Marvell Kirkwood 88F6282 CPU.

Synology provides downloadable toolchains here: [synology toolchains](https://sourceforge.net/projects/dsgpl/files/)

Download the one for DSM 6.1 and 88f62x CPU: [88f62x](https://sourceforge.net/projects/dsgpl/files/DSM%206.1%20Tool%20Chains/Marvell%2088F628x%20Linux%202.6.32/6281-gcc464_glibc215_88f6281-GPL.txz/download)

Unpack the toolchain to /usr/local:  
    `$ sudo tar Jxvf ~/Downloads/6281-gcc464_glibc215_88f6281-GPL.txz -C /usr/local`

Set-up a sysroot.sh file.

    $ sudo cat << EOF > /usr/local/arm-marvell-linux-gnueabi/sysroot.sh
    #!/bin/bash

    SYSROOT=/usr/local/arm-marvell-linux-gnueabi/arm-marvell-linux-gnueabi/libc

    /usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-gcc --sysroot=\$SYSROOT \$(echo "\$@" | sed 's/-L \/usr\/lib //g')
    EOF

Make the sysroot.sh executable  
    `$ sudo chmod +x /usr/local/arm-marvell-linux-gnueabi/sysroot.sh`

Set-up a cargo config file

    $ cat << EOF > ~/.cargo/config
    [target.armv5te-rcross-linux-gnueabi]
    linker = "/usr/local/arm-marvell-linux-gnueabi/sysroot.sh"
    ar = "/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-ar"
    EOF

Get the rust source and binaries

    $ git clone https://github.com/joerg-krause/rust-cross-libs.git
    $ cd rust-cross-libs
    $ git clone https://github.com/rust-lang/rust rust-git
    $ wget https://static.rust-lang.org/dist/rust-nightly-x86_64-unknown-linux-gnu.tar.gz
    $ tar xf rust-nightly-x86_64-unknown-linux-gnu.tar.gz
    $ rust-nightly-x86_64-unknown-linux-gnu/install.sh --prefix=$PWD/rust

Define the rust environment

    $ export PATH=$PWD/rust/bin:$PATH
    $ export LD_LIBRARY_PATH=$PWD/rust/lib
    $ export RUST_TARGET_PATH=$PWD/cfg

Define the cross toolchain environment

    $ export HOST=x86_64-unknown-linux-gnu
    $ export TARGET=armv5te-rcross-linux-gnueabi
    $ export CC=/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-gcc
    $ export AR=/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabi-ar
    $ export CFLAGS="-Wall -Os -fPIC -D__arm__ -mfloat-abi=soft"

The panic strategy in the armv5te $TARGET.json is abort, so use  
    `$ ./rust-cross-libs.sh --rust-prefix=$PWD/rust --rust-git=$PWD/rust-git --target=$PWD/cfg/$TARGET.json`

At this point I created the hello world example and verified it worked on the DS212.

Download the spotty source code  
    `$ git clone https://github.com/michaelherger/spotty`

Build spotty with cargo

    $ cargo update
    $ cargo build --target=$TARGET --release

This failed the first time with a build error in nix 0.8.1 library

I opened the failing file signal.rs in vi  
    `$ vi ~/.cargo/registry/src/github.com-1ecc6299db9ec823/nix-0.8.1/src/sys/signal.rs`

and added these line a few lines below 	sev.sigev_notify = match sigev_notify"

    #[cfg(all(target_os = "linux"))]
    SigevNotify::SigevThreadId{..} => libc::SIGEV_THREAD_ID,

I have no idea what this does, I just made sure it builds :-). The hack in signal.rs is not needed when env="gnu" in $PWD/cfg/armv5-rcross-linux-gnueabi.json. The "gnueabi" target was changed to "gnu" in rust.  
I have submitted a [PR](https://github.com/joerg-krause/rust-cross-libs/pull/7) to [@joerg-krause](https://github.com/joerg-krause)

Running the cargo build again:  
    `$ cargo build --target=$TARGET --release`

note: I tried using buildroot at first instead of the synology provided toolchain. With the external Sourcery Codebench ARM 2014.05 toolchain I got a spotty, but it was linked against glibc 2.17 and the DS212 has 2.15 installed, so that didn't work.



["I found that the reuse_port is used in rust-mdns address_family.rs - if I comment out line 15 and cargo build (I am using spotty) on my ARM with kernel 2.6 then discovery works."](https://github.com/plietar/librespot/issues/226)

Spotty on macOS 10.9 and older
------------------------------
needs to be built using lewton, but doesn't work with --disable-discovery?

Spotty on Windows
-----------------
Requires MS VC 2015 runtime v14, 32-bit(!)

