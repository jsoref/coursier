#!/usr/bin/env bash
set -evx

if [ $# -gt 3 ]; then
  echo "Usage: $0 launcher-path local-version tmp-directory" 1>&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="$(pwd)"

if [ $# -ge 1 ]; then
  COURSIER="$1" # path to the launcher to test
else
  if [ ! -x "modules/cli/target/pack/bin/coursier" ]; then
    sbt cli/pack
  fi

  COURSIER="$(pwd)/modules/cli/target/pack/bin/coursier"
fi

if [ $# -ge 2 ]; then
  LOCAL_VERSION="$2"
else
  LOCAL_VERSION="0.1.0-test-SNAPSHOT"
  if [ ! -e "$HOME/.ivy2/local/io.get-coursier/coursier-cli_2.12/$LOCAL_VERSION/jars/coursier-cli_2.12.jar" ]; then
    sbt "set version in ThisBuild := \"$LOCAL_VERSION\"" publishLocal
  fi
fi

if [ $# -ge 3 ]; then
  TMP="$3"
  mkdir -p "$TMP"
  DO_CLEANUP=0
else
  TMP="$(mktemp -d)"
  DO_CLEANUP=1
fi

echo "Temporary directory: $TMP"

cleanup() {
  [ "$DO_CLEANUP" = "0" ] || rm -rf "$TMP"
}

trap cleanup EXIT INT TERM

if echo "$OSTYPE" | grep -q darwin; then
  GREP="ggrep"
else
  GREP="grep"
fi

generateLauncher() {
  VERSION="$LOCAL_VERSION" OUTPUT="$TMP/coursier-test" scripts/generate-launcher.sh -r ivy2Local
}

generateLauncher

cd "$TMP"

if which ng-nailgun; then
  NG=ng-nailgun
else
  NG=ng
fi

nailgun() {
  "$COURSIER" bootstrap \
    -o echo-ng \
    --standalone \
    io.get-coursier:echo:1.0.0 \
    com.facebook:nailgun-server:1.0.0 \
    -M com.facebook.nailgun.NGServer
  java -jar ./echo-ng &
  sleep 2
  local OUT="$("$NG" coursier.echo.Echo foo)"
  if [ "$OUT" != foo ]; then
    echo "Error: unexpected output from the nailgun-based echo command." 1>&2
    exit 1
  fi
}

fork() {
  local OUT="$("$COURSIER" launch --fork io.get-coursier:echo:1.0.1 -- foo)"
  if [ "$OUT" != foo ]; then
    echo "Error: unexpected output from forked echo command." 1>&2
    exit 1
  fi
}

nonStaticMainClass() {
  local OUT="$("$COURSIER" launch org.scala-lang:scala-compiler:2.13.0 --main-class scala.tools.nsc.Driver 2>&1 || true)"
  if echo "$OUT" | grep "Main method in class scala.tools.nsc.Driver is not static"; then
    :
  else
    echo "Error: unexpected output from launch command with non-static main class: $OUT"
    exit 1
  fi
}

simple() {
  "$COURSIER" bootstrap -o cs-echo io.get-coursier:echo:1.0.1
  local OUT="$(./cs-echo foo)"
  if [ "$OUT" != foo ]; then
    echo "Error: unexpected output from bootstrapped echo command." 1>&2
    exit 1
  fi
}

require() {
  if ! "$COURSIER" --require 1.0.3; then
    echo "Error: expected --require 1.0.3 to succeed." 1>&2
    exit 1
  fi
  if "$COURSIER" --require 41.0.3; then
    echo "Error: expected --require 41.0.3 to fail." 1>&2
    exit 1
  fi
}


javaClassPathProp() {
  "$COURSIER" bootstrap -o cs-props-0 io.get-coursier:props:1.0.2
  EXPECTED="./cs-props-0:$("$COURSIER" fetch --classpath io.get-coursier:props:1.0.2)"
  GOT="$(./cs-props-0 java.class.path)"
  if [ "$GOT" != "$EXPECTED" ]; then
    echo "Error: unexpected java.class.path property (expected $EXPECTED, got $CP)" 1>&2
    exit 1
  fi
}

javaClassPathInExpansion() {
  "$COURSIER" bootstrap -o cs-props-1 --property foo='${java.class.path}' io.get-coursier:props:1.0.2
  EXPECTED="./cs-props-1:$("$COURSIER" fetch --classpath io.get-coursier:props:1.0.2)"
  GOT="$(./cs-props-1 java.class.path)"
  if [ "$GOT" != "$EXPECTED" ]; then
    echo "Error: unexpected expansion with java.class.path property (expected $EXPECTED, got $GOT)" 1>&2
    exit 1
  fi
}

javaClassPathInExpansionFromLaunch() {
  EXPECTED="$("$COURSIER" fetch --classpath io.get-coursier:props:1.0.2)"
  GOT="$("$COURSIER" launch --property foo='${java.class.path}' io.get-coursier:props:1.0.2 -- foo)"
  if [ "$GOT" != "$EXPECTED" ]; then
    echo "Error: unexpected expansion with java.class.path property (expected $EXPECTED, got $CP)" 1>&2
    exit 1
  fi
}

spaceInMainJar() {
  mkdir -p "dir with space"
  "$COURSIER" bootstrap -o "dir with space/cs-props-0" io.get-coursier:props:1.0.2
  OUTPUT="$("./dir with space/cs-props-0" coursier.mainJar)"
  if ! echo "$OUTPUT" | grep -q "dir with space"; then
    echo "Error: unexpected coursier.mainJar property (got $CP, expected \"dir with space\" in it)" 1>&2
    exit 1
  fi
}

hybrid() {
  # FIXME We should also inspect the generated launcher to check that it's indeed an hybrid one
  "$COURSIER" bootstrap -o cs-echo-hybrid io.get-coursier:echo:1.0.1 --hybrid
  local OUT="$(./cs-echo-hybrid foo)"
  if [ "$OUT" != foo ]; then
    echo "Error: unexpected output from echo command hybrid launcher." 1>&2
    exit 1
  fi
}

hybridJavaClassPath() {
  "$COURSIER" bootstrap -o cs-props-hybrid io.get-coursier:props:1.0.2 --hybrid
  local OUT="$(./cs-props-hybrid java.class.path)"
  if [ "$OUT" != "./cs-props-hybrid" ]; then
    echo "Error: unexpected java.class.path from cs-props-hybrid command:" 1>&2
    ./cs-props-hybrid java.class.path 1>&2
    exit 1
  fi
}

hybridNoUrlInJavaClassPath() {
  "$COURSIER" bootstrap -o cs-props-hybrid-shared \
    io.get-coursier:props:1.0.2 \
    io.get-coursier:echo:1.0.2 \
    --shared io.get-coursier:echo \
    --hybrid
  local OUT="$(./cs-props-hybrid-shared java.class.path)"
  if [ "$OUT" != "./cs-props-hybrid-shared" ]; then
    echo "Error: unexpected java.class.path from cs-props-hybrid-shared command:" 1>&2
    ./cs-props-hybrid-shared java.class.path 1>&2
    exit 1
  fi
}

standalone() {
  "$COURSIER" bootstrap -o cs-echo-standalone io.get-coursier:echo:1.0.1 --standalone
  local OUT="$(./cs-echo-standalone foo)"
  if [ "$OUT" != foo ]; then
    echo "Error: unexpected output from bootstrapped standalone echo command." 1>&2
    exit 1
  fi
}

scalafmtStandalone() {
  "$COURSIER" bootstrap -o cs-scalafmt-standalone org.scalameta:scalafmt-cli_2.12:2.0.0-RC4 --standalone
  # return code 0 is enough
  ./cs-scalafmt-standalone --help
}

launcherSimple() {
  ./coursier-test bootstrap -o cs-echo-launcher io.get-coursier:echo:1.0.0
  if [ "$(./cs-echo-launcher foo)" != foo ]; then
    echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
    exit 1
  fi
}

launcherJavaArgs() {
  if [ "$(./cs-echo-launcher -J-Dother=thing foo -J-Dfoo=baz)" != foo ]; then
    echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
    exit 1
  fi
}

launcherArgsPacking() {
  if [ "$(./cs-echo-launcher "-n foo")" != "-n foo" ]; then
    echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
    exit 1
  fi
}

launcherJavaProps() {
  # run via the launcher rather than via the sbt-pack scripts, because the latter interprets -Dfoo=baz itself
  # rather than passing it to coursier since https://github.com/xerial/sbt-pack/pull/118
  ./coursier-test bootstrap -o cs-props -D other=thing -J -Dfoo=baz io.get-coursier:props:1.0.2
  local OUT="$(./cs-props foo)"
  if [ "$OUT" != baz ]; then
    echo -e "Error: unexpected output from bootstrapped props command.\n$OUT" 1>&2
    exit 1
  fi
  local OUT="$(./cs-props other)"
  if [ "$OUT" != thing ]; then
    echo -e "Error: unexpected output from bootstrapped props command.\n$OUT" 1>&2
    exit 1
  fi
}

launcherJavaPropsArgs() {
 if [ "$(./cs-props -J-Dhappy=days happy)" != days ]; then
   echo "Error: unexpected output from bootstrapped props command." 1>&2
   exit 1
 fi
}

launcherJavaPropsEnv() {
  if [ "$(JAVA_OPTS=-Dhappy=days ./cs-props happy)" != days ]; then
    echo "Error: unexpected output from bootstrapped props command." 1>&2
    exit 1
  fi
}

launcherJavaPropsEnvMulti() {
  if [ "$(JAVA_OPTS="-Dhappy=days -Dfoo=other" ./cs-props happy)" != days ]; then
    echo "Error: unexpected output from bootstrapped props command." 1>&2
    exit 1
  fi
}

launcherAssembly() {
  ./coursier-test bootstrap -a -o cs-props-assembly -D other=thing -J -Dfoo=baz io.get-coursier:props:1.0.2
  local OUT="$(./cs-props-assembly foo)"
  if [ "$OUT" != baz ]; then
    echo -e "Error: unexpected output from assembly props command.\n$OUT" 1>&2
    exit 1
  fi
  local OUT="$(./cs-props-assembly other)"
  if [ "$OUT" != thing ]; then
    echo -e "Error: unexpected output from assembly props command.\n$OUT" 1>&2
    exit 1
  fi
}

launcherAssemblyPreambleInSource() {
  # source jar here has a bash preamble, which assembly should ignore
"$COURSIER" bootstrap \
  --intransitive io.get-coursier::coursier-cli:1.1.0-M14-2 \
  -o coursier-test.jar \
  --assembly \
  --classifier standalone \
  -A jar
./coursier-test.jar --help
}

nailgun
fork
nonStaticMainClass
simple
require
javaClassPathProp
javaClassPathInExpansion
javaClassPathInExpansionFromLaunch
spaceInMainJar
hybrid
hybridJavaClassPath
hybridNoUrlInJavaClassPath
standalone
scalafmtStandalone

launcherSimple
launcherJavaArgs
launcherArgsPacking
launcherJavaProps
launcherJavaPropsArgs
launcherJavaPropsEnv
launcherJavaPropsEnvMulti
launcherAssembly
launcherAssemblyPreambleInSource
