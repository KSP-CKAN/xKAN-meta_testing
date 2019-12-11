#!/bin/bash

set -e

# Locations of CKAN and NetKAN.
LATEST_CKAN_URL="http://ckan-travis.s3.amazonaws.com/ckan.exe"
LATEST_NETKAN_URL="http://ckan-travis.s3.amazonaws.com/netkan.exe"
LATEST_CKAN_META="https://github.com/KSP-CKAN/CKAN-meta/archive/master.tar.gz"

# Third party utilities.
JQ_PATH="jq"

# Return codes.
EXIT_OK=0
EXIT_NETKAN_VALIDATION_FAILED=2
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

# Find the changes to test.
echo "Finding changes to test..."

if [[ -n "$ghprbActualCommit" ]]
then
    echo "Commit hash: $ghprbActualCommit"
    export COMMIT_CHANGES="`git diff --diff-filter=AMR --name-only --stat origin/master...HEAD`"
else
    echo "No commit provided, skipping further tests."
    exit "$EXIT_OK"
fi

# Make sure we start from a clean slate.
if [[ -d "downloads_cache/" ]]
then
    rm -rf --verbose downloads_cache
fi

if [[ -e "master.tar.gz" ]]
then
    rm -f --verbose master.tar.gz
fi

if [[ -e "metadata.tar.gz" ]]
then
    rm -f --verbose metadata.tar.gz
fi

# fetch latest ckan.exe
echo "Fetching latest ckan.exe"
wget --quiet "$LATEST_CKAN_URL" -O ckan.exe
mono ckan.exe version

echo "Fetching latest netkan.exe"
wget --quiet "$LATEST_NETKAN_URL" -O netkan.exe
mono netkan.exe --version

# Fetch the latest metadata.
echo "Fetching latest metadata"
wget --quiet "$LATEST_CKAN_META" -O metadata.tar.gz

# Create folders.
# TODO: Point to cache folder here instead if possible.
if [ ! -d "downloads_cache/" ]
then
    mkdir --verbose downloads_cache
fi

# Get all the files
OTHER_FILES=()
for o in $COMMIT_CHANGES
do
    if [[ "$o" =~ \.ckan$ ]]
    then
        OTHER_FILES+=($o)
    fi
done
echo "Files: ${OTHER_FILES[*]}"

# Check if we found any
if (( ${#OTHER_FILES[@]} > 0 ))
then
    # Inject into metadata
    inject_metadata "${OTHER_FILES[@]}"
fi

for ckan in $COMMIT_CHANGES
do
    # set -e doesn't apply inside an if block CKAN#1273
    if ! [[ $ckan =~ \.ckan$ ]]
    then
        echo "Skipping non-module '$ckan'"
        continue
    fi

    echo "Validating metadata: '$ckan'"
    # Note: Additional NETKAN_OPTIONS may be set on jenkins jobs
    mono netkan.exe --validate-ckan "$ckan" $NETKAN_OPTIONS

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
    create_dummy_ksp "$ghprbActualCommit" "${KSP_VERSIONS[@]}"

    # Get or restore fresh registry
    if [[ ! -e registry.json ]]
    then
        echo "Running ckan update"
        mono ckan.exe update
        echo "Saving fresh registry file"
        cp --verbose dummy_ksp/CKAN/registry.json .
    else
        echo "Restoring saved registry file"
        cp --verbose registry.json dummy_ksp/CKAN
    fi

    echo Running ckan install -c "$ckan"
    mono ckan.exe prompt --headless <<EOCKAN
install -c $ckan --headless
list --porcelain
show $CURRENT_IDENTIFIER
ksp forget $KSP_NAME
EOCKAN

    # Blank line between files
    echo
done
