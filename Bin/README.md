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

["I found that the reuse_port is used in rust-mdns address_family.rs - if I comment out line 15 and cargo build (I am using spotty) on my ARM with kernel 2.6 then discovery works."](https://github.com/plietar/librespot/issues/226)

Spotty on macOS 10.9 and older
------------------------------
needs to be built using lewton, but doesn't work with --disable-discovery?