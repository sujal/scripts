#! /bin/bash
#
# iPhone packaging script
# Copyright 2012 Sujal Shah <codesujal@gmail.com>
# 
# Using code originally by Frank Szczerba (See copyright notice below)
#
# ============================================================================
#
# Copyright 2009, Frank Szczerba <frank@szczerba.net>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#    * Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the copyright holder nor the names of any
#      contributors may be used to endorse or promote products derived from
#      this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

#
# Helper functions
#
die() {
	echo "$*" >&2
	exit 1
}

usage() {
	if [ -n "$1" ] ; then
		echo "$@" >&2
		printf "\n"
	fi
	echo "usage: build [-nlD] [scheme...]" >&2
	echo "    -n : do not update build number or commit to git/svn & do not distribute" >&2
	echo "    -l : keep build local - do not distribute to testflight" >&2
	echo "    -D : force distribution to testflight (useful w/ -n)" >&2
	if [ -n "$xcodeschemes" ] ; then
		printf "\n    Known schemes:" >&2
		printf " %s" $xcodeschemes >&2
		printf "\n\nscheme is REQUIRED\n" >&2
	else
		echo "This does not appear to be a valid project directory!" >&2
	fi
	exit 3
}

svn_status() {
	svn status
}

svn_dirtycheck() {
	(cd "$1"; svn status) | egrep -qv '^X|Performing status|^$'
}

svn_commit() {
	svn commit -m "$1"
}

svn_tag() {
	echo "Tagging not supported for SVN"
}

svn_fullvers() {
	svn info | egrep "^Revision:" | awk '{print "SVN"$2}'
}

git_status() {
	git status
}

git_dirtycheck() {
	! (cd "$1" ; git status) | grep -q 'nothing to commit (working directory clean)'
}

git_commit() {
	
	git commit -a -n -m "$1"
	
}

git_tag() {
	git tag "$1" -m "$2"
}

git_fullvers() {
	git rev-parse HEAD 2>/dev/null
}

if [ -d '.svn' ]; then
	VCPREFIX=svn
else
	VCPREFIX=git
fi

#
# Default options
#
project="$(basename $(pwd))"
projectdir="$(pwd)"
nocommit=0
nodistribute=0
force_distribute=0
schemes=
buildbase=build
build_command=archive
archive_dir=$HOME/Library/Developer/Xcode/Archives/`date +"%Y-%m-%d"`

echo $projectdir

# source repos shared across multiple projects, these must be clean and get
# tagged with everything else
sharedsources=

# all known configurations

xcodeproject="$(xcodebuild -list | perl -ne ' if (/Information about project "([^"]+)"/) { print $1,"\n"; }')"

xcodeschemes="$(xcodebuild -list | sed '
    /Schemes:/,/^[[:space:]]*$/  !d
    /Schemes/        d
    /^[[:space:]]*$/        d
    s/^[[:space:]]*//
    s/(.*)//
    s/[[:space:]]*$//  ')"

if [ -z "$xcodeproject" ] ; then
	# no project bundle?
	usage;
fi

#
# Parse command line options
#
while [ -n "$*" ]; do
	case "$1" in
		-n) nocommit=1 
		    if [ $force_distribute -eq 0 ] ; then
		      nodistribute=1
		    fi 
		    shift
		    ;;
		-l) nodistribute=1 ; shift ;;
		-D) force_distribute=1 ; nodistribute=0 ; shift ;;
		-*) usage ;;
		*)	if echo $xcodeschemes | grep -wq "$1" ; then
				if [ -z "$schemes" ]; then
					schemes="$1"
				else
					schemes="${schemes}:$1";
				fi
				shift 
			else
				usage "Invalid scheme '$1'"
			fi
			;;
	esac
done

# require a scheme
if [ -z "$schemes" ] ; then
	usage;
fi

echo "$schemes"

# check for modified files, bail if found
isdirty=0

for d in . $sharedsources ; do
	if ${VCPREFIX}_dirtycheck ; then
		if [ "$nocommit" -eq "0" ] ; then
			# if committing the directory must be clean at first
			${VCPREFIX}_status
			die "directory \"$d\" is dirty"
		else
			# development build, just remember that it was dirty
			isdirty=1
		fi
	fi
done

if [ "$nocommit" -eq "0" ] ; then

	# read out the marketing version
	# do this separate from the cut so we can check the exit code
	mvers=$(agvtool mvers -terse | head -1)
	if [ $? -ne 0 -o -z "$mvers" ] ; then
		die "No marketing version found"
	fi

	if echo "$mvers" | grep -q = ; then
		mvers=$(echo "$mvers" | cut -f 2 -d =)
	fi

	# going to commit, bump the version number
	agvtool bump -all

	bvers=$(agvtool vers -terse)
	if [ $? -ne 0 -o -z "$bvers" ] ; then
		die "No build version found"
	fi

	# read out the build version, must exist if the marketing version does
	fullvers="$mvers build $bvers"
	tag=$(echo "$fullvers" | tr ' ' _)

	# commit the changed version and tag it
	echo "Committing "$fullvers" with tag $tag"
	${VCPREFIX}_commit "Set build version '$fullvers'" || die 'commit failed'
	${VCPREFIX}_tag "$tag" "$fullvers"
	libtag=$(echo "$project-$tag" | tr ' ' _)
	for d in $sharedsources ; do
		(cd $d ; ${VCPREFIX}_tag $libtag "$project $tag")
	done
else

	# not committing, use the SHA1 as the version
	TAGFUNCTION="${VCPREFIX}_fullvers"
	fullvers=`$TAGFUNCTION`
	
	# if it's dirty, append the date, time, and timezone
	if [ "$isdirty" -ne 0 ] ; then
		fullvers="$fullvers+ $(date +%F\ %T\ %Z)"
	fi
fi

# clean up old builds
rm -rf Payload
logname=$(mktemp /tmp/build.temp.XXXXXX)
printf "Created:" > $logname

# read in build config
. "$projectdir/.codesigning"

# build and package each requested config
SAVEIFS=$IFS
IFS=$':'
for scheme in $schemes ; do
	scheme=`echo $scheme | sed 's/^[[:space:]]//'`

	echo "SCHEME=$scheme"
	
	# packaged output goes in Releases if tagged, Development otherwise
	if [ "$nocommit" -eq "0" ] ; then
		basedir=Releases
	else
		basedir=Development
	fi

	releasedir="$basedir/$scheme/$fullvers"
	mkdir -p "$releasedir"  

  (xcodebuild -project "$xcodeproject.xcodeproj" -scheme "$scheme" -parallelizeTargets clean $build_command 2>&1 | tee "$basedir/xcodebuild.log") || die "Build failed"

  xcodebuild_fail_count=`grep -c '\*\* BUILD FAILED \*\*' "$basedir/xcodebuild.log"`

  if [ "$xcodebuild_fail_count" -ne "0" ]; then 
    die "Build Failed - see above"
  fi

	# Package each app

  latestXCArchive="$archive_dir/$(cd "$archive_dir"; ls -1dt $scheme* | head -1)"
  # latestXCArchive="${latestXCArchive%?}"
  app=`find "$latestXCArchive" -name *.app`
  appname=$scheme # could derive this from $app
  dsym="$latestXCArchive/dSYMs/$scheme.app.dSYM"
  
  echo "$latestXCArchive"

  # package for ad hoc

  VARSAFE_SCHEME=`echo $scheme | tr "[[:lower:]] -" "[[:upper:]]_"`
  ADHOC_PRO=`eval echo \\$${VARSAFE_SCHEME}_ADHOC_PROFILE`
  STORE_PRO=`eval echo \\$${VARSAFE_SCHEME}_STORE_PROFILE`

  echo \n\n\n==========================================================
  echo "Signing for distribution and adhoc as $DISTRIBUTION_IDENTITY"
  echo "app: $app"
  echo ==========================================================\n\n\n

  /usr/bin/xcrun -sdk iphoneos PackageApplication -v "$app" \
       -o "$projectdir/$releasedir/$scheme.ipa" \
       --sign "$DISTRIBUTION_IDENTITY" \
       --embed "$ADHOC_PRO"

  # # package for store
  # cp -Rp "$app" "$projectdir/$releasedir/"
  # codesign -f -vv -s "$DISTRIBUTION_IDENTITY" -i "$STORE_PRO" "$projectdir/$releasedir/$scheme.app"
  # ditto -c -k --keepParent "$projectdir/$releasedir/$scheme.app" "$projectdir/$releasedir/$scheme.app.zip"

	# save debug symbols (if available) with the app
  echo \n\n\n==========================================================
  echo "saving DSYM"
  echo "dsym: $dsym"
  echo ==========================================================\n\n\n

	if [ -d "$dsym" ] ; then
		output="$projectdir/$releasedir/$scheme.dSYM.zip"
		ditto -c -k --keepParent -rsrc "$dsym" "$output" || die "Failed to compress debug info"
		printf "\t\t\t$output\n" >> $logname
	fi
	
  if [ "$nodistribute" -eq "0" ]; then
  
    SKIP_LIST=0 # leftover

    if [ "$SKIP_LIST" -eq "0" -a -f "$projectdir/.testflight" ]; then
      . "$projectdir/.testflight"
    
      echo
      echo "Enter release notes (end w/ a ^D):"
      echo
      NOTES_FILENAME=`mktemp iphonebuildscript`
      cat > $NOTES_FILENAME
      RELEASE_NOTES="`cat $NOTES_FILENAME`"
      rm $NOTES_FILENAME

      TESTFLIGHT_URL=`curl http://testflightapp.com/api/builds.json \
        -F file="@$projectdir/$releasedir/$scheme.ipa" \
        -F dsym="@$projectdir/$releasedir/$scheme.dSYM.zip" \
        -F api_token="$API_TOKEN" \
        -F team_token="$TEAM_TOKEN" \
        -F notes="$RELEASE_NOTES"  \
        -F notify=True  \
        -F replace=True \
        -F distribution_lists="$DISTRIBUTION_LISTS" | perl -ne 'if (/"install_url":\s+"([^"]+)"/){ print "$1\n";}'`
      
      if [ -f "$projectdir/.campfire" ]; then
        . "$projectdir/.campfire"
        curl -u "$CF_ROOM_TOKEN":X -H 'Content-Type: application/json' \
        -d "{\"message\":{\"body\":\"$scheme $fullvers available on Testflight: $TESTFLIGHT_URL\"}}" \
        "https://$CF_ROOM_SUBDOMAIN.campfirenow.com/room/$CF_ROOM_ID/speak.json"
      fi
    fi
  fi #end is_adhoc check
	
done
IFS=$SAVEIFS

# report the generated files
printf "\n" >> $logname
cat $logname
rm $logname
