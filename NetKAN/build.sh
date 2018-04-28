#!/bin/bash

set -e

# We want our globs to be null
shopt -s nullglob

# Locations of CKAN and NetKAN.
LATEST_CKAN_URL="http://ckan-travis.s3.amazonaws.com/ckan.exe"
LATEST_NETKAN_URL="http://ckan-travis.s3.amazonaws.com/netkan.exe"
LATEST_CKAN_META="https://github.com/KSP-CKAN/CKAN-meta/archive/master.tar.gz"
LATEST_CKAN_VALIDATE="https://raw.githubusercontent.com/KSP-CKAN/CKAN/master/bin/ckan-validate.py"
LATEST_CKAN_SCHEMA="https://raw.githubusercontent.com/KSP-CKAN/CKAN/master/CKAN.schema"

# Third party utilities.
JQ_PATH="jq"

# Return codes.
EXIT_OK=0
EXIT_FAILED_PROVE_STEP=1
EXIT_FAILED_JSON_VALIDATION=2
EXIT_FAILED_ROOT_NETKANS=3
EXIT_FAILED_DUPLICATE_IDENTIFIERS=4

# Allow us to specify a commit id as the first argument
if [ -n "$1" ]
then
    echo "Using CLI argument of $1"
    ghprbActualCommit=$1
fi

# ------------------------------------------------
# Function for creating dummy KSP directories to
# test on. Takes version as an argument.
# ------------------------------------------------
create_dummy_ksp () {
    # Set the version to the requested KSP version
    KSP_VERSION=$1
    KSP_NAME=$2

    echo "Creating a dummy KSP '$KSP_VERSION' install"

    # Remove any existing KSP dummy install.
    if [ -d "dummy_ksp/" ]
    then
        rm -rf dummy_ksp
    fi

    # Create a new dummy KSP.
    mkdir -p --verbose \
        dummy_ksp \
        dummy_ksp/CKAN \
        dummy_ksp/GameData \
        dummy_ksp/Ships/ \
        dummy_ksp/Ships/VAB \
        dummy_ksp/Ships/SPH \
        dummy_ksp/Ships/@thumbs \
        dummy_ksp/Ships/@thumbs/VAB \
        dummy_ksp/Ships/@thumbs/SPH

    # Link to the downloads cache.
    # NOTE: If this isn't done before ckan.exe uses the instance,
    #       it will be auto-created as a plain directory!
    ln -s --verbose ../../downloads_cache/ dummy_ksp/CKAN/downloads

    # Set the base game version
    echo "Version $KSP_VERSION" > dummy_ksp/readme.txt

    # Simulate the DLC if base game version 1.4.0 or later
    if versions_less_or_equal 1.4.0 "$KSP_VERSION"
    then
        mkdir --p --verbose \
            dummy_ksp/GameData/SquadExpansion/MakingHistory
        echo "Version 1.1.0" > dummy_ksp/GameData/SquadExpansion/MakingHistory/readme.txt
    fi

    # Copy in resources.
    cp --verbose ckan.exe dummy_ksp/ckan.exe

    # Reset the Mono registry.
    if [ "$USER" = "jenkins" ]
    then
        REGISTRY_FILE=$HOME/.mono/registry/CurrentUser/software/ckan/values.xml
        if [ -r $REGISTRY_FILE ]
        then
            rm -f --verbose $REGISTRY_FILE
        fi
    fi

    # Register the new dummy install.
    mono ckan.exe ksp add $KSP_NAME "`pwd`/dummy_ksp"

    # Set the instance to default.
    mono ckan.exe ksp default $KSP_NAME

    # Point to the local metadata instead of GitHub.
    mono ckan.exe repo add local "file://`pwd`/master.tar.gz"
    mono ckan.exe repo remove default
}

# ------------------------------------------------
# Function for injecting metadata into a tar.gz
# archive. Assummes metadata.tar.gz to be present.
# ------------------------------------------------
inject_metadata () {
    # TODO: Arrays + Bash Functions aren't fun. This needs
    # Improvement but appears to work. The variables are
    # available to the called functions.

    # Check input, requires at least 1 argument.
    if [ $# -ne 1 ]
    then
        echo "Nothing to inject."
        cp --verbose metadata.tar.gz master.tar.gz
        return 0
    fi

    echo "Injecting into metadata."

    # Extract the metadata into a new folder.
    rm -rf CKAN-meta-master
    tar -xzf metadata.tar.gz

    # Copy in the files to inject.
    for f in "${OTHER_FILES[@]}"
    do
        echo "Injecting: $f"
        DEST="CKAN-meta-master/$f"
        mkdir -p --verbose $(dirname "$DEST")
        cp --verbose $f "$DEST"
    done

    # Recompress the archive.
    rm -f --verbose master.tar.gz
    tar -czf master.tar.gz CKAN-meta-master
}

# ------------------------------------------------
# Print the list of game versions we know about.
# ------------------------------------------------
get_versions() {
    # Usage: VERSIONS=( $(get_versions) )

    # Get our official list of releases
    BUILDS_JSON=$(wget -q -O - https://raw.githubusercontent.com/KSP-CKAN/CKAN/master/Core/builds.json)

    # Get just the MAJOR.MINOR.PATCH strings
    echo $BUILDS_JSON | "$JQ_PATH" --raw-output '.builds[]' \
        | sed -e 's/\.[0-9]\+$//' \
        | uniq \
        | tac
}

# ------------------------------------------------
# Compare two game versions.
# Returns true if first <= second, false otherwise.
# ------------------------------------------------
versions_less_or_equal() {
    # Usage: versions_less_or_equal major1.minor1.patch1 major2.minor2.patch2
    # Returns: 0=true, 1=false, 2=error
    VER1=$1
    VER2=$2

    if [[ -z $VER1 || -z $VER2 ]]
    then
        # Null means unbounded, so always match
        return 0
    elif [[ $VER1 =~ ^([0-9]+)\.([0-9]+) ]]
    then
        MAJOR1=${BASH_REMATCH[1]}
        MINOR1=${BASH_REMATCH[2]}
        if [[ $VER2 =~ ^([0-9]+)\.([0-9]+) ]]
        then
            MAJOR2=${BASH_REMATCH[1]}
            MINOR2=${BASH_REMATCH[2]}
            if   (( $MAJOR1 < $MAJOR2 )); then return 0
            elif (( $MAJOR1 > $MAJOR2 )); then return 1
            elif (( $MINOR1 < $MINOR2 )); then return 0
            elif (( $MINOR1 > $MINOR2 )); then return 1
            else
                # First two numbers match, check for a third
                if [[ $VER1 =~ ^[0-9]+\.[0-9]+\.([0-9]+) ]]
                then
                    PATCH1=${BASH_REMATCH[1]}
                    if [[ $VER2 =~ ^[0-9]+\.[0-9]+\.([0-9]+) ]]
                    then
                        PATCH2=${BASH_REMATCH[1]}
                        if   (( $PATCH1 < $PATCH2 )); then return 0
                        elif (( $PATCH1 > $PATCH2 )); then return 1
                        else
                            # All are equal
                            return 0
                        fi
                    else
                        # No third digit, accept it
                        return 0
                    fi
                else
                    # No third digit, accept it
                    return 0
                fi
            fi
        else
            # Second version not valid
            return 2
        fi
    else
        # First version not valid
        return 2
    fi
}

# ------------------------------------------------
# Print versions that match the given min and max.
# ------------------------------------------------
matching_versions() {
    # ASSUMES: We have done VERSIONS=( $(get_versions) ) globally
    # Usage: matching_versions ksp_version_min ksp_version_max
    MIN=$1
    MAX=$2

    if [[ ( -z "$MIN" && -z "$MAX" ) || ( "$MIN" = any && "$MAX" = any ) ]]
    then
        echo "${VERSIONS[@]}"
    else
        declare -a MATCHES
        MATCHES=()
        for VER in "${VERSIONS[@]}"
        do
            if versions_less_or_equal "$MIN" "$VER" && versions_less_or_equal "$VER" "$MAX"
            then
                MATCHES+=($VER)
            fi
        done
        echo "${MATCHES[@]}"
    fi
}

# ------------------------------------------------
# Print versions that match the given .ckan file.
# ------------------------------------------------
ckan_matching_versions() {
    # Usage: ckan_matching_versions modname-version.ckan
    CKAN="$1"

    # Get min and max versions
    MIN=$("$JQ_PATH" --raw-output 'if .ksp_version then .ksp_version else .ksp_version_min end' "$CKAN")
    MAX=$("$JQ_PATH" --raw-output 'if .ksp_version then .ksp_version else .ksp_version_max end' "$CKAN")

    matching_versions "$MIN" "$MAX"
}

# ------------------------------------------------
# Print max real version compatible with given .ckan file.
# Even if you claim compatibility with 99.99.99, this
# will only return the most recent release.
# ------------------------------------------------
ckan_max_real_version() {
    # Usage: ckan_max_real_version modname-version.ckan
    CKAN="$1"

    VERS=( $(ckan_matching_versions "$CKAN") )
    echo "${VERS[0]}"
}

declare -a VERSIONS
VERSIONS=( $(get_versions) )

# ------------------------------------------------
# Main entry point.
# ------------------------------------------------

if [ -n "$ghprbActualCommit" ]
then
    echo "Commit hash: $ghprbActualCommit"
    export COMMIT_CHANGES="`git diff --diff-filter=AM --name-only --stat origin/master...HEAD`"
else
    echo "No commit provided, skipping further tests."
    exit $EXIT_OK
fi

# Make sure we start from a clean slate.
if [ -d "built/" ]
then
    rm -rf --verbose built
fi

if [ -d "downloads_cache/" ]
then
    rm -rf --verbose downloads_cache
fi

if [ -e "master.tar.gz" ]
then
    rm -f --verbose master.tar.gz
fi

if [ -e "metadata.tar.gz" ]
then
    rm -f --verbose metadata.tar.gz
fi

# Check our new NetKAN is not in the root of our repo
root_netkans=( *.netkan )

if (( ${#root_netkans[@]} > 0 ))
then
    echo NetKAN file found in root of repository, please move it into NetKAN/
    exit $EXIT_FAILED_ROOT_NETKANS
fi

# Check JSON.
echo "Running jsonlint on the changed files"
echo "If you get an error below you should look for syntax errors in the metadata"

for f in $COMMIT_CHANGES
do
    if ! [[ "$f" =~ ^NetKAN/ ]]
    then
        echo "Skipping file '$f': Not in the NetKAN directory."
        continue
    elif [[ "$f" =~ .frozen$ ]]
    then
        echo "Lets try not to validate '$f' with jsonlint"
        continue
    fi

    echo "Validating $f..."
    jsonlint -s -v $f

    if [ $? -ne 0 ]
    then
        echo "Failed to validate $f"
        exit $EXIT_FAILED_JSON_VALIDATION
    fi
done
echo ""

# Run basic tests.
echo "Running basic sanity tests on metadata."
echo "If these fail, then fix whatever is causing them first."

if ! prove
then
    echo "Prove step failed."
    exit $EXIT_FAILED_PROVE_STEP
fi

# Find the changes to test.
echo "Finding changes to test..."

# Print the changes.
echo "Detected file changes:"
for f in $COMMIT_CHANGES
do
    echo "$f"
done
echo ""

# Create folders.
mkdir --verbose built
# Point to cache folder here
mkdir --verbose downloads_cache

# Fetch latest ckan and netkan executable.
echo "Fetching latest ckan.exe"
wget --quiet $LATEST_CKAN_URL -O ckan.exe
mono ckan.exe version

echo "Fetching latest netkan.exe"
wget --quiet $LATEST_NETKAN_URL -O netkan.exe
mono netkan.exe --version

# CKAN Validation files
wget --quiet $LATEST_CKAN_VALIDATE -O ckan-validate.py
wget --quiet $LATEST_CKAN_SCHEMA -O CKAN.schema
chmod a+x --verbose ckan-validate.py

# Fetch the latest metadata.
echo "Fetching latest metadata"
wget --quiet $LATEST_CKAN_META -O metadata.tar.gz

# Determine KSP dummy name.
if [ -z $ghprbActualCommit ]
then
    KSP_NAME=dummy
else
    KSP_NAME=$ghprbActualCommit
fi

# Build all the passed .netkan files.
# Note: Additional NETKAN_OPTIONS may be set on jenkins jobs
for f in $COMMIT_CHANGES
do
    if [[ "$f" =~ \.netkan$ ]]
    then
        basename=$(basename "$f" .netkan)
        frozen_files=( "NetKAN/$basename.frozen"* )

        if [ ${#frozen_files[@]} -gt 0 ]
        then
            echo "'$basename' matches an existing frozen identifier: ${frozen_files[@]}"
            exit $EXIT_FAILED_DUPLICATE_IDENTIFIERS
        fi

        echo "Running NetKAN for $f"
        mono netkan.exe $f --cachedir="downloads_cache" --outputdir="built" $NETKAN_OPTIONS
    else
        echo "Let's try not to build '$f' with netkan"
    fi
done

# Test all the built files.
for ckan in built/*.ckan
do
    if [ ! -e "$ckan" ]
    then
        echo "No ckan files to test"
        continue
    fi

    echo "Checking $ckan"
    ./ckan-validate.py $ckan
    echo "----------------------------------------------"
    echo ""
    cat $ckan | python -m json.tool
    echo "----------------------------------------------"
    echo ""

    # Get a list of all the OTHER files.
    OTHER_FILES=()

    for o in built/*.ckan
    do
        OTHER_FILES+=($o)
    done

    # Inject into metadata.
    inject_metadata $OTHER_FILES

    # Extract identifier and KSP version.
    CURRENT_IDENTIFIER=$($JQ_PATH --raw-output '.identifier' $ckan)
    CURRENT_KSP_VERSION=$(ckan_max_real_version "$ckan")

    # TODO: Someday we could loop over ( $(ckan_matching_versions "$ckan") ) to find
    #       working versions less than the maximum, if the maximum doesn't work.
    #       (E.g., a dependency isn't updated yet.)

    echo "Extracted $CURRENT_IDENTIFIER as identifier."
    echo "Extracted $CURRENT_KSP_VERSION as KSP version."

    # Create a dummy KSP install.
    create_dummy_ksp $CURRENT_KSP_VERSION $KSP_NAME

    echo "Running ckan update"
    mono ckan.exe update

    echo "Running ckan install -c $ckan"
    mono ckan.exe install -c $ckan --headless

    # Print list of installed mods.
    mono ckan.exe list --porcelain

    # Check the installed files for this .ckan file.
    mono ckan.exe show $CURRENT_IDENTIFIER

    # Cleanup.
    mono ckan.exe ksp forget $KSP_NAME

    # Check for Installations that have gone wrong.
    gamedata=($(find dummy_ksp/GameData/. -name GameData -exec sh -c 'if test -d "{}"; then echo "{}";fi' \;))
    if (( ${#gamedata[@]} > 0 ))
    then
      echo "GameData directory found within GameData"
      printf '%s\n' "Path: ${gamedata[@]}"
      exit 1;
    fi

    # Blank line between files
    echo
done
