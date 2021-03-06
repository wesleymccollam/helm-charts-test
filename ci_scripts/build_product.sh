#!/usr/bin/env bash
#
# Ping Identity DevOps - CI scripts
#
# This script builds the product images
#
test "${VERBOSE}" = "true" && set -x

#
# Usage printing function
#
usage() {
    test -n "${*}" && echo "${*}"
    cat << END_USAGE
Usage: ${0} {options}
    where {options} include:
    -p, --product
        The name of the product for which to build a docker image
    -s, --shim
        the name of the operating system for which to build a docker image
    -j, --jvm
        the id of the jvm to build
    -v, --version
        the version of the product for which to build a docker image
        this setting overrides the versions in the version file of the target product
    --verbose-build
        verbose docker build not using docker buildkit
    --dry-run
        does everything except actually call the docker command and prints it instead
    --help
        Display general usage information
END_USAGE
    exit 99
}

# export PING_IDENTITY_SNAPSHOT=--snapshot to trigger snapshot build
DOCKER_BUILDKIT=1
noCache=${DOCKER_BUILD_CACHE}
while ! test -z "${1}"; do
    case "${1}" in
        -p | --product)
            shift
            test -z "${1}" && usage "You must provide a product to build"
            productToBuild="${1}"
            ;;
        -s | --shim)
            shift
            test -z "${1}" && usage "You must provide an OS Shim"
            shimsToBuild="${shimsToBuild:+${shimsToBuild} }${1}"
            ;;
        -j | --jvm)
            shift
            test -z "${1}" && usage "You must provide a JVM id"
            jvmsToBuild="${jvmsToBuild:+${jvmsToBuild} }${1}"
            ;;
        -v | --version)
            shift
            test -z "${1}" && usage "You must provide a version to build"
            versionsToBuild="${versionsToBuild:+${versionsToBuild} }${1}"
            ;;
        --no-cache)
            noCache="--no-cache"
            ;;
        --verbose-build)
            progress="--progress plain"
            ;;
        --dry-run)
            dryRun="echo"
            ;;
        --fail-fast)
            failFast=true
            ;;
        --snapshot)
            PING_IDENTITY_SNAPSHOT="--snapshot"
            export PING_IDENTITY_SNAPSHOT
            ;;
        --help)
            usage
            ;;
        *)
            usage "Unrecognized option"
            ;;
    esac
    shift
done

if test -z "${productToBuild}"; then
    echo "You must specify a product name to build, for example pingfederate or pingcentral"
    usage
fi

if test -z "${CI_COMMIT_REF_NAME}"; then
    CI_PROJECT_DIR="$(
        cd "$(dirname "${0}")/.." || exit 97
        pwd
    )"
    test -z "${CI_PROJECT_DIR}" && echo "Invalid call to dirname ${0}" && exit 97
fi
CI_SCRIPTS_DIR="${CI_PROJECT_DIR:-.}/ci_scripts"
# shellcheck source=./ci_tools.lib.sh
. "${CI_SCRIPTS_DIR}/ci_tools.lib.sh"

# Handle snapshot pipeline logic and requirements
if test -n "${PING_IDENTITY_SNAPSHOT}"; then
    if test -z "${PING_IDENTITY_GITLAB_TOKEN}"; then
        echo "the PING_IDENTITY_GITLAB_TOKEN must be provided for snapshot"
        exit 96
    fi
    case "${productToBuild}" in
        pingaccess | pingcentral)
            snapshot_url="${SNAPSHOT_ARTIFACTORY_URL}"
            ;;
        pingfederate)
            snapshot_url="${SNAPSHOT_BLD_FED_URL}"
            ;;
        pingdelegator)
            snapshot_url="${SNAPSHOT_DELEGATOR_URL}"
            ;;
        pingauthorize | pingauthorizepap | pingdataconsole | pingdatasync | pingdatagovernance | pingdatagovernancepap | pingdirectory | pingdirectoryproxy)
            snapshot_url="${SNAPSHOT_NEXUS_URL}"
            ;;
        pingdownloader)
            #Build pingdownloader normally in a snapshot pipeline as there is no "snapshot bits" for downloader.
            unset PING_IDENTITY_SNAPSHOT
            ;;
        *)
            echo "Snapshot not supported"
            exit 0
            ;;
    esac
fi

if test -z "${versionsToBuild}"; then
    if test -n "${PING_IDENTITY_SNAPSHOT}"; then
        versionsToBuild=$(_getLatestSnapshotVersionForProduct "${productToBuild}")
        latestVersion=$(_getLatestVersionForProduct "${productToBuild}")
        shimsToBuild=$(_getDefaultShimForProductVersion "${productToBuild}" "${latestVersion}")
        jvmsToBuild="al11"
    else
        versionsToBuild=$(_getAllVersionsToBuildForProduct "${productToBuild}")
    fi
fi

# result table header
_resultsFile="/tmp/$$.results"
_reportPattern='%-23s| %-20s| %-20s| %-10s| %10s| %7s'

# Add header to results file
printf ' %-24s| %-20s| %-20s| %-10s| %10s| %7s\n' "PRODUCT" "VERSION" "SHIM" "JDK" "DURATION" "RESULT" > ${_resultsFile}
_totalStart=$(date '+%s')

_date=$(date +"%y%m%d")

returnCode=0
for _version in ${versionsToBuild}; do
    # if the list of shims was not provided as arguments, get the list from the versions file
    if test -z "${shimsToBuild}"; then
        _shimsToBuild=$(_getShimsToBuildForProductVersion "${productToBuild}" "${_version}")
    else
        _shimsToBuild=${shimsToBuild}
    fi

    _buildVersion="${_version}"

    if test -f "${CI_PROJECT_DIR}/${productToBuild}/Product-staging"; then
        # Check if a file named product.zip is present within the product directory.
        # If so, use a different buildVersion to differentiate the build from regular
        # builds that use the pingdownloader. It is up to the product specific
        # Product-staging file to copy the product.zip into the build container.
        _overrideProductFile="${productToBuild}/tmp/product.zip"
        if test -f "${_overrideProductFile}"; then
            banner "Using file system location ${_overrideProductFile}"
            _buildVersion="${_version}-fsoverride"
        fi
        _start=$(date '+%s')
        # In the snapshot pipeline, provide the latest version in the product's version.json
        # for the dependency check, as the snapshot version is not present in the versions.json
        if test -n "${PING_IDENTITY_SNAPSHOT}"; then
            dependency_check_version="${latestVersion}"
        else
            dependency_check_version="${_version}"
        fi
        _dependencies=$(_getDependenciesForProductVersion "${productToBuild}" "${dependency_check_version}")
        _image="${FOUNDATION_REGISTRY}/${productToBuild}:staging-${_buildVersion}-${CI_TAG}"
        # build the staging for each product so we don't need to download and stage the product each time
        # Word-split is expected behavior for $progress and $_dependencies. Disable shellcheck.
        # shellcheck disable=SC2086
        DOCKER_BUILDKIT=${DOCKER_BUILDKIT} docker image build \
            -f "${CI_PROJECT_DIR}/${productToBuild}/Product-staging" \
            -t "${_image}" \
            ${progress} ${noCache} \
            --build-arg FOUNDATION_REGISTRY="${FOUNDATION_REGISTRY}" \
            --build-arg DEPS="${DEPS_REGISTRY}" \
            --build-arg GIT_TAG="${CI_TAG}" \
            --build-arg ARCH="${ARCH}" \
            --build-arg DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER}" \
            --build-arg DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY}" \
            --build-arg PRODUCT="${productToBuild}" \
            --build-arg VERSION="${_buildVersion}" \
            ${PING_IDENTITY_SNAPSHOT:+--build-arg PING_IDENTITY_SNAPSHOT="${PING_IDENTITY_SNAPSHOT}"} \
            ${PING_IDENTITY_SNAPSHOT:+--build-arg PING_IDENTITY_GITLAB_TOKEN="${PING_IDENTITY_GITLAB_TOKEN}"} \
            ${PING_IDENTITY_SNAPSHOT:+--build-arg INTERNAL_GITLAB_URL="${INTERNAL_GITLAB_URL}"} \
            ${PING_IDENTITY_SNAPSHOT:+--build-arg SNAPSHOT_URL="${snapshot_url}"} \
            ${VERBOSE:+--build-arg VERBOSE="true"} \
            ${_dependencies} \
            "${CI_PROJECT_DIR}/${productToBuild}"
        _returnCode=${?}
        _stop=$(date '+%s')
        _duration=$((_stop - _start))
        if test ${_returnCode} -ne 0; then
            returnCode=${_returnCode}
            _result=FAIL
            if test -n "${failFast}"; then
                banner "Build break for ${productToBuild} staging for version ${_buildVersion}"
                exit ${_returnCode}
            fi
        else
            _result=PASS
        fi
        append_status "${_resultsFile}" "${_result}" "${_reportPattern}" "${productToBuild}" "${_buildVersion}" "Staging" "N/A" "${_duration}" "${_result}"
        imagesToClean="${imagesToClean} ${_image}"
    fi

    # iterate over the shims (default to alpine)
    for _shim in ${_shimsToBuild:-alpine}; do
        _start=$(date '+%s')
        _shimLongTag=$(_getLongTag "${_shim}")
        if test -z "${jvmsToBuild}"; then
            _jvmsToBuild=$(_getJVMsToBuildForProductVersionShim "${productToBuild}" "${_version}" "${_shim}")
        else
            _jvmsToBuild=${jvmsToBuild}
        fi

        for _jvm in ${_jvmsToBuild}; do
            fullTag="${_buildVersion}-${_shimLongTag}-${_jvm}-${CI_TAG}-${ARCH}"
            imageVersion="${productToBuild}-${_shimLongTag}-${_jvm}-${_buildVersion}-${_date}-${GIT_REV_SHORT}"
            licenseVersion="$(_getLicenseVersion "${_version}")"

            _image="${FOUNDATION_REGISTRY}/${productToBuild}:${fullTag}"
            # Word-split is expected behavior for $progress. Disable shellcheck.
            # shellcheck disable=SC2086
            DOCKER_BUILDKIT=${DOCKER_BUILDKIT} docker image build \
                -t "${_image}" \
                ${progress} ${noCache} \
                --build-arg PRODUCT="${productToBuild}" \
                --build-arg REGISTRY="${FOUNDATION_REGISTRY}" \
                --build-arg DEPS="${DEPS_REGISTRY}" \
                --build-arg GIT_TAG="${CI_TAG}" \
                --build-arg JVM="${_jvm}" \
                --build-arg ARCH="${ARCH}" \
                --build-arg SHIM="${_shim}" \
                --build-arg SHIM_TAG="${_shimLongTag}" \
                --build-arg VERSION="${_buildVersion}" \
                --build-arg IMAGE_VERSION="${imageVersion}" \
                --build-arg IMAGE_GIT_REV="${GIT_REV_LONG}" \
                --build-arg LICENSE_VERSION="${licenseVersion}" \
                ${VERBOSE:+--build-arg VERBOSE="true"} \
                "${CI_PROJECT_DIR}/${productToBuild}"

            _returnCode=${?}
            _stop=$(date '+%s')
            _duration=$((_stop - _start))
            if test ${_returnCode} -ne 0; then
                returnCode=${_returnCode}
                _result=FAIL
                if test -n "${failFast}"; then
                    banner "Build break for ${productToBuild} on ${_shim} for version ${_buildVersion}"
                    exit ${_returnCode}
                fi
            else
                _result=PASS
                if test -z "${IS_LOCAL_BUILD}"; then
                    ${dryRun} docker push "${_image}"
                    if test -n "${PING_IDENTITY_SNAPSHOT}"; then
                        ${dryRun} docker tag "${_image}" "${FOUNDATION_REGISTRY}/${productToBuild}:latest-${ARCH}-$(date "+%m%d%Y")"
                        ${dryRun} docker push "${FOUNDATION_REGISTRY}/${productToBuild}:latest-${ARCH}-$(date "+%m%d%Y")"
                        ${dryRun} docker image rm -f "${FOUNDATION_REGISTRY}/${productToBuild}:latest-${ARCH}-$(date "+%m%d%Y")"
                        ${dryRun} docker tag "${_image}" "${FOUNDATION_REGISTRY}/${productToBuild}:${_version}-${ARCH}-$(date "+%m%d%Y")"
                        ${dryRun} docker push "${FOUNDATION_REGISTRY}/${productToBuild}:${_version}-${ARCH}-$(date "+%m%d%Y")"
                        ${dryRun} docker image rm -f "${FOUNDATION_REGISTRY}/${productToBuild}:${_version}-${ARCH}-$(date "+%m%d%Y")"
                        if test "${ARCH}" = "x86_64"; then
                            ${dryRun} docker tag "${_image}" "${FOUNDATION_REGISTRY}/${productToBuild}:latest"
                            ${dryRun} docker push "${FOUNDATION_REGISTRY}/${productToBuild}:latest"
                            ${dryRun} docker image rm -f "${FOUNDATION_REGISTRY}/${productToBuild}:latest"
                        fi
                    fi
                    ${dryRun} docker image rm -f "${_image}"
                fi
            fi
            append_status "${_resultsFile}" "${_result}" "${_reportPattern}" "${productToBuild}" "${_buildVersion}" "${_shim}" "${_jvm}" "${_duration}" "${_result}"
        done
    done
done

# leave the runner without clutter
if test -z "${IS_LOCAL_BUILD}"; then
    imagesToClean=$(docker image ls -qf "reference=*/*/*${CI_TAG}*" | sort | uniq)
    # Word-split is expected behavior for $imagesToClean. Disable shellcheck.
    # shellcheck disable=SC2086
    test -n "${imagesToClean}" && ${dryRun} docker image rm -f ${imagesToClean}
    imagesToClean=$(docker image ls -qf "dangling=true")
    # Word-split is expected behavior for $imagesToClean. Disable shellcheck.
    # shellcheck disable=SC2086
    test -n "${imagesToClean}" && ${dryRun} docker image rm -f ${imagesToClean}
fi

cat ${_resultsFile}
rm ${_resultsFile}
_totalStop=$(date '+%s')
_totalDuration=$((_totalStop - _totalStart))
echo "Total duration: ${_totalDuration}s"
exit ${returnCode}
