#!/bin/bash

set -e

# We want our globs to be null
shopt -s nullglob

# Locations of CKAN and NetKAN.
LATEST_CKAN_URL="http://ckan-travis.s3.amazonaws.com/ckan.exe"
LATEST_NETKAN_URL="http://ckan-travis.s3.amazonaws.com/netkan.exe"
LATEST_CKAN_META="https://github.com/KSP-CKAN/CKAN-meta/archive/master.tar.gz"

# Third party utilities.
JQ_PATH="jq"

# Return codes.
EXIT_OK=0
EXIT_FAILED_JSON_VALIDATION=2
EXIT_FAILED_ROOT_NETKANS=3
EXIT_FAILED_DUPLICATE_IDENTIFIERS=4
EXIT_FAILED_NO_GAME_VERSION=5

# Allow us to specify a commit id as the first argument
if [ -n "$1" ]
then
    echo "Using CLI argument of $1"
    ghprbActualCommit="$1"
fi

# ------------------------------------------------
# Function for creating dummy KSP directories to
# test on.
# Usage: create_dummy_ksp name main_ver ver2 ver3 ...
# ------------------------------------------------
create_dummy_ksp() {
    KSP_NAME="$1"
    shift
    KSP_VERSION="$1"
    shift
    COMPAT_VERSIONS=("$@")

    echo "Creating a dummy KSP '$KSP_VERSION' install"

    # Remove any existing KSP dummy install.
    if [[ -d dummy_ksp/ ]]
    then
        rm -rf dummy_ksp
    fi

    # Reset the Mono registry.
    if [[ "$USER" = "jenkins" ]]
    then
        REGISTRY_FILE="$HOME"/.mono/registry/CurrentUser/software/ckan/values.xml
        if [[ -r "$REGISTRY_FILE" ]]
        then
            rm -f --verbose "$REGISTRY_FILE"
        fi
    fi

    # Create dummy install.
    # The DLCs are simulated depending on the version.
    if versions_less_or_equal "1.7.1" "$KSP_VERSION"
    then
        mono ckan.exe ksp fake --set-default --headless "$KSP_NAME" dummy_ksp "$KSP_VERSION" --MakingHistory 1.1.0 --BreakingGround 1.0.0
    elif versions_less_or_equal "1.4.1" "$KSP_VERSION"
    then
        mono ckan.exe ksp fake --set-default --headless "$KSP_NAME" dummy_ksp "$KSP_VERSION" --MakingHistory 1.1.0
    else
        mono ckan.exe ksp fake --set-default --headless "$KSP_NAME" dummy_ksp "$KSP_VERSION"
    fi

    # Add other compatible versions.
    for compVer in "${COMPAT_VERSIONS[@]}"
    do
        mono ckan.exe compat add "$compVer"
    done

    # Link to the netkan downloads cache as a legacy cache.
    ln -s --verbose ../../downloads_cache/ dummy_ksp/CKAN/downloads

    # Copy in resources.
    cp --verbose ckan.exe dummy_ksp/ckan.exe

    # Point to the local metadata instead of GitHub.
    mono ckan.exe repo add local "file://`pwd`/master.tar.gz"
    mono ckan.exe repo remove default
}

# ------------------------------------------------
# Function for injecting metadata into a tar.gz
# archive. Assumes metadata.tar.gz to be present.
# ------------------------------------------------
inject_metadata() {
    # Check input, requires at least 1 argument.
    if (( $# < 1 ))
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
    for f in "$@"
    do
        echo "Injecting: $f"

        # Find proper destination path
        ID=$($JQ_PATH --raw-output '.identifier' "$f")
        DEST="CKAN-meta-master/$ID/$(basename $f)"

        # Print a diff if the generated file already exists
        if [[ -e $DEST ]]
        then
            echo "Changes:"
            diff -su --label Current "$DEST" --label New "$f" || true
            echo
        fi

        mkdir -p --verbose $(dirname "$DEST")
        cp --verbose "$f" "$DEST"
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
    VER1="$1"
    VER2="$2"

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
    MIN="$1"
    MAX="$2"

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
    MIN=$("$JQ_PATH" --raw-output 'if .ksp_version then .ksp_version elif .ksp_version_min then .ksp_version_min else "" end' "$CKAN")
    MAX=$("$JQ_PATH" --raw-output 'if .ksp_version then .ksp_version elif .ksp_version_max then .ksp_version_max else "" end' "$CKAN")

    matching_versions "$MIN" "$MAX"
}

# ------------------------------------------------
# Print versions indicated in pull request body text.
# Input comes from the Jenkins ghprbPullLongDescription environment variable.
# We look for a string that looks like:
#   ckan compat add 1.4 1.5 1.6
# And we print out the version numbers that we find.
# ------------------------------------------------
versions_from_description() {
    if [[ $ghprbPullLongDescription =~ 'ckan compat add'((' '[0-9.]+)+) ]]
    then
        # Unquoted so each version is a separate string
        echo ${BASH_REMATCH[1]}
    fi
}

declare -a VERSIONS
VERSIONS=( $(get_versions) )

# ------------------------------------------------
# Main entry point.
# ------------------------------------------------

if [ -n "$ghprbActualCommit" ]
then
    echo "Commit hash: $ghprbActualCommit"
    export COMMIT_CHANGES="`git diff --diff-filter=AMR --name-only --stat origin/master...HEAD`"
else
    echo "No commit provided, skipping further tests."
    exit "$EXIT_OK"
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
    exit "$EXIT_FAILED_ROOT_NETKANS"
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
    jsonlint -s -v "$f"

    if [ $? -ne 0 ]
    then
        echo "Failed to validate $f"
        exit "$EXIT_FAILED_JSON_VALIDATION"
    fi
done
echo ""

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
wget --quiet "$LATEST_CKAN_URL" -O ckan.exe
mono ckan.exe version

echo "Fetching latest netkan.exe"
wget --quiet "$LATEST_NETKAN_URL" -O netkan.exe
mono netkan.exe --version

# Fetch the latest metadata.
echo "Fetching latest metadata"
wget --quiet "$LATEST_CKAN_META" -O metadata.tar.gz

# Determine KSP dummy name.
if [ -z $ghprbActualCommit ]
then
    KSP_NAME=dummy
else
    KSP_NAME="$ghprbActualCommit"
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
            exit "$EXIT_FAILED_DUPLICATE_IDENTIFIERS"
        fi

        echo "Running NetKAN for $f"
        mono netkan.exe "$f" --cachedir="downloads_cache" --outputdir="built" $NETKAN_OPTIONS
    else
        echo "Let's try not to build '$f' with netkan"
    fi
done

# Get array of all the files
OTHER_FILES=(built/*.ckan)

# Check if we found any
if (( ${#OTHER_FILES[@]} > 0 ))
then
    # Inject into metadata
    inject_metadata "${OTHER_FILES[@]}"
fi

# Test all the built files.
for ckan in built/*.ckan
do
    if [ ! -e "$ckan" ]
    then
        echo "No ckan files to test"
        continue
    fi

    echo "Checking $ckan"
    echo ""
    echo "----------------------------------------------"
    cat "$ckan"
    echo "----------------------------------------------"
    echo ""

    # Extract identifier and KSP version.
    CURRENT_IDENTIFIER=$($JQ_PATH --raw-output '.identifier' "$ckan")
    KSP_VERSIONS=( $(ckan_matching_versions "$ckan") $(versions_from_description) )

    if (( ${#KSP_VERSIONS[@]} < 1 ))
    then
        echo "$ckan doesn't match any valid game version"
        exit "$EXIT_FAILED_NO_GAME_VERSION"
    fi

    echo "Extracted $CURRENT_IDENTIFIER as identifier."
    echo "Extracted ${KSP_VERSIONS[*]} as KSP versions."

    # Create a dummy KSP install.
    create_dummy_ksp "$KSP_NAME" "${KSP_VERSIONS[@]}"

    echo "Running ckan update"
    mono ckan.exe update

    echo "Running ckan install -c $ckan"
    mono ckan.exe install -c "$ckan" --headless

    # Print list of installed mods.
    mono ckan.exe list --porcelain

    # Check the installed files for this .ckan file.
    mono ckan.exe show "$CURRENT_IDENTIFIER"

    # Cleanup.
    mono ckan.exe ksp forget "$KSP_NAME"

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
