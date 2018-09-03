#!/bin/bash -eu

# Publish any versions of the docker image not yet pushed to jenkins/jenkins
# Arguments:
#   -n dry run, do not build or publish images
#   -d debug

set -eou pipefail

ARCHS=(arm arm64 s390x amd64)
QEMUARCHS=(arm aarch64 s390x x86_64)
QEMUVER="v2.9.1-1"
REGISTRY="jenkins"
IMAGE="jenkins-experimental"
BASEIMAGE=

get-manifest-tool() {
    if [[ ! -f manifest-tool ]]; then
        local version
        version=$(curl -s https://api.github.com/repos/estesp/manifest-tool/tags | jq -r '.[0].name')

        echo "Downloading manifest-tool"
        if ! curl -OLs "https://github.com/estesp/manifest-tool/releases/download/$version/manifest-tool-linux-amd64"; then
            echo "Error downloading manifest-tool"
            exit
        fi

        mv manifest-tool-linux-amd64 manifest-tool
        chmod +x manifest-tool
    fi
}

get-qemu-handlers() {
    if [[ ! $(find . -name "*qemu-*") ]]; then
        echo "Downloading Qemu handlers"
        for target_arch in ${QEMUARCHS[*]}; do
            if ! curl -OLs "https://github.com/multiarch/qemu-user-static/releases/download/$QEMUVER/x86_64_qemu-${target_arch}-static.tar.gz"; then
                echo "Error downloading Qemu handler"
                exit
            fi
            tar -xvf x86_64_qemu-"${target_arch}"-static.tar.gz
        done
        rm -f x86_64_qemu-*
    fi
}

set-base-image() {
    local variant=$1
    local arch=$2
    local dockerfile

    if [[ ! -z "$variant" ]]; then
        dockerfile="./multiarch/Dockerfile${variant}-${arch}"
    else
        dockerfile="./multiarch/Dockerfile-${arch}"
    fi

    if [[ "$variant" =~ alpine ]]; then
        /bin/cp -f multiarch/Dockerfile.alpine "$dockerfile"
    elif [[ "$variant" =~ slim ]]; then
        /bin/cp -f multiarch/Dockerfile.slim "$dockerfile"
    else
        /bin/cp -f multiarch/Dockerfile.debian "$dockerfile"
    fi

    # Parse architectures and variants
    if [[ $arch == amd64 ]]; then
        BASEIMAGE="openjdk:8-jdk"
    elif [[ $arch == arm ]]; then
        BASEIMAGE="arm32v7/openjdk:8-jdk"
    elif [[ $arch == arm64 ]]; then
        BASEIMAGE="arm64v8/openjdk:8-jdk"
    elif [[ $arch == s390x ]]; then
        BASEIMAGE="s390x/openjdk:8-jdk"
    fi

    if [[ $variant =~ alpine && $arch == arm ]]; then
        # The arm32v7 openjdk alpine variant doesn't seem to exist
        BASEIMAGE="arm32v6/openjdk:8-jdk-alpine"
    elif [[ $variant =~ alpine ]]; then
        BASEIMAGE="$BASEIMAGE-alpine"
    elif [[ $variant =~ slim ]]; then
        BASEIMAGE="$BASEIMAGE-slim"
    fi

    # Make the Dockerfile after we set the base image
    sed -i "s|BASEIMAGE|${BASEIMAGE}|g" "$dockerfile"

    if [[ "${arch}" == "amd64" ]]; then
        sed -i "/CROSS_BUILD_/d" "$dockerfile"
    else
        if [[ "${arch}" == "arm64" ]]; then
            sed -i "s|ARCH|aarch64|g" "$dockerfile"
        else
            sed -i "s|ARCH|${arch}|g" "$dockerfile"
        fi
        sed -i "s/CROSS_BUILD_//g" "$dockerfile"
    fi
}

sort-versions() {
    if [ "$(uname)" == 'Darwin' ]; then
        gsort --version-sort
    else
        sort --version-sort
    fi
}

# Try tagging with and without -f to support all versions of docker
docker-tag() {
    local from="$REGISTRY/$IMAGE:$1"
    local to="$2/$IMAGE:$3"
    local out

    docker pull "$from"
    if out=$(docker tag -f "$from" "$to" 2>&1); then
        echo "$out"
    else
        docker tag "$from" "$to"
    fi
}

login-token() {
    # could use jq .token
    curl -q -sSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:jmreicha/jenkins:pull" | grep -o '"token":"[^"]*"' | cut -d':' -f 2 | xargs echo
}

is-published() {
    local tag=$1
    local opts=""
    if [ "$debug" = true ]; then
        opts="-v"
    fi
    local http_code;
    http_code=$(curl $opts -q -fsL -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer $TOKEN" "https://index.docker.io/v2/jmreicha/jenkins/manifests/$tag")
    if [ "$http_code" -eq "404" ]; then
        false
    elif [ "$http_code" -eq "200" ]; then
        true
    else
        echo "Received unexpected http code from Docker hub: $http_code"
        exit 1
    fi
}

get-manifest() {
    local tag=$1
    local opts=""
    if [ "$debug" = true ]; then
        opts="-v"
    fi
    curl $opts -q -fsSL -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer $TOKEN" "https://index.docker.io/v2/jmreicha/jenkins/manifests/$tag"
}

get-digest() {
    local manifest
    manifest=$(get-manifest "$1")
    #get-manifest "$1" | jq .config.digest
    if [ "$debug" = true ]; then
        >&2 echo "DEBUG: Manifest for $1: $manifest"
    fi
    echo "$manifest" | grep -A 10 -o '"config".*' | grep digest | head -1 | cut -d':' -f 2,3 | xargs echo
}

get-latest-versions() {
    curl -q -fsSL https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/jenkins-war/maven-metadata.xml | grep '<version>.*</version>' | grep -E -o '[0-9]+(\.[0-9]+)+' | sort-versions | uniq | tail -n 1
}

# Make a list of platforms for manifest-tool to publish
parse-manifest-platforms() {
    local platforms=()
    for arch in ${ARCHS[*]}; do
        platforms+=("linux/$arch")
    done
    IFS=,;printf "%s" "${platforms[*]}"
}

publish() {
    local version=$1
    local variant=$2
    local tag="${version}${variant}"
    local sha
    build_opts=(--no-cache --pull)

    if [ "$dry_run" = true ]; then
        build_opts=()
    fi

    sha=$(curl -q -fsSL "https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/jenkins-war/${version}/jenkins-war-${version}.war.sha256" )

    for arch in ${ARCHS[*]}; do
        set-base-image "$variant" "$arch"

        docker build --file "multiarch/Dockerfile$variant-$arch" \
                     --build-arg "JENKINS_VERSION=$version" \
                     --build-arg "JENKINS_SHA=$sha" \
                     --tag "$REGISTRY/$IMAGE:${tag}-${arch}" \
                     "${build_opts[@]+"${build_opts[@]}"}" .

        # " line to fix syntax highlightning
        if [ ! "$dry_run" = true ]; then
            docker push "$REGISTRY/$IMAGE:${tag}-${arch}"
        fi
    done
}

tag-and-push() {
    local source=$1
    local target=$2
    local arch=$3
    local digest_source
    local digest_target

    if [ "$debug" = true ]; then
        >&2 echo "DEBUG: Getting digest for ${source}-${arch}"
    fi

    # if tag doesn't exist yet, ie. dry run
    if ! digest_source=$(get-digest "${source}-${arch}"); then
        echo "Unable to get source digest for ${source}-${arch} ${digest_source}"
        digest_source=""
    fi

    if [ "$debug" = true ]; then
        >&2 echo "DEBUG: Getting digest for ${target}-${arch}"
    fi
    if ! digest_target=$(get-digest "${target}-${arch}"); then
        echo "Unable to get target digest for ${target}-${arch} ${digest_target}"
        digest_target=""
    fi

    if [ "$digest_source" == "$digest_target" ] && [ -n "${digest_target}" ]; then
        echo "Images ${source}-${arch} [$digest_source] and ${target}-${arch} [$digest_target] are already the same, not updating tags"
    else
        echo "Creating tag ${target}-${arch} pointing to ${source}-${arch}"
        #docker-tag "${source}-${arch}" "jenkins" "${target}-${arch}"
        docker-tag "${source}-${arch}" "$REGISTRY" "${target}-${arch}"

        if [ ! "$dry_run" = true ]; then
            echo "Pushing $REGISTRY/$IMAGE:${target}-${arch}"
            docker push "$REGISTRY/$IMAGE:${target}-${arch}"
        else
            echo "Would push $REGISTRY/$IMAGE:${target}-${arch}"
        fi
    fi
}

publish-variant() {
    local version=$1
    local variant=$2

    for arch in ${ARCHS[*]}; do
        if [[ "$variant" =~ slim ]]; then
            tag-and-push "${version}${variant}" "slim" "${arch}"
        elif [[ "$variant" =~ alpine ]]; then
            tag-and-push "${version}${variant}" "alpine" "${arch}"
        fi
    done

    if [[ "$variant" =~ slim ]]; then
        push-manifest "slim" ""
    elif [[ "$variant" =~ alpine ]]; then
        push-manifest "alpine" ""
    fi
}

publish-latest() {
    local version=$1
    local variant=$2

    for arch in ${ARCHS[*]}; do
        # push latest (for master) or the name of the branch (for other branches)
        if [ -z "$variant" ]; then
            tag-and-push "${version}${variant}" "latest" "${arch}"
        fi
    done

    # Only push latest when there is no variant
    if [[ -z "$variant" ]]; then
        push-manifest "latest" ""
    fi
}

publish-lts() {
    local version=$1
    local variant=$2
    for arch in ${ARCHS[*]}; do
        tag-and-push "${version}${variant}" "lts${variant}" "${arch}"
    done
    push-manifest "lts" "${variant}"
}

push-manifest() {
    local version=$1
    local variant=$2

    ./manifest-tool push from-args \
        --platforms "$(parse-manifest-platforms)" \
        --template "$REGISTRY/$IMAGE:${version}${variant}-ARCH" \
        --target "$REGISTRY/$IMAGE:${version}${variant}"
}

cleanup() {
    echo "Cleaning up"
    rm -f manifest-tool
    rm -f qemu-*
    rm -rf ./multiarch/Dockerfile-*
}

# Process arguments

dry_run=false
debug=false
variant=""

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -n)
        dry_run=true
        ;;
        -d)
        debug=true
        ;;
        -v|--variant)
        variant="-"$2
        shift
        ;;
        *)
        echo "Unknown option: $key"
        return 1
        ;;
    esac
    shift
done


if [ "$dry_run" = true ]; then
    echo "Dry run, will not publish images"
fi

if [ "$debug" = true ]; then
    set -x
fi

get-manifest-tool
get-qemu-handlers

# Register binfmt_misc to run cross platform builds against non x86 architectures
docker run --rm --privileged multiarch/qemu-user-static:register --reset

TOKEN=$(login-token)

lts_version=""
version=""
for version in $(get-latest-versions); do
    if is-published "$version$variant"; then
        echo "Tag is already published: $version$variant"
    else
        echo "Publishing version: $version$variant"
        publish "$version" "$variant"
    fi

    # Update lts tag
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        lts_version="${version}"
    fi
done

push-manifest "${version}" "${variant}"

publish-variant "${version}" "${variant}"

publish-latest "${version}" "${variant}"

if [ -n "${lts_version}" ]; then
    publish-lts "${lts_version}" "${variant}"
fi

cleanup
