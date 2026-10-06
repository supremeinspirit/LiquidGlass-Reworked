#!/var/jb/bin/sh
# on-device build for the iOS 13 rootful port; logos is pinned (see ../deps)
umask 022
export THEOS=/var/jb/theos LC_ALL=C
exec make THEOS_BIN_PATH="$(cd "$(dirname "$0")/../deps/theosbin" && pwd)" "$@"
