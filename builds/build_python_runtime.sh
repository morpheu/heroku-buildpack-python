#!/usr/bin/env bash

set -euo pipefail

PYTHON_VERSION="${1:?"Error: The Python version to build must be specified as the first argument."}"
PYTHON_MAJOR_VERSION="${PYTHON_VERSION%.*}"

INSTALL_DIR="/app/.heroku/python"
SRC_DIR="/tmp/src"
ARCHIVES_DIR="/tmp/upload/${STACK}/runtimes"

case "${STACK}" in
  heroku-22)
    SUPPORTED_PYTHON_VERSIONS=(
      "3.9"
      "3.10"
      "3.11"
    )
    ;;
  heroku-20)
    SUPPORTED_PYTHON_VERSIONS=(
      "2.7"
      "3.4"
      "3.5"
      "3.6"
      "3.7"
      "3.8"
      "3.9"
      "3.10"
      "3.11"
    )
    ;;
  *)
    echo "Error: Unsupported stack '${STACK}'!" >&2
    exit 1
    ;;
esac

if [[ ! " ${SUPPORTED_PYTHON_VERSIONS[*]} " == *" ${PYTHON_MAJOR_VERSION} "* ]]; then
  echo "Error: Python ${PYTHON_MAJOR_VERSION} is not supported on ${STACK}!" >&2
  exit 1
fi

echo "Building Python ${PYTHON_VERSION} for ${STACK}..."

SOURCE_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
SIGNATURE_URL="${SOURCE_URL}.asc"

set -o xtrace

mkdir -p "${SRC_DIR}" "${INSTALL_DIR}" "${ARCHIVES_DIR}"

curl --fail --retry 3 --retry-connrefused --connect-timeout 10 --max-time 60 -o python.tgz "${SOURCE_URL}"
curl --fail --retry 3 --retry-connrefused --connect-timeout 10 --max-time 60 -o python.tgz.asc "${SIGNATURE_URL}"

tar --extract --file python.tgz --strip-components=1 --directory "${SRC_DIR}"
cd "${SRC_DIR}"

# Aim to keep this roughly consistent with the options used in the Python Docker images,
# for maximum compatibility / most battle-tested build configuration:
# https://github.com/docker-library/python
CONFIGURE_OPTS=(
  # Support loadable extensions in the `_sqlite` extension module.
  # no 2.7 "--enable-loadable-sqlite-extensions"
  # Make autoconf's configure option validation more strict.
  "--enable-option-checking=fatal"
  # Install Python into `/app/.heroku/python` rather than the default of `/usr/local`.
  "--prefix=${INSTALL_DIR}"
  # Skip running `ensurepip` as part of install, since the buildpack installs a curated
  # version of pip itself (which ensures it's consistent across Python patch releases).
  "--with-ensurepip=no"
  # Build the `pyexpat` module using the `expat` library in the stack image (which will
  # automatically receive security updates), rather than CPython's vendored version.
  "--with-system-expat"
)

if [[ "${PYTHON_MAJOR_VERSION}" != "3.7" ]]; then
  CONFIGURE_OPTS+=(
    # Python 3.7 and older run the whole test suite for PGO, which takes
    # much too long. Whilst this can be overridden via `PROFILE_TASK`, we
    # prefer to change as few of the upstream build options as possible.
    # As such, PGO is only enabled for Python 3.8+.
  )
fi

if [[ "${PYTHON_MAJOR_VERSION}" == "2.7" ]]; then
  CONFIGURE_OPTS+=(
    "--enable-unicode=ucs4"
  )
fi

if [[ "${PYTHON_MAJOR_VERSION}" == "3.11" ]]; then
  CONFIGURE_OPTS+=(
    # Skip building the test modules, since we remove them after the build anyway.
    # This feature was added in Python 3.10+, however it wasn't until Python 3.11
    # that compatibility issues between it and PGO were fixed:
    # https://github.com/python/cpython/pull/29315
    # TODO: See if a backport of that fix would be accepted to Python 3.10.
    "--disable-test-modules"
  )
fi

./configure "${CONFIGURE_OPTS[@]}"

# Using LDFLAGS we instruct the linker to omit all symbol information from the final binary
# and shared libraries, to reduce the size of the build. We have to use `--strip-all` and
# not `--strip-unneeded` since `ld` only understands the former (unlike the `strip` command),
# however it's safe to use since these options don't apply to static libraries.
make -j "$(nproc)" LDFLAGS='-Wl,--strip-all'
make install

if [[ "${PYTHON_MAJOR_VERSION}" == 3.[7-9] ]]; then
  # On older versions of Python we're still building the static library, which has to be
  # manually stripped since the linker stripping enabled in LDFLAGS doesn't cover them.
  # We're using `--strip-unneeded` since `--strip-all` would remove the `.symtab` section
  # that is required for static libraries to be able to be linked.
  # `find` is used since there are multiple copies of the static library in version-specific
  # locations, eg:
  #   - `lib/libpython3.9.a`
  #   - `lib/python3.9/config-3.9-x86_64-linux-gnu/libpython3.9.a`
  find "${INSTALL_DIR}" -type f -name '*.a' -print -exec strip --strip-unneeded '{}' +
fi

# Remove unneeded test directories, similar to the official Docker Python images:
# https://github.com/docker-library/python
# This is a no-op on Python 3.11+, since --disable-test-modules will have prevented
# the test files from having been built in the first place.
find "${INSTALL_DIR}" -depth -type d -a \( -name 'test' -o -name 'tests' -o -name 'idle_test' \) -print -exec rm -rf '{}' +

# The `make install` step automatically generates `.pyc` files for the stdlib, however:
# - It generates these using the default `timestamp` invalidation mode, which does
#   not work well with the CNB file timestamp normalisation behaviour. As such, we
#   must use one of the hash-based invalidation modes to prevent the `.pyc`s from
#   always being treated as outdated and so being regenerated at application boot.
# - It generates `.pyc`s for all three optimisation levels (standard, -O and -OO),
#   when the vast majority of apps only use the standard mode. As such, we can skip
#   regenerating/shipping those `.opt-{1,2}.pyc` files, reducing build output by 18MB.
#
# We use the `unchecked-hash` mode rather than `checked-hash` since it improves app startup
# times by ~5%, and is only an issue if manual edits are made to the stdlib, which is not
# something we support.
#
# See:
# https://docs.python.org/3/reference/import.html#cached-bytecode-invalidation
# https://docs.python.org/3/library/compileall.html
# https://peps.python.org/pep-0488/
# https://peps.python.org/pep-0552/
find "${INSTALL_DIR}" -depth -type f -name "*.pyc" -delete
# We use the Python binary from the original build output in the source directory,
# rather than the installed binary in `$INSTALL_DIR`, for parity with the automatic
# `.pyc` generation run by `make install`:
# https://github.com/python/cpython/blob/v3.11.3/Makefile.pre.in#L2087-L2113
# LD_LIBRARY_PATH="${SRC_DIR}" "${SRC_DIR}/python" -m compileall -f --workers 0 "${INSTALL_DIR}"

# Support using Python 3 via the version-less `python` command, for parity with virtualenvs,
# the Python Docker images and to also ensure buildpack Python shadows any installed system
# Python, should that provide a version-less alias too.
# This symlink must be relative, to ensure that the Python install remains relocatable.
if [[ "${PYTHON_MAJOR_VERSION}" == 3.[4-9] ]]; then
  ln -srvT "${INSTALL_DIR}/bin/python3" "${INSTALL_DIR}/bin/python"
fi

cd "${ARCHIVES_DIR}"

# The tar file is gzipped separately, so we can set a higher gzip compression level than
# the default. In the future we'll also want to create a second archive that used zstd.
TAR_FILENAME="python-${PYTHON_VERSION}.tar"
tar --create --format=pax --sort=name --verbose --file "${TAR_FILENAME}" --directory="${INSTALL_DIR}" .
gzip --best "${TAR_FILENAME}"

du --max-depth 1 --human-readable "${INSTALL_DIR}"
du --all --human-readable "${ARCHIVES_DIR}"
