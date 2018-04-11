#!/bin/bash

#===============================================================================
# Filename:  boost.sh
# Author:    Pete Goodliffe
# Copyright: (c) Copyright 2009 Pete Goodliffe
# Licence:   Please feel free to use this, with attribution
# Modified version
#===============================================================================
#
# Builds a Boost framework for the iPhone.
# Creates a set of universal libraries that can be used on an iPhone and in the
# iPhone simulator. Then creates a pseudo-framework to make using boost in Xcode
# less painful.
#
# To configure the script, define:
#    BOOST_LIBS:        which libraries to build
#    IPHONE_SDKVERSION: iPhone SDK version (e.g. 5.1)
#
# Then go get the source tar.bz of the boost you want to build, shove it in the
# same directory as this script, and run "./boost.sh". Grab a cuppa. And voila.
#===============================================================================

: ${BOOST_LIBS:="thread filesystem system"}
: ${IPHONE_SDKVERSION:=`xcodebuild -showsdks | grep iphoneos | egrep "[[:digit:]]+\.[[:digit:]]+" -o | tail -1`}
: ${OSX_SDKVERSION:=10.8}
: ${XCODE_ROOT:=`xcode-select -print-path`}
: ${EXTRA_CPPFLAGS:="-DBOOST_AC_USE_PTHREADS -DBOOST_SP_USE_PTHREADS -std=c++11 -stdlib=libc++"}
: ${JOBS:=16}

# The EXTRA_CPPFLAGS definition works around a thread race issue in
# shared_ptr. I encountered this historically and have not verified that
# the fix is no longer required. Without using the posix thread primitives
# an invalid compare-and-swap ARM instruction (non-thread-safe) was used for the
# shared_ptr use count causing nasty and subtle bugs.
#
# Should perhaps also consider/use instead: -BOOST_SP_USE_PTHREADS

: ${TARBALLDIR:=`pwd`}
: ${SRCDIR:=`pwd`}
: ${PATCHDIR:="$(cd $(dirname $0); pwd)/boost-patches"}
: ${IOSBUILDDIR:=`pwd`/ios/build}
: ${PREFIXDIR:=`pwd`/ios/prefix}
: ${COMPILER:="clang++"}

: ${BOOST_VERSION:=1.58.0}

#===============================================================================
ARM_DEV_CMD="xcrun --sdk iphoneos"
SIM_DEV_CMD="xcrun --sdk iphonesimulator"

ARM_COMBINED_LIB=$IOSBUILDDIR/lib_boost_arm.a
SIM_COMBINED_LIB=$IOSBUILDDIR/lib_boost_x86.a

ARCH_SIMULATOR=
ARCH_IOS=

#===============================================================================
# Functions
#===============================================================================

abort()
{
    echo
    echo "Aborted: $@"
    exit 1
}

doneSection()
{
    echo
    echo "================================================================="
    echo "Done"
    echo
}

#===============================================================================

cleanEverythingReadyToStart()
{
    echo Cleaning everything before we start to build...

    rm -rf iphone-build iphonesim-build
    rm -rf $IOSBUILDDIR
    rm -rf $PREFIXDIR

    doneSection
}

#===============================================================================

downloadBoost()
{
    if [ ! -s $TARBALLDIR/boost_${BOOST_VERSION2}.tar.bz2 ]; then
        echo "Downloading boost ${BOOST_VERSION}"
        curl -L -o $TARBALLDIR/boost_${BOOST_VERSION2}.tar.bz2 "http://netcologne.dl.sourceforge.net/project/boost/boost/${BOOST_VERSION}/boost_${BOOST_VERSION2}.tar.bz2"
    fi

    doneSection
}

#===============================================================================

unpackBoost()
{
    [ -f "$BOOST_TARBALL" ] || abort "Source tarball missing."

    echo Unpacking boost into $SRCDIR...

    [ -d $SRCDIR ]    || mkdir -p $SRCDIR
    [ -d $BOOST_SRC ] || ( cd $SRCDIR; tar xfj $BOOST_TARBALL )
    [ -d $BOOST_SRC ] && echo "    ...unpacked as $BOOST_SRC"

    doneSection
}

#===============================================================================

restoreBoost()
{
    cp $BOOST_SRC/tools/build/src/user-config.jam-bk $BOOST_SRC/tools/build/src/user-config.jam
}

#===============================================================================

updateBoost()
{
    echo Updating boost into $BOOST_SRC...

    mv $BOOST_SRC/tools/build/src/user-config.jam $BOOST_SRC/tools/build/src/user-config.jam-bk

    if [ ! -z "$ARCH_IOS" ]
    then
        ARCH_FLAGS=$(echo "$ARCH_IOS" | sed 's/\([[:alnum:]_]\{1,\}\)/-arch \1/g')

        cat >> $BOOST_SRC/tools/build/src/user-config.jam <<EOF
using darwin : ${IPHONE_SDKVERSION}~iphone
: $XCODE_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/$COMPILER $ARCH_FLAGS -fvisibility=hidden -fvisibility-inlines-hidden $EXTRA_CPPFLAGS
: <striper> <root>$XCODE_ROOT/Platforms/iPhoneOS.platform/Developer
: <architecture>arm <target-os>iphone
;
EOF
    fi

    if [ ! -z "$ARCH_SIMULATOR" ]
    then
        ARCH_FLAGS=$(echo "$ARCH_SIMULATOR" | sed 's/\([[:alnum:]_]\{1,\}\)/-arch \1/g')

        cat >> $BOOST_SRC/tools/build/src/user-config.jam <<EOF
using darwin : ${IPHONE_SDKVERSION}~iphonesim
: $XCODE_ROOT/Toolchains/XcodeDefault.xctoolchain/usr/bin/$COMPILER $ARCH_FLAGS -fvisibility=hidden -fvisibility-inlines-hidden $EXTRA_CPPFLAGS
: <striper> <root>$XCODE_ROOT/Platforms/iPhoneSimulator.platform/Developer
: <architecture>x86 <target-os>iphone
;
EOF
    fi

    doneSection
}

#===============================================================================

bootstrapBoost()
{
    cd $BOOST_SRC

    BOOST_LIBS_COMMA=$(echo $BOOST_LIBS | sed -e "s/ /,/g")
    echo "Bootstrapping (with libs $BOOST_LIBS_COMMA)"
    ./bootstrap.sh --with-libraries=$BOOST_LIBS_COMMA

    doneSection
}

#===============================================================================

buildBoostForIPhoneOS()
{
    cd $BOOST_SRC

    if [ ! -z "$ARCH_IOS" ]
    then
        ./bjam -j$JOBS --build-dir=iphone-build --stagedir=iphone-build/stage \
            --prefix=$PREFIXDIR toolset=darwin architecture=arm \
            target-os=iphone macosx-version=iphone-${IPHONE_SDKVERSION} \
            define=_LITTLE_ENDIAN link=static stage

        # Install this one so we can copy the includes for the frameworks...
        ./bjam -j$JOBS --build-dir=iphone-build --stagedir=iphone-build/stage \
            --prefix=$PREFIXDIR toolset=darwin architecture=arm \
            target-os=iphone macosx-version=iphone-${IPHONE_SDKVERSION} \
            define=_LITTLE_ENDIAN link=static install

        INSTALLED=1

        doneSection
    fi

    if [ ! -z "$ARCH_SIMULATOR" ]
    then
        ./bjam -j$JOBS --build-dir=iphonesim-build \
            --stagedir=iphonesim-build/stage \
            --toolset=darwin-${IPHONE_SDKVERSION}~iphonesim architecture=x86 \
            target-os=iphone macosx-version=iphonesim-${IPHONE_SDKVERSION} \
            link=static stage

        if [ "$INSTALLED" != 1 ]
        then
            ./bjam -j$JOBS --build-dir=iphonesim-build \
                --stagedir=iphonesim-build/stage \
                --toolset=darwin-${IPHONE_SDKVERSION}~iphonesim \
                architecture=x86 target-os=iphone \
                macosx-version=iphonesim-${IPHONE_SDKVERSION} \
                link=static stage
        fi

        doneSection
    fi
}

#===============================================================================

scrunchAllLibsTogetherInOneLibPerPlatform()
{
    cd $BOOST_SRC

    echo Building fat libraries...

    for NAME in $BOOST_LIBS
    do
        LIBS=

        if [ ! -z "$ARCH_IOS" ]
        then
            LIBS="$LIBS iphone-build/stage/lib/libboost_$NAME.a"
        fi

        if [ ! -z "$ARCH_SIMULATOR" ]
        then
            LIBS="$LIBS iphonesim-build/stage/lib/libboost_$NAME.a"
        fi

        lipo -c $LIBS -o $IOSBUILDDIR/libboost_$NAME.a
    done
}

setArchitectures()
{
    for ARCH in $@
    do
        case $ARCH in
            i386|x86_64)
                ARCH_SIMULATOR="${ARCH_SIMULATOR} $ARCH"
                ;;
            armv7|arm64)
                ARCH_IOS="${ARCH_IOS} $ARCH"
                ;;
        esac
    done
}

#===============================================================================
# Execution starts here
#===============================================================================

for ARG in $@
do
    case "$ARG" in
        --boost=*)
            BOOST_VERSION=${ARG#--boost=}
            ;;
        --with-libraries=*)
            BOOST_LIBS="$(echo ${ARG#--with-libraries=} | tr -c '[a-z]\n' ' ')"
            ;;
        --clean)
            DO_CLEAN=1
            ;;
        --arch=*)
            setArchitectures $(echo ${ARG#--arch=} | tr -c '[a-z_0-9]\n' ' ')
            ;;
    esac
done

BOOST_VERSION2=$(echo $BOOST_VERSION | tr '.' '_')

BOOST_TARBALL=$TARBALLDIR/boost_$BOOST_VERSION2.tar.bz2
BOOST_SRC=$SRCDIR/boost_${BOOST_VERSION2}

mkdir -p $IOSBUILDDIR

if [ "$DO_CLEAN" = 1 ]
then
    cleanEverythingReadyToStart
    restoreBoost
fi

echo "BOOST_VERSION:     $BOOST_VERSION"
echo "BOOST_LIBS:        $BOOST_LIBS"
echo "BOOST_SRC:         $BOOST_SRC"
echo "IOSBUILDDIR:       $IOSBUILDDIR"
echo "PREFIXDIR:         $PREFIXDIR"
echo "IOSFRAMEWORKDIR:   $IOSFRAMEWORKDIR"
echo "IPHONE_SDKVERSION: $IPHONE_SDKVERSION"
echo "XCODE_ROOT:        $XCODE_ROOT"
echo "COMPILER:          $COMPILER"
echo "SIMULATOR:         $SIMULATOR"
echo

downloadBoost
unpackBoost
bootstrapBoost
updateBoost
buildBoostForIPhoneOS
scrunchAllLibsTogetherInOneLibPerPlatform

restoreBoost

echo "Completed successfully"

#===============================================================================
