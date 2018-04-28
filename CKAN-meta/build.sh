#!/bin/bash
set -e

# Locations of CKAN and validation.
LATEST_CKAN_URL="http://ckan-travis.s3.amazonaws.com/ckan.exe"
LATEST_CKAN_VALIDATE="https://raw.githubusercontent.com/KSP-CKAN/CKAN/master/bin/ckan-validate.py"
LATEST_CKAN_SCHEMA="https://raw.githubusercontent.com/KSP-CKAN/CKAN/master/CKAN.schema"
LATEST_CKAN_META="https://github.com/KSP-CKAN/CKAN-meta/archive/master.tar.gz"

# Third party utilities.
JQ_PATH="jq"

# Return codes.
EXIT_OK=0

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

    # Link to the shared downloads cache.
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

    # Extract the metadata into a new folder.
    rm -rf CKAN-meta-master
    tar -xzf metadata.tar.gz

    # Copy in the files to inject.
    for f in "${OTHER_FILES[@]}"
    do
        echo "Injecting $f"
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

# Find the changes to test.
echo "Finding changes to test..."

if [ -n "$ghprbActualCommit" ]
then
    echo "Commit hash: $ghprbActualCommit"
    export COMMIT_CHANGES="`git diff --diff-filter=AM --name-only --stat origin/master...HEAD`"
else
    echo "No commit provided, skipping further tests."
    exit $EXIT_OK
fi

# Make sure we start from a clean slate.
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

# CKAN Validation files
wget --quiet $LATEST_CKAN_VALIDATE -O ckan-validate.py
wget --quiet $LATEST_CKAN_SCHEMA -O CKAN.schema
chmod a+x --verbose ckan-validate.py

# fetch latest ckan.exe
echo "Fetching latest ckan.exe"
wget --quiet $LATEST_CKAN_URL -O ckan.exe
mono ckan.exe version

# Fetch the latest metadata.
echo "Fetching latest metadata"
wget --quiet $LATEST_CKAN_META -O metadata.tar.gz

# Create folders.
# TODO: Point to cache folder here instead if possible.
if [ ! -d "downloads_cache/" ]
then
    mkdir --verbose downloads_cache
fi

for ckan in $COMMIT_CHANGES
do
    # set -e doesn't apply inside an if block CKAN#1273
    if [ "$ckan" = "build.sh" ]
    then
        echo "Lets try not to validate our build script with CKAN"
        continue
    elif [[ "$ckan" = "builds.json" ]]
    then
        echo "Skipping remote build map $ckan"
        continue
    fi

    ./ckan-validate.py $ckan
    echo ----------------------------------------------
    cat $ckan | python -m json.tool
    echo ----------------------------------------------

    if [[ "$ckan" =~ .frozen$ ]]
    then
        echo "Skipping install of frozen module '$ckan'"
        continue
    fi

    # Extract identifier and KSP version.
    CURRENT_IDENTIFIER=$($JQ_PATH --raw-output '.identifier' $ckan)
    CURRENT_KSP_VERSION=$(ckan_max_real_version "$ckan")

    # TODO: Someday we could loop over ( $(ckan_matching_versions "$ckan") ) to find
    #       working versions less than the maximum, if the maximum doesn't work.
    #       (E.g., a dependency isn't updated yet.)

    echo "Extracted $CURRENT_IDENTIFIER as identifier."
    echo "Extracted $CURRENT_KSP_VERSION as KSP version."

    # Get a list of all the OTHER files.
    OTHER_FILES=()

    for o in $COMMIT_CHANGES
    do
        if [ "$ckan" != "$o" ] && [ "$ckan" != "build.sh" ]
        then
            OTHER_FILES+=($o)
        fi
    done
    echo "Other files: ${OTHER_FILES[*]}"

    # Inject into metadata.
    inject_metadata $OTHER_FILES

    # Create a dummy KSP install.
    create_dummy_ksp $CURRENT_KSP_VERSION $ghprbActualCommit

    echo "Running ckan update"
    mono ckan.exe update

    echo Running ckan install -c $ckan
    mono --debug ckan.exe install -c $ckan --headless

    # Show all installed mods.
    echo "Installed mods:"
    mono --debug ckan.exe list --porcelain

    # Check the installed files for this .ckan file.
    mono ckan.exe show $CURRENT_IDENTIFIER

    # Cleanup.
    mono ckan.exe ksp forget $KSP_NAME

    # Blank line between files
    echo
done
