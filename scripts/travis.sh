#!/usr/bin/env bash
set -evx

setupCoursierBinDir() {
  mkdir -p bin
  cp coursier bin/
  export PATH="$(pwd)/bin:$PATH"
}

downloadInstallSbtExtras() {
  mkdir -p bin
  curl -L -o bin/sbt https://github.com/paulp/sbt-extras/raw/1d8ee2c0a75374afa1cb687f450aeb095180882b/sbt
  chmod +x bin/sbt
}

integrationTestsRequirements() {
  # Required for ~/.ivy2/local repo tests
  sbt scala211 coreJVM/publishLocal scala212 cli/publishLocal
}

isScalaJs() {
  [ "$SCALA_JS" = 1 ]
}

jsCompile() {
  sbt scalaFromEnv js/compile js/test:compile coreJS/fastOptJS cacheJS/fastOptJS testsJS/test:fastOptJS js/test:fastOptJS
}

jvmCompile() {
  sbt scalaFromEnv jvm/compile jvm/test:compile
}

runJsTests() {
  sbt scalaFromEnv js/test
}

runJvmTests() {
  if [ "$(uname)" == "Darwin" ]; then
    IT="testsJVM/it:test" # don't run proxy-tests in particular
  else
    IT="jvm/it:test"
  fi

  ./modules/tests/handmade-metadata/scripts/with-test-repo.sh sbt scalaFromEnv jvm/test $IT
}

checkBinaryCompatibility() {
  sbt scalaFromEnv coreJVM/mimaReportBinaryIssues cacheJVM/mimaReportBinaryIssues
}

testBootstrap() {
  if [ "$SCALA_VERSION" = 2.12 ]; then
    sbt scalaFromEnv "project cli" pack

    modules/cli/target/pack/bin/coursier bootstrap -o cs-echo io.get-coursier:echo:1.0.1
    local OUT="$(./cs-echo foo)"
    if [ "$OUT" != foo ]; then
      echo "Error: unexpected output from bootstrapped echo command." 1>&2
      exit 1
    fi


    if echo "$OSTYPE" | grep -q darwin; then
      GREP="ggrep"
    else
      GREP="grep"
    fi

    CURRENT_VERSION="$("$GREP" -oP '(?<=")[^"]*(?<!")' version.sbt)"

    sbt scalaFromEnv cli/publishLocal
    ACTUAL_VERSION="$CURRENT_VERSION" OUTPUT="coursier-test" scripts/generate-launcher.sh -r ivy2Local
    ./coursier-test bootstrap -o cs-echo-launcher io.get-coursier:echo:1.0.0
    if [ "$(./cs-echo-launcher foo)" != foo ]; then
      echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
      exit 1
    fi

    if [ "$(./cs-echo-launcher -J-Dother=thing foo -J-Dfoo=baz)" != foo ]; then
      echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
      exit 1
    fi

    if [ "$(./cs-echo-launcher "-n foo")" != "-n foo" ]; then
      echo "Error: unexpected output from bootstrapped echo command (generated by proguarded launcher)." 1>&2
      exit 1
    fi

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

    if [ "$(./cs-props -J-Dhappy=days happy)" != days ]; then
      echo "Error: unexpected output from bootstrapped props command." 1>&2
      exit 1
    fi

    # assembly tests
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
  fi
}

testNativeBootstrap() {
  if [ "$SCALA_VERSION" = "2.12" -a "$NATIVE" = "1" ]; then
    sbt scalaFromEnv "project cli" pack
    modules/cli/target/pack/bin/coursier bootstrap -S -o native-echo io.get-coursier:echo_native0.3_2.11:1.0.1
    if [ "$(./native-echo -n foo a)" != "foo a" ]; then
      echo "Error: unexpected output from native test bootstrap." 1>&2
      exit 1
    fi
  fi
}

addPgpKeys() {
  for key in b41f2bce 9fa47a44 ae548ced b4493b94 53a97466 36ee59d9 dc426429 3b80305d 69e0a56c fdd5c0cd 35543c27 70173ee5 111557de 39c263a9; do
    gpg --keyserver keyserver.ubuntu.com --recv "$key"
  done
}


# TODO Add coverage once https://github.com/scoverage/sbt-scoverage/issues/111 is fixed

downloadInstallSbtExtras
setupCoursierBinDir

if isScalaJs; then
  jsCompile
  runJsTests
else
  testNativeBootstrap

  integrationTestsRequirements
  jvmCompile

  runJvmTests

  testBootstrap

  checkBinaryCompatibility
fi

